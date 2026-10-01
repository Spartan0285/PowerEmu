/*
 * PowerEmu Agent - runs inside the virtual Mac (Mac OS X 10.4+, PowerPC).
 *
 * A background-only application started as a login item.  It connects to
 * PowerEmu through QEMU's user-mode network: connections to 10.0.2.100:7700
 * are forwarded to the PowerEmu app on the host.
 *
 * Messages both ways are a header line "VERB LENGTH\n" followed by LENGTH
 * bytes of payload:
 *
 *   host -> guest   HELLO   host version
 *                   CLIP    UTF-8 text for the pasteboard
 *                   SHUTDOWN / RESTART
 *                   MOUNT   "URL\tNAME" of a shared folder (WebDAV)
 *                   UNMOUNT NAME of a shared folder
 *                   CHANGED lines of "NAME\tPATH": folders in a shared folder
 *                           that changed on the host (PATH is relative to
 *                           the share, empty for its top)
 *                   PING
 *   guest -> host   HELLO   "agent-version\tmac-os-version\tuser"
 *                   CLIP    UTF-8 text copied in the guest
 *                   PONG
 *                   LOG     a line for PowerEmu's log
 *
 * Objective-C 1 with manual retain/release, for the 10.4 SDK.
 */
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include "PEPixelPack.h"

/*
 * Private CoreGraphics window-server calls (there is no public window list
 * before 10.5).  Stable on 10.4 and 10.5, PowerPC.  Harmony uses them to tell
 * PowerEmu exactly where the guest's windows are, so it can show those and
 * nothing else -- rather than guessing from what is drawn, which leaks.
 */
typedef int CGSConnectionID;
typedef int CGSWindowID;
extern CGSConnectionID _CGSDefaultConnection(void);
extern CGError CGSGetOnScreenWindowList(CGSConnectionID cid, CGSConnectionID target,
                                        int capacity, CGSWindowID *list, int *count);
extern CGError CGSGetScreenRectForWindow(CGSConnectionID cid, CGSWindowID wid, CGRect *rect);
extern CGError CGSGetWindowLevel(CGSConnectionID cid, CGSWindowID wid, int *level);
/*
 * Which window is on top of which.
 *
 * PowerEmu copies each guest window's pixels out of the one screen everything
 * is drawn into, so it has to know whether anything is covering a window: what
 * the framebuffer holds under another window is that other window.
 *
 * CGSGetOnScreenWindowList answers this: with a target of 0 it lists every
 * window on screen from front to back, across applications.  Bringing another
 * application forward moves its windows to the front of the list, which is the
 * whole question.
 *
 * This was doubted once, and replaced by CGSGetWindowGlobalClipShape -- the
 * visible part of a window, which the window server works out itself.  On
 * Tiger that returns an empty region for every window, so every window looked
 * covered, nothing was ever copied afresh, and every window on this Mac sat
 * frozen at whatever had last been taken of it.  It looked like the copies
 * were right because they were only ever made during the pass that raises each
 * window in turn.  The list's order is the thing to use.
 */
extern CGError CGSMoveWindow(CGSConnectionID cid, CGSWindowID wid, CGPoint *point);
extern CGError CGSOrderWindow(CGSConnectionID cid, CGSWindowID wid, int mode, CGSWindowID relative);
/* Which application a window belongs to, to bring it to the front on a click. */
extern CGError CGSGetWindowOwner(CGSConnectionID cid, CGSWindowID wid, CGSConnectionID *owner);
extern CGError CGSConnectionGetPID(CGSConnectionID cid, pid_t *pid, CGSConnectionID owner);
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/param.h>
#include <sys/ucred.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <dirent.h>
#include <dlfcn.h>
#include <zlib.h>
#include <limits.h>

#include "PEFullscreenState.h"
#include "PEAccessibility.h"
#include "PETilePack.h"

#include "PETransferZip.h"

#define PE_AGENT_VERSION "2.21"

extern CGError CGSGetConnectionIDForPSN(CGSConnectionID cid, ProcessSerialNumber *psn,
                                        CGSConnectionID *out);

/*
 * Which window is drawn at a point on the screen.
 *
 * This is the one question the window server will answer truthfully about
 * windows it does not own, and it is the whole of what Harmony needs: for any
 * patch of a window, is that patch this window, or is something else drawn
 * over it?  Looked up by name rather than linked against, so an older system
 * that does not have it simply falls back instead of refusing to launch.
 */
typedef CGError (*PEFindWindowFn)(CGSConnectionID cid, int zero, int one, int zero2,
                                  CGPoint *screenPoint, CGPoint *windowPoint,
                                  CGSWindowID *outWid, CGSConnectionID *outCid);
static PEFindWindowFn PEFindWindow(void)
{
    static PEFindWindowFn fn;
    static int looked;
    if (!looked) {
        looked = 1;
        fn = (PEFindWindowFn)dlsym(RTLD_DEFAULT, "CGSFindWindowByGeometry");
    }
    return fn;
}

/* The window drawn at a screen point, or 0 if it cannot be told. */
static CGSWindowID PEWindowAtPoint(CGSConnectionID cid, CGPoint p)
{
    PEFindWindowFn fn = PEFindWindow();
    CGSWindowID wid = 0;
    CGSConnectionID owner = 0;
    CGPoint local;
    if (!fn) return 0;
    if (fn(cid, 0, 1, 0, &p, &local, &wid, &owner) != kCGErrorSuccess) return 0;
    return wid;
}

#ifndef kSetFrontProcessFrontWindowOnly
#define kSetFrontProcessFrontWindowOnly (1 << 0)
#endif
#define PE_HOST_ADDR     "10.0.2.100"
#define PE_HOST_PORT     7700

/*
 * Both can be pointed elsewhere for testing, which is the only way to
 * exercise the agent on a real PowerPC Mac rather than inside a guest:
 * 10.0.2.100 only means anything behind QEMU's user-mode networking.
 */
static const char *AgentHost(void)
{
    const char *h = getenv("PE_AGENT_HOST");
    return (h && *h) ? h : PE_HOST_ADDR;
}

static int AgentPort(void)
{
    const char *p = getenv("PE_AGENT_PORT");
    return (p && *p) ? atoi(p) : PE_HOST_PORT;
}

@interface PEAgent : NSObject {
    NSMutableDictionary *fileTransfers;
    NSLock *fileTransferLock;
    int fileTransferWorkers;
    int fileDragWindow;
    NSString *fileDragSourcePath;
    NSArray *fileDragPaths;
    int sock;
    BOOL completeCaptureMode;
    PEFullscreenState fullscreenState;
    BOOL deferredHarmonyExit;
    int focusRequestSequence;
    NSLock *captureLock;
    int frameSock;
    NSString *controlFrameSession;
    NSString *workerFrameSession;
    int pointerButtons;
    NSMutableDictionary *captureHistory;
    // Worker-owned capture storage. Recycle only when the cache retained a
    // separate previous image, never while these pixels are the cached image.
    NSMutableData *captureScratch;
    CGContextRef captureContext;
    BOOL captureScratchReusable;
    NSFileHandle *handle;
    NSMutableData *inbox;
    int lastChangeCount;        /* pasteboard change we have dealt with */
    NSString *lastClip;         /* text last exchanged, to stop echoes */
    BOOL harmonyChangedFinder; /* latched on entry; CAPTUREMODE is cleared before exit */
    BOOL harmonyRemembered;     /* whether the two below have been read yet */
    BOOL dockHadAutohide;       /* whether these were set at all before */
    BOOL dockWasAutohidden;     /* what this Mac looked like before Harmony */
    BOOL finderHadDesktopKey;
    BOOL finderDrewDesktop;
    NSTimer *windowTimer;
    NSString *savedMinEffect;
    int windowReportTick;       /* reports window rectangles while Harmony is on */
    int sheetReportTick;
    unsigned sheetEpoch;
    BOOL sheetReportBusy;
    int lastWindowCount;        /* so a window going away is noticed at once */
    BOOL raiseBringsAppForward; /* RAISEHARD: raise the whole application */
    int hitTestProbed;
    pid_t menuBarPid;           /* application whose menus PowerEmu is showing */
    CFAbsoluteTime menuBarReportedAt;
}
- (void)fileTransfer:(NSDictionary *)request;
- (void)armFileDrag:(NSString *)spec;
- (void)reportFocused;
- (void)confirmFocus:(NSArray *)request;
- (void)sheetWorker:(NSNumber *)epoch;
- (void)sheetResult:(NSArray *)result;
- (void)connect;
- (void)disconnected;
- (void)processInbox;
- (void)handle:(NSString *)verb payload:(NSData *)payload;
- (void)mount:(NSString *)spec;
- (void)unmount:(NSString *)name;
- (void)changed:(NSString *)list;
- (void)harmony:(BOOL)on;
- (void)reportWindows:(NSTimer *)t;
- (void)setResolution:(NSString *)wh;
- (void)raiseWindow:(NSString *)idStr;
- (void)moveWindow:(NSString *)args;
- (void)minimizeWindow:(NSString *)args;
- (void)setMinimiseEffect:(NSString *)effect;
- (void)set:(NSString *)domain key:(NSString *)key yes:(BOOL)yes keep:(BOOL)keep;
- (void)run:(NSString *)tool with:(NSArray *)args;
- (void)sendAppIcon:(NSString *)pidStr;
- (BOOL)reportMenuBarFor:(pid_t)pid;
- (void)reportMenuItems:(NSString *)args;
- (void)pickMenuItem:(NSString *)args;
@end


/*
 * Accessibility: the supported way to move, raise and read the menus of another
 * application's windows.  CGS refuses all three for a window this connection
 * does not own, so everything that acts on a guest window goes through here.
 *
 * An Accessibility window carries no CoreGraphics window number, so the two are
 * matched by their frame: every application with a user interface is asked for
 * its windows and the one sitting exactly where CGS says ours is, is it.
 */
#include "PESheets.inc"

static AXUIElementRef PEFindAXWindow(CGRect rect, pid_t *ownerOut)
{
    ProcessSerialNumber psn = { 0, kNoProcess };
    if (!AXAPIEnabled()) {
        return NULL;
    }
    while (GetNextProcess(&psn) == noErr) {
        ProcessInfoRec info;
        pid_t pid = 0;
        CFArrayRef windows = NULL;
        AXUIElementRef app;
        memset(&info, 0, sizeof(info));
        info.processInfoLength = sizeof(info);
        if (GetProcessInformation(&psn, &info) != noErr) continue;
        if (info.processMode & modeOnlyBackground) continue;
        if (GetProcessPID(&psn, &pid) != noErr || pid <= 0) continue;
        app = AXUIElementCreateApplication(pid);
        if (!app) continue;
        if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute,
                                          (CFTypeRef *)&windows) == kAXErrorSuccess && windows) {
            NSMutableArray *all = [NSMutableArray arrayWithArray:(NSArray *)windows];
            CFIndex i, roots = [all count];
            for(i=0;i<roots;i++) PEAppendSheets((AXUIElementRef)[all objectAtIndex:i],all,0);
            CFIndex n = [all count];
            for (i = 0; i < n; i++) {
                AXUIElementRef w = (AXUIElementRef)[all objectAtIndex:i];
                CFTypeRef posRef = NULL, sizeRef = NULL;
                CGPoint p; CGSize sz;
                if (AXUIElementCopyAttributeValue(w, kAXPositionAttribute, &posRef) != kAXErrorSuccess)
                    continue;
                if (AXUIElementCopyAttributeValue(w, kAXSizeAttribute, &sizeRef) != kAXErrorSuccess) {
                    CFRelease(posRef);
                    continue;
                }
                AXValueGetValue((AXValueRef)posRef, kAXValueCGPointType, &p);
                AXValueGetValue((AXValueRef)sizeRef, kAXValueCGSizeType, &sz);
                CFRelease(posRef);
                CFRelease(sizeRef);
                if (fabs(p.x - rect.origin.x) <= 4 && fabs(p.y - rect.origin.y) <= 4 &&
                    fabs(sz.width - rect.size.width) <= 4 && fabs(sz.height - rect.size.height) <= 4) {
                    CFRetain(w);
                    CFRelease(windows);
                    CFRelease(app);
                    if (ownerOut) *ownerOut = pid;
                    return w;
                }
            }
            CFRelease(windows);
        }
        CFRelease(app);
    }
    return NULL;
}

/* Where the volume mounted from `from` (a WebDAV URL) is, or nil. */
/*
 * Menus.
 *
 * In Harmony this Mac's menu bar is never shown -- the point is that a guest
 * application should look like it is running here -- so the front guest
 * application's menus are read out and rebuilt in PowerEmu's own menu bar
 * instead.  Accessibility is the only way to read another application's menus,
 * and the only way to work them afterwards.
 *
 * An item is addressed by where it sits rather than by a reference, as a path
 * of indices from the menu bar: "3.5.1" is the menu bar's fourth menu, its
 * sixth item, that item's second.  PowerEmu hands the same path back when
 * somebody picks it and it is walked again, which keeps nothing alive between
 * the two.
 */
#ifndef kAXMenuItemCmdCharAttribute
#define kAXMenuItemCmdCharAttribute      CFSTR("AXMenuItemCmdChar")
#endif
#ifndef kAXMenuItemCmdModifiersAttribute
#define kAXMenuItemCmdModifiersAttribute CFSTR("AXMenuItemCmdModifiers")
#endif
#ifndef kAXMenuItemMarkCharAttribute
#define kAXMenuItemMarkCharAttribute     CFSTR("AXMenuItemMarkChar")
#endif

static CFArrayRef PECopyChildren(AXUIElementRef e)
{
    CFArrayRef kids = NULL;
    if (!e) return NULL;
    if (AXUIElementCopyAttributeValue(e, kAXChildrenAttribute,
                                      (CFTypeRef *)&kids) != kAXErrorSuccess) return NULL;
    return kids;
}

static AXUIElementRef PECopyMenuBar(pid_t pid)
{
    AXUIElementRef app = pid > 0 ? AXUIElementCreateApplication(pid) : NULL;
    AXUIElementRef bar = NULL;
    if (!app) return NULL;
    AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute, (CFTypeRef *)&bar);
    CFRelease(app);
    return bar;
}

/*
 * Below the menu bar every level is an item wrapping a menu: the item's one
 * child is the menu, and the menu's children are the next items down.
 */
static AXUIElementRef PECopyMenuOf(AXUIElementRef item)
{
    CFArrayRef one = PECopyChildren(item);
    AXUIElementRef menu = NULL;
    if (one) {
        if (CFArrayGetCount(one) > 0)
            menu = (AXUIElementRef)CFRetain(CFArrayGetValueAtIndex(one, 0));
        CFRelease(one);
    }
    return menu;
}

static AXUIElementRef PECopyMenuElement(pid_t pid, NSString *path)
{
    AXUIElementRef bar = PECopyMenuBar(pid);
    AXUIElementRef cur;
    NSArray *parts = [path componentsSeparatedByString:@"."];
    unsigned k;
    if (!bar) return NULL;
    cur = (AXUIElementRef)CFRetain(bar);
    for (k = 0; k < [parts count]; k++) {
        CFArrayRef kids;
        AXUIElementRef next = NULL;
        CFIndex want = (CFIndex)[[parts objectAtIndex:k] intValue];
        if (k > 0) {                        /* step from the item into its menu */
            AXUIElementRef menu = PECopyMenuOf(cur);
            CFRelease(cur);
            cur = menu;
            if (!cur) break;
        }
        kids = PECopyChildren(cur);
        if (kids) {
            if (want >= 0 && want < CFArrayGetCount(kids))
                next = (AXUIElementRef)CFRetain(CFArrayGetValueAtIndex(kids, want));
            CFRelease(kids);
        }
        CFRelease(cur);
        cur = next;
        if (!cur) break;
    }
    CFRelease(bar);
    return cur;
}

static NSString *PEAXString(AXUIElementRef e, CFStringRef attr)
{
    CFTypeRef v = NULL;
    NSString *out = @"";
    if (AXUIElementCopyAttributeValue(e, attr, &v) == kAXErrorSuccess && v) {
        if (CFGetTypeID(v) == CFStringGetTypeID()) out = [[(NSString *)v copy] autorelease];
        CFRelease(v);
    }
    /* Tabs and newlines separate the fields this goes into. */
    if ([out rangeOfString:@"\t"].location != NSNotFound
        || [out rangeOfString:@"\n"].location != NSNotFound) {
        NSMutableString *m = [[out mutableCopy] autorelease];
        NSRange all = NSMakeRange(0, [m length]);
        [m replaceOccurrencesOfString:@"\t" withString:@" " options:0 range:all];
        all = NSMakeRange(0, [m length]);
        [m replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:all];
        out = m;
    }
    return out;
}

static int PEAXInt(AXUIElementRef e, CFStringRef attr, int fallback)
{
    CFTypeRef v = NULL;
    int out = fallback;
    if (AXUIElementCopyAttributeValue(e, attr, &v) == kAXErrorSuccess && v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &out);
        else if (CFGetTypeID(v) == CFBooleanGetTypeID()) out = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
        CFRelease(v);
    }
    return out;
}

/*
 * Every item of one menu, and of the menus inside it, as
 * "path<tab>title<tab>enabled<tab>key<tab>modifiers<tab>mark<tab>hasSubmenu".
 * An item with no title is a separator.
 */
static void PEAppendMenuItems(AXUIElementRef item, NSString *path, int depth, NSMutableString *out)
{
    AXUIElementRef menu = PECopyMenuOf(item);
    CFArrayRef kids = menu ? PECopyChildren(menu) : NULL;
    CFIndex i, n = kids ? CFArrayGetCount(kids) : 0;
    for (i = 0; i < n; i++) {
        AXUIElementRef it = (AXUIElementRef)CFArrayGetValueAtIndex(kids, i);
        NSString *childPath = [NSString stringWithFormat:@"%@.%d", path, (int)i];
        NSString *title = PEAXString(it, kAXTitleAttribute);
        CFArrayRef sub = PECopyChildren(it);
        int hasSub = (sub && CFArrayGetCount(sub) > 0) ? 1 : 0;
        if (sub) CFRelease(sub);
        [out appendFormat:@"%@\t%@\t%d\t%@\t%d\t%@\t%d\n", childPath, title,
             PEAXInt(it, kAXEnabledAttribute, 1),
             PEAXString(it, kAXMenuItemCmdCharAttribute),
             PEAXInt(it, kAXMenuItemCmdModifiersAttribute, 0),
             PEAXString(it, kAXMenuItemMarkCharAttribute), hasSub];
        /*
         * Submenus are followed, but not far: each level is another round of
         * calls into the other application, and menus three deep are rare.
         */
        if (hasSub && depth < 2) PEAppendMenuItems(it, childPath, depth + 1, out);
    }
    if (kids) CFRelease(kids);
    if (menu) CFRelease(menu);
}

static NSString *MountPointFor(NSString *from)
{
    struct statfs *m;
    int i, n = getmntinfo(&m, MNT_NOWAIT);
    for (i = 0; i < n; i++) {
        /* webdavfs records the URL percent-encoded; PowerEmu sends it plain. */
        NSString *f = [[NSString stringWithUTF8String:m[i].f_mntfromname]
                          stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        if (!f) continue;
        if ([f isEqualToString:from] || [[f stringByAppendingString:@"/"] isEqualToString:from])
            return [NSString stringWithUTF8String:m[i].f_mntonname];
    }
    return nil;
}

/* Ask loginwindow to shut down or restart, as the Apple menu does:
 * applications are asked to quit and can still stop it (unsaved work).
 * Apple Technical Q&A QA1134. */
static OSStatus SendLoginwindowEvent(AEEventID what)
{
    ProcessSerialNumber psn = { 0, kSystemProcess };
    AEAddressDesc target;
    AppleEvent event = { typeNull, NULL }, reply = { typeNull, NULL };
    OSStatus err = AECreateDesc(typeProcessSerialNumber, &psn, sizeof psn, &target);
    if (err != noErr) return err;
    err = AECreateAppleEvent(kCoreEventClass, what, &target, kAutoGenerateReturnID,
                             kAnyTransactionID, &event);
    AEDisposeDesc(&target);
    if (err != noErr) return err;
    err = AESend(&event, &reply, kAENoReply, kAENormalPriority, kAEDefaultTimeout, NULL, NULL);
    AEDisposeDesc(&event);
    AEDisposeDesc(&reply);
    return err;
}

@implementation PEAgent

- (id)init
{
    if ((self = [super init])) {
        sock = -1;
        frameSock = -1;
        inbox = [[NSMutableData alloc] init];
        lastChangeCount = [[NSPasteboard generalPasteboard] changeCount];
    }
    return self;
}

/*
 * What is in this Mac's Dock, so PowerEmu can show it while Harmony has the
 * real one hidden.
 *
 * The Dock keeps its own list in com.apple.dock: persistent-apps are the ones
 * somebody put there, in the order they put them.  Each entry carries a file
 * URL and the label the Dock draws.  Both are wanted -- the label because it
 * is what the reader recognizes, the path because it is what opens the thing.
 *
 * Running applications that are not in the Dock are added after them, which is
 * what the Dock itself does: it shows what you keep and what you are using.
 * They are marked so PowerEmu can bring one forward rather than open a second
 * copy.
 */
- (void)sendDockApps
{
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    NSDictionary *dock = [u persistentDomainForName:@"com.apple.dock"];
    NSArray *items = [dock objectForKey:@"persistent-apps"];
    NSMutableString *out = [NSMutableString string];
    NSMutableSet *listed = [NSMutableSet set];
    NSEnumerator *e = [items objectEnumerator];
    NSDictionary *item;
    ProcessSerialNumber psn = { 0, kNoProcess };

    /* Which applications are up, by the path they were opened from. */
    NSMutableDictionary *running = [NSMutableDictionary dictionary];
    while (GetNextProcess(&psn) == noErr) {
        ProcessInfoRec info;
        FSSpec spec;
        pid_t pid = 0;
        memset(&info, 0, sizeof(info));
        info.processInfoLength = sizeof(info);
        info.processAppSpec = &spec;
        if (GetProcessInformation(&psn, &info) != noErr) continue;
        if (info.processMode & modeOnlyBackground) continue;
        if (GetProcessPID(&psn, &pid) != noErr) continue;
        {
            CFURLRef url = CFURLCreateFromFSRef(NULL, (const FSRef *)&spec);
            NSString *path = nil;
            if (url) {
                path = [(NSURL *)url path];
                CFRelease(url);
            }
            if (path) [running setObject:[NSNumber numberWithInt:(int)pid] forKey:path];
        }
    }

    while ((item = [e nextObject])) {
        NSDictionary *tile = [item objectForKey:@"tile-data"];
        NSDictionary *file = [tile objectForKey:@"file-data"];
        NSString *url = [file objectForKey:@"_CFURLString"];
        NSString *label = [tile objectForKey:@"file-label"];
        NSString *path = nil;
        NSNumber *pid;
        if (!url) continue;
        path = [url hasPrefix:@"file://"] ? [[NSURL URLWithString:url] path] : url;
        if (![path length]) continue;
        if (![label length]) label = [[path lastPathComponent] stringByDeletingPathExtension];
        pid = [running objectForKey:path];
        [out appendFormat:@"%@\t%@\t%d\n", path, label, pid ? [pid intValue] : 0];
        [listed addObject:path];
    }

    /* Then anything running that nobody has kept in the Dock. */
    {
        NSEnumerator *r = [running keyEnumerator];
        NSString *path;
        while ((path = [r nextObject])) {
            NSString *label;
            if ([listed containsObject:path]) continue;
            label = [[path lastPathComponent] stringByDeletingPathExtension];
            if ([label isEqualToString:@"PowerEmu Agent"]) continue;
            [out appendFormat:@"%@\t%@\t%d\n", path, label,
                              [[running objectForKey:path] intValue]];
        }
    }
    [self send:@"DOCKAPPS" text:out];
}

- (void)send:(NSString *)verb data:(NSData *)payload
{
    if (sock < 0) return;
    unsigned len = payload ? [payload length] : 0;
    NSString *head = [NSString stringWithFormat:@"%@ %u\n", verb, len];
    NSMutableData *d = [NSMutableData dataWithData:[head dataUsingEncoding:NSASCIIStringEncoding]];
    if (payload) [d appendData:payload];
    const char *p = [d bytes];
    size_t left = [d length];
    while (left > 0) {
        ssize_t n = write(sock, p, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { [self disconnected]; return; }
        p += n; left -= n;
    }
}

- (void)send:(NSString *)verb text:(NSString *)text
{
    [self send:verb data:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

/* Complete window backing-store capture, including covered pixels. Never
 * substitute a screen crop here. The host permits only one request in flight.
 * RGBA bytes avoid expensive guest PNG encoding and are immutable on receipt. */
- (NSData *)captureWindow:(NSString *)request
{
    BOOL profile = getenv("POWEREMU_CAPTURE_PROFILE") != NULL;
    const char *reuseSetting = getenv("PE_CAPTURE_REUSE");
    BOOL reuse = (!reuseSetting || strcmp(reuseSetting, "0") != 0) && captureScratchReusable;
    CFAbsoluteTime began = profile ? CFAbsoluteTimeGetCurrent() : 0;
    int wid = [request intValue];
    NSArray *fields = [request componentsSeparatedByString:@" "];
    int sequence = [fields count] > 1 ? [[fields objectAtIndex:1] intValue] : 0;
    NSData *failure = [[NSString stringWithFormat:@"%d 0 0 0 %d\n", wid, sequence] dataUsingEncoding:NSASCIIStringEncoding];
    typedef void (*CaptureFn)(CGContextRef, CGRect, int, int, CGRect);
    CaptureFn capture = (CaptureFn)dlsym(RTLD_DEFAULT, "CGContextCopyWindowCaptureContentsToRect");
    CGRect rect, after;
    int cid = _CGSDefaultConnection();
    if (!capture || wid <= 0 || CGSGetScreenRectForWindow(cid, wid, &rect) != 0 ||
        rect.size.width < 1 || rect.size.height < 1 || rect.size.width > 4096 || rect.size.height > 4096) {
        return failure;
    }
    size_t w = (size_t)rect.size.width, h = (size_t)rect.size.height;
    // Keep one bounded context for the current size. Explicitly zero every
    // pixel before capture, including corners the private API may not paint.
    // This preserves the old freshly allocated bitmap's initialization.
    if (captureContext && (!reuse || CGBitmapContextGetWidth(captureContext) != w ||
                           CGBitmapContextGetHeight(captureContext) != h)) {
        CGContextRelease(captureContext); captureContext = NULL;
        [captureScratch release]; captureScratch = nil;
    }
    if (!captureContext) {
        [captureScratch release];
        captureScratch = [[NSMutableData alloc] initWithLength:w*h*4];
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        captureContext = CGBitmapContextCreate([captureScratch mutableBytes], w, h, 8, w*4,
                                              color, kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(color);
    }
    NSMutableData *pixels = captureScratch;
    CGContextRef context = captureContext;
    if (reuse) memset([pixels mutableBytes], 0, [pixels length]);
    CFAbsoluteTime allocated = profile ? CFAbsoluteTimeGetCurrent() : 0;
    if (context) {
        CGRect local = CGRectMake(0,0,w,h);
        CGContextSaveGState(context);
        capture(context, local, cid, wid, local);
        CGContextFlush(context);
        CGContextRestoreGState(context);
    }
    if (!context || CGSGetScreenRectForWindow(cid, wid, &after) != 0 ||
        !CGSizeEqualToSize(rect.size, after.size)) {
        return failure;
    }
    CFAbsoluteTime captured = profile ? CFAbsoluteTimeGetCurrent() : 0;
    // Compare complete pixels, not a hash: an unchanged window needs no
    // compression, transfer or host texture upload. The host echoes the last
    // sequence it actually accepted, so a dropped response forces a full image.
    if (!captureHistory) captureHistory = [[NSMutableDictionary alloc] init];
    NSString *key = [NSString stringWithFormat:@"%d", wid];
    NSDictionary *previous = [captureHistory objectForKey:key];
    int accepted = [fields count] > 2 ? [[fields objectAtIndex:2] intValue] : 0;
    NSData *oldPixels = [previous objectForKey:@"pixels"];
    BOOL baseMatches = accepted > 0 && accepted == [[previous objectForKey:@"sequence"] intValue]
        && w == [[previous objectForKey:@"width"] unsignedIntValue]
        && h == [[previous objectForKey:@"height"] unsignedIntValue]
        && [oldPixels length] == [pixels length];
    BOOL unchanged = baseMatches && memcmp([oldPixels bytes], [pixels bytes], [pixels length]) == 0;
    NSMutableData *tilePacket = nil;
    // Tiles are opt-in, lossless, and based only on the sequence the host
    // actually accepted. Dense updates abort early to the independent codecs.
    // Flat UI images already have a cheap pixel-packet codec; don't add work.
    if (!unchanged && baseMatches && [fields count] > 4 &&
        [[fields objectAtIndex:4] isEqualToString:@"tiles32"] &&
        !getenv("PE_CAPTURE_RAW") && [pixels length] >= 16384 &&
        !PEPixelPackWorthTrying([pixels bytes], [pixels length]/4) &&
        PETileWorthTrying([oldPixels bytes], [pixels bytes], [pixels length]/4)) {
        NSMutableData *tiles = [NSMutableData dataWithLength:[pixels length]/8];
        size_t length = PETilePack([oldPixels bytes], [pixels bytes], w, h, accepted,
                                   [tiles mutableBytes], [tiles length]);
        if (length) {
            uLongf packedLength = compressBound(length);
            NSMutableData *candidate = [NSMutableData dataWithLength:packedLength+4];
            if (compress2((Bytef *)[candidate mutableBytes]+4, &packedLength,
                          [tiles bytes], length, 1) == Z_OK && packedLength+4 < [pixels length]/8) {
                PETilePut32([candidate mutableBytes], length);
                [candidate setLength:packedLength+4];
                tilePacket = candidate;
            }
        }
    }
    CFAbsoluteTime compared = profile ? CFAbsoluteTimeGetCurrent() : 0;
    if ([pixels length] <= 8 * 1024 * 1024) {
        // Keep the recently used windows when one more application opens.
        // Clearing the entire cache made five-window workloads resend every
        // image repeatedly. Bound retained pixels to eight 8 MB entries.
        if ([captureHistory count] >= 8 && !previous) {
            NSString *oldest = nil;
            NSEnumerator *keys = [captureHistory keyEnumerator];
            NSString *candidate;
            int oldestSequence = INT_MAX;
            while ((candidate = [keys nextObject])) {
                int candidateSequence = [[[captureHistory objectForKey:candidate] objectForKey:@"sequence"] intValue];
                if (candidateSequence < oldestSequence) { oldest = candidate; oldestSequence = candidateSequence; }
            }
            if (oldest) [captureHistory removeObjectForKey:oldest];
        }
        [captureHistory setObject:[NSDictionary dictionaryWithObjectsAndKeys:
            // Changed pixels become the retained image. Do not write this
            // buffer again. Only an unchanged capture may reuse its scratch,
            // because the cache keeps the separate previous image instead.
            unchanged ? oldPixels : (NSData *)pixels, @"pixels",
            [NSNumber numberWithInt:sequence], @"sequence",
            [NSNumber numberWithUnsignedInt:w], @"width", [NSNumber numberWithUnsignedInt:h], @"height", nil] forKey:key];
    } else [captureHistory removeObjectForKey:key];
    captureScratchReusable = unchanged;
    if (unchanged) {
        if (profile) fprintf(stderr, "PECAPTURE id=%d seq=%d unchanged=1 setupMS=%.3f captureMS=%.3f compareMS=%.3f cacheMS=%.3f compressMS=0 totalMS=%.3f\n",
            wid, sequence, (allocated-began)*1000, (captured-allocated)*1000,
            (compared-captured)*1000, (CFAbsoluteTimeGetCurrent()-compared)*1000,
            (CFAbsoluteTimeGetCurrent()-began)*1000);
        return [[NSString stringWithFormat:@"%d %lu %lu 2 %d\n", wid,
            (unsigned long)w, (unsigned long)h, sequence] dataUsingEncoding:NSASCIIStringEncoding];
    }
    if (tilePacket) {
        NSMutableData *out = [NSMutableData dataWithData:[[NSString stringWithFormat:@"%d %lu %lu 4 %d\n",
            wid, (unsigned long)w, (unsigned long)h, sequence] dataUsingEncoding:NSASCIIStringEncoding]];
        [out appendData:tilePacket];
        if (profile) fprintf(stderr, "PETILES id=%d seq=%d base=%d totalMS=%.3f bytes=%lu\n",
            wid, sequence, accepted, (CFAbsoluteTimeGetCurrent()-began)*1000, (unsigned long)[out length]);
        return out;
    }
    CFAbsoluteTime cached = profile ? CFAbsoluteTimeGetCurrent() : 0;
    // Diagnostic A/B option: raw transport may cost less than guest zlib.
    // Keep compression as the default until measured through the real bridge.
    BOOL tryCompression = getenv("PE_CAPTURE_RAW") == NULL;
    uLongf packedSize = 0;
    NSMutableData *packed = nil;
    BOOL compressed = NO;
    int encoding = 0;
    BOOL pixelPackets = [fields count] > 3 && [[fields objectAtIndex:3] isEqualToString:@"rle32"];
    if (tryCompression && pixelPackets && PEPixelPackWorthTrying([pixels bytes], [pixels length] / 4)) {
        // Require at least 4:1 reduction; abort early for detailed/noisy images.
        packed = [NSMutableData dataWithLength:[pixels length] / 4];
        packedSize = PEPixelPack([pixels bytes], [pixels length] / 4,
                                 [packed mutableBytes], [packed length]);
        if (packedSize) { compressed = YES; encoding = 3; }
    }
    if (!compressed) {
        packedSize = tryCompression ? compressBound([pixels length]) : 0;
        packed = tryCompression ? [NSMutableData dataWithLength:packedSize] : nil;
        const char *memorySetting = getenv("PE_CAPTURE_MEMLEVEL");
        int memoryLevel = memorySetting ? atoi(memorySetting) : 8;
        if (memoryLevel < 1 || memoryLevel > 9) memoryLevel = 8;
        if (tryCompression && (getenv("PE_CAPTURE_RLE") || memorySetting)) {
            z_stream stream;
            memset(&stream, 0, sizeof stream);
            // RLE is still a standard zlib stream; the host decoder is unchanged.
            if (deflateInit2(&stream, 1, Z_DEFLATED, MAX_WBITS, memoryLevel,
                             getenv("PE_CAPTURE_RLE") ? Z_RLE : Z_DEFAULT_STRATEGY) == Z_OK) {
                stream.next_in = (Bytef *)[pixels bytes]; stream.avail_in = [pixels length];
                stream.next_out = [packed mutableBytes]; stream.avail_out = packedSize;
                compressed = deflate(&stream, Z_FINISH) == Z_STREAM_END;
                packedSize = stream.total_out;
                deflateEnd(&stream);
            }
        } else if (tryCompression) {
            compressed = compress2([packed mutableBytes], &packedSize, [pixels bytes], [pixels length], 1) == Z_OK;
        }
        if (compressed) encoding = 1;
    }
    // Incompressible pixels should never cost more wire bytes than raw RGBA.
    compressed = compressed && packedSize < [pixels length];
    if (compressed) [packed setLength:packedSize];
    CFAbsoluteTime packedAt = profile ? CFAbsoluteTimeGetCurrent() : 0;
    NSMutableData *out = [NSMutableData dataWithData:[[NSString stringWithFormat:@"%d %lu %lu %d %d\n",
        wid, (unsigned long)w, (unsigned long)h, compressed ? encoding : 0, sequence] dataUsingEncoding:NSASCIIStringEncoding]];
    [out appendData:compressed ? packed : pixels];
    if (profile) fprintf(stderr, "PECAPTURE id=%d seq=%d unchanged=0 setupMS=%.3f captureMS=%.3f compareMS=%.3f cacheMS=%.3f compressMS=%.3f packetMS=%.3f totalMS=%.3f bytes=%lu\n",
        wid, sequence, (allocated-began)*1000, (captured-allocated)*1000,
        (compared-captured)*1000, (cached-compared)*1000, (packedAt-cached)*1000,
        (CFAbsoluteTimeGetCurrent()-packedAt)*1000, (CFAbsoluteTimeGetCurrent()-began)*1000,
        (unsigned long)[out length]);
    return out;
}

/* Persistent image transport, independent of input/menu traffic. Reopening
 * guestfwd for every frame launches a new host bridge process each time. */
- (void)captureWorker:(NSArray *)job
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (![captureLock tryLock]) { [pool drain]; return; }
    NSString *request = [job objectAtIndex:0], *session = [job objectAtIndex:1];
    if (![workerFrameSession isEqualToString:session]) {
        [captureHistory removeAllObjects];
        if (captureContext) CGContextRelease(captureContext);
        captureContext = NULL;
        captureScratchReusable = NO;
        [captureScratch release]; captureScratch = nil;
        if (frameSock >= 0) close(frameSock);
        frameSock = -1;
        [workerFrameSession release]; workerFrameSession = [session copy];
    }
    NSData *payload = [self captureWindow:request];
    BOOL profile = getenv("POWEREMU_CAPTURE_PROFILE") != NULL;
    CFAbsoluteTime deliveryBegan = profile ? CFAbsoluteTimeGetCurrent() : 0;
    BOOL delivered = NO;
    NSMutableData *packet = [NSMutableData data];
    if (frameSock < 0) {
        frameSock = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        struct timeval timeout = {2, 0};
        setsockopt(frameSock, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        setsockopt(frameSock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
        setsockopt(frameSock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        struct sockaddr_in address;
        memset(&address, 0, sizeof address);
        address.sin_len = sizeof address; address.sin_family = AF_INET;
        address.sin_port = htons(AgentPort()); address.sin_addr.s_addr = inet_addr(AgentHost());
        if (frameSock >= 0 && connect(frameSock, (struct sockaddr *)&address, sizeof address) != 0) {
            close(frameSock); frameSock = -1;
        }
        NSData *hello = [session dataUsingEncoding:NSUTF8StringEncoding];
        [packet appendData:[[NSString stringWithFormat:@"FRAMEHELLO %u\n", (unsigned)[hello length]] dataUsingEncoding:NSASCIIStringEncoding]];
        [packet appendData:hello];
    }
    if (frameSock >= 0) {
        [packet appendData:[[NSString stringWithFormat:@"WINDOWFRAME %u\n", (unsigned)[payload length]] dataUsingEncoding:NSASCIIStringEncoding]];
        [packet appendData:payload];
        const char *bytes = [packet bytes]; size_t left = [packet length];
        while (left) {
            ssize_t n = write(frameSock, bytes, left);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { close(frameSock); frameSock = -1; break; }
            bytes += n; left -= n;
        }
        delivered = left == 0;
    }
    if (profile) fprintf(stderr, "PEDELIVERY request=%s socketWriteMS=%.3f bytes=%lu delivered=%d\n",
        [request UTF8String], (CFAbsoluteTimeGetCurrent()-deliveryBegan)*1000,
        (unsigned long)[packet length], (int)delivered);
    [captureLock unlock];
    [pool drain];
}

- (void)retryLater
{
    [self performSelector:@selector(connect) withObject:nil afterDelay:5.0];
}

- (void)connect
{
    if (sock >= 0) return;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { [self retryLater]; return; }
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons(AgentPort());
    a.sin_addr.s_addr = inet_addr(AgentHost());
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) {
        close(s);
        [self retryLater];
        return;
    }
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    // A dead host bridge must not block the guest's main run loop forever
    // while it sends a menu/window report. Reconnect on a stalled write.
    struct timeval controlWriteTimeout = {2, 0};
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &controlWriteTimeout, sizeof controlWriteTimeout);
    sock = s;
    [inbox setLength:0];
    handle = [[NSFileHandle alloc] initWithFileDescriptor:s closeOnDealloc:NO];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(received:)
        name:NSFileHandleReadCompletionNotification object:handle];
    [handle readInBackgroundAndNotify];

    NSDictionary *sv = [NSDictionary dictionaryWithContentsOfFile:
        @"/System/Library/CoreServices/SystemVersion.plist"];
    NSString *hello = [NSString stringWithFormat:@"%s\t%@\t%@", PE_AGENT_VERSION,
        [sv objectForKey:@"ProductVersion"], NSUserName()];
    [self send:@"HELLO" text:hello];
}

- (void)disconnected
{
    sheetEpoch++;
    if (sock < 0) return;
    if(pointerButtons) {
        Point location;GetGlobalMouse(&location);
        CGPostKeyboardEvent(0,53,true);CGPostKeyboardEvent(0,53,false);
        CGPostMouseEvent(CGPointMake(location.h,location.v),true,3,false,false,false);
        pointerButtons=0;
    }
    fileDragWindow=0;[fileDragSourcePath release];fileDragSourcePath=nil;[fileDragPaths release];fileDragPaths=nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:NSFileHandleReadCompletionNotification object:handle];
    [handle release];
    handle = nil;
    close(sock);
    sock = -1;
    [self retryLater];
}

- (void)received:(NSNotification *)n
{
    if ([n object] != handle) return;  // a completion from a retired connection
    NSData *d = [[n userInfo] objectForKey:NSFileHandleNotificationDataItem];
    if ([d length] == 0) { [self disconnected]; return; }
    [inbox appendData:d];
    [self processInbox];
    if (handle) [handle readInBackgroundAndNotify];
}

- (void)processInbox
{
    for (;;) {
        const char *b = [inbox bytes];
        unsigned len = [inbox length];
        const char *nl = memchr(b, '\n', len);
        if (!nl) return;
        NSString *head = [[[NSString alloc] initWithBytes:b length:nl - b
            encoding:NSASCIIStringEncoding] autorelease];
        NSArray *parts = [head componentsSeparatedByString:@" "];
        unsigned size = [parts count] > 1 ? (unsigned)[[parts objectAtIndex:1] intValue] : 0;
        unsigned start = (nl - b) + 1;
        if (len < start + size) return;             /* payload not all here yet */
        NSData *payload = [inbox subdataWithRange:NSMakeRange(start, size)];
        [self handle:[parts objectAtIndex:0] payload:payload];
        [inbox replaceBytesInRange:NSMakeRange(0, start + size) withBytes:NULL length:0];
    }
}

- (void)handle:(NSString *)verb payload:(NSData *)payload
{
    NSString *text = [[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] autorelease];
    if ([verb isEqualToString:@"HELLO"]) {
        NSArray *f = [text componentsSeparatedByString:@" "];
        if ([f count] >= 3) { [controlFrameSession release]; controlFrameSession = [[f objectAtIndex:2] copy]; }
    } else if ([verb isEqualToString:@"CLIP"]) {
        if (!text) return;
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
        [pb setString:text forType:NSStringPboardType];
        lastChangeCount = [pb changeCount];
        [lastClip release];
        lastClip = [text copy];
    } else if ([verb isEqualToString:@"SHUTDOWN"]) {
        SendLoginwindowEvent(kAEShutDown);
    } else if ([verb isEqualToString:@"RESTART"]) {
        SendLoginwindowEvent(kAERestart);
    } else if ([verb isEqualToString:@"MOUNT"]) {
        [self mount:text];
    } else if ([verb isEqualToString:@"UNMOUNT"]) {
        [self unmount:text];
    } else if ([verb isEqualToString:@"CHANGED"]) {
        [self changed:text];
    } else if ([verb isEqualToString:@"HARMONY"]) {
        [self harmony:[text isEqualToString:@"1"]];
    } else if ([verb isEqualToString:@"CAPTUREMODE"]) {
        completeCaptureMode = [text isEqualToString:@"1"];
    } else if ([verb isEqualToString:@"PREPAREHARMONY"]) {
        NSArray *f = [text componentsSeparatedByString:@" "];
        if ([f count] == 3) {
            CGDirectDisplayID display = CGMainDisplayID();
            if (CGDisplayIsCaptured(display)) {
                [self send:@"FULLSCREEN" data:[@"captured" dataUsingEncoding:NSUTF8StringEncoding]];
                return;
            }
            [self setResolution:[NSString stringWithFormat:@"%@ %@", [f objectAtIndex:1], [f objectAtIndex:2]]];
            int w = (int)CGDisplayPixelsWide(display), h = (int)CGDisplayPixelsHigh(display);
            BOOL ok = w == [[f objectAtIndex:1] intValue] && h == [[f objectAtIndex:2] intValue];
            [self send:@"HARMONYREADY" text:[NSString stringWithFormat:@"%@ %d %d %d", [f objectAtIndex:0], w, h, ok]];
        }
    } else if ([verb isEqualToString:@"FOCUSWINDOW"]) {
        NSArray *f = [text componentsSeparatedByString:@" "];
        if ([f count] == 2) {
            focusRequestSequence = [[f objectAtIndex:1] intValue];
            [self raiseWindow:[f objectAtIndex:0]];
            [self confirmFocus:[NSArray arrayWithObjects:[f objectAtIndex:0], [f objectAtIndex:1], @"0", nil]];
        }
    } else if ([verb isEqualToString:@"POINTER"]) {
        int x, y, buttons;
        if (sscanf([text UTF8String], "%d %d %d", &x, &y, &buttons) == 3) {
            CGPoint point = CGPointMake(x, y);
            CGError result = CGPostMouseEvent(point, true, 3, (buttons & 1) != 0, (buttons & 2) != 0, (buttons & 4) != 0);
            if (buttons != pointerButtons) {
                [self send:@"LOG" text:[NSString stringWithFormat:@"POINTER %d %d buttons=%d result=%d", x, y, buttons, result]];
                pointerButtons = buttons;
            }
        }
    } else if ([verb isEqualToString:@"RESOLUTION"]) {
        [self setResolution:text];
    } else if ([verb isEqualToString:@"RAISE"]) {
        [self raiseWindow:text];
    } else if ([verb isEqualToString:@"RAISEHARD"]) {
        /* The application comes up with the window.  PowerEmu's capture pass
         * uses this when it must be certain a window really is on top. */
        raiseBringsAppForward = YES;
        [self raiseWindow:text];
        raiseBringsAppForward = NO;
    } else if ([verb isEqualToString:@"MOVEWINDOW"]) {
        [self moveWindow:text];
    } else if ([verb isEqualToString:@"MINIMIZE"]) {
        [self minimizeWindow:text];
    } else if ([verb isEqualToString:@"UNMINIMIZE"]) {
        NSArray *f = [text componentsSeparatedByString:@" "];
        if ([f count] >= 2) {
            pid_t pid = (pid_t)[[f objectAtIndex:0] intValue];
            CFIndex idx = (CFIndex)[[f objectAtIndex:1] intValue];
            AXUIElementRef app = pid > 0 ? AXUIElementCreateApplication(pid) : NULL;
            CFArrayRef wins = NULL;
            if (app && AXUIElementCopyAttributeValue(app, kAXWindowsAttribute,
                                                     (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
                if (idx >= 0 && idx < CFArrayGetCount(wins)) {
                    AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(wins, idx);
                    AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanFalse);
                    AXUIElementPerformAction(win, kAXRaiseAction);
                }
                CFRelease(wins);
            }
            if (app) CFRelease(app);
            if (pid > 0) {
                ProcessSerialNumber psn;
                if (GetProcessForPID(pid, &psn) == noErr) SetFrontProcess(&psn);
            }
        }
    } else if ([verb isEqualToString:@"FILEDRAGARM"]) {
        [self armFileDrag:text];
    } else if ([verb isEqualToString:@"FILETRANSFER"]) {
        id request=[NSPropertyListSerialization propertyListFromData:payload mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:NULL];
        if([request isKindOfClass:[NSDictionary class]])[self fileTransfer:request];
    } else if ([verb isEqualToString:@"QUITAPP"]) {
        /* Somebody quit the application's tile in this Mac's Dock. */
        pid_t qp = (pid_t)[text intValue];
        ProcessSerialNumber qpsn;
        if (qp > 0 && GetProcessForPID(qp, &qpsn) == noErr) {
            AppleEvent ev, reply;
            AEDesc target;
            if (AECreateDesc(typeProcessSerialNumber, &qpsn, sizeof(qpsn), &target) == noErr) {
                if (AECreateAppleEvent(kCoreEventClass, kAEQuitApplication, &target,
                                       kAutoGenerateReturnID, kAnyTransactionID, &ev) == noErr) {
                    AESend(&ev, &reply, kAENoReply, kAENormalPriority,
                           kAEDefaultTimeout, NULL, NULL);
                    AEDisposeDesc(&ev);
                }
                AEDisposeDesc(&target);
            }
        }
    } else if ([verb isEqualToString:@"WINDOWFRAME"]) {
        if (!captureLock) captureLock = [[NSLock alloc] init];
        if (controlFrameSession) [NSThread detachNewThreadSelector:@selector(captureWorker:) toTarget:self withObject:[NSArray arrayWithObjects:text, controlFrameSession, nil]];
    } else if ([verb isEqualToString:@"APPICON"]) {
        [self sendAppIcon:text];
    } else if ([verb isEqualToString:@"MENUS"]) {
        menuBarPid = 0;
        [self reportFocused];
    } else if ([verb isEqualToString:@"MENUITEMS"]) {
        [self reportMenuItems:text];
    } else if ([verb isEqualToString:@"MENUPICK"]) {
        [self pickMenuItem:text];
    } else if ([verb isEqualToString:@"ACTIVATE"]) {
        pid_t pid = (pid_t)[text intValue];
        ProcessSerialNumber psn;
        if (pid > 0 && GetProcessForPID(pid, &psn) == noErr) {
            SetFrontProcess(&psn);
        }
    } else if ([verb isEqualToString:@"LAUNCH"]) {
        /*
         * Open one of the applications in this Mac's Dock.
         *
         * Harmony hides the Dock, because two of them on one screen is one too
         * many -- but the Dock is where somebody keeps the applications they
         * actually use, so hiding it takes away the way in to anything that is
         * not already running.  PowerEmu shows the same list on its own side
         * and sends the choice back here.
         */
        if ([text length]) {
            [[NSWorkspace sharedWorkspace] launchApplication:text];
        }
    } else if ([verb isEqualToString:@"DOCKAPPS"]) {
        [self sendDockApps];
    } else if ([verb isEqualToString:@"PING"]) {
        [self send:@"PONG" data:nil];
    }
}

/*
 * Harmony: stop drawing the things that are not windows.
 *
 * PowerEmu can hide the desktop from the host's side -- it watches what is
 * copied to the screen and makes everything that is not a window
 * transparent -- but working out which is which from the copies alone is
 * guesswork, and the Dock in particular arrives looking exactly like a
 * window.  It is far better to ask this Mac not to draw them.
 *
 * SetSystemUIMode is no use here: it applies to the application that calls
 * it, and this agent is never the front one.  So the Dock is told to hide
 * itself and the Finder to stop drawing the desktop, which is what somebody
 * would do by hand, and both are put back afterwards.
 */
- (void)run:(NSString *)tool with:(NSArray *)args
{
    NSTask *t = [[NSTask alloc] init];
    [t setLaunchPath:tool];
    [t setArguments:args];
    NS_DURING
        [t launch];
        [t waitUntilExit];
    NS_HANDLER
        /* A Mac without the tool is not a reason to take the agent down. */
    NS_ENDHANDLER
    [t release];
}

- (void)set:(NSString *)domain key:(NSString *)key yes:(BOOL)yes keep:(BOOL)keep
{
    NSString *defaults = @"/usr/bin/defaults";
    if (keep) {
        [self run:defaults with:[NSArray arrayWithObjects:@"write", domain, key,
            @"-bool", yes ? @"true" : @"false", nil]];
    } else {
        [self run:defaults with:[NSArray arrayWithObjects:@"delete", domain, key, nil]];
    }
}

- (void)harmony:(BOOL)on
{
    sheetEpoch++;
    // Host reconnects reconcile both states. Repeating the current state must
    // not restart Finder or overwrite the preferences remembered on entry.
    if (!on && !windowTimer) return;
    // Restarting Finder/Dock during an exclusive game can steal focus.
    // Show the full guest immediately on the host, but restore guest desktop
    // preferences only after the application releases its display.
    if (!on && CGDisplayIsCaptured(CGMainDisplayID())) {
        deferredHarmonyExit = YES;
        return;
    }
    deferredHarmonyExit = NO;
    if (on && windowTimer) {
        menuBarPid = 0;
        [self reportWindows:nil];
        return;
    }
    if (on) PERefreshAccessibilityState();
    memset(&fullscreenState, 0, sizeof(fullscreenState));
    NSString *killall = @"/usr/bin/killall";

    /*
     * Remember what this Mac looked like before each session, so turning Harmony
     * off puts back what the reader had rather than what we assume they had.
     */
    if (!harmonyRemembered) {
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        NSDictionary *dock = [u persistentDomainForName:@"com.apple.dock"];
        NSDictionary *finder = [u persistentDomainForName:@"com.apple.finder"];
        dockHadAutohide = [dock objectForKey:@"autohide"] != nil;
        dockWasAutohidden = [[dock objectForKey:@"autohide"] boolValue];
        finderHadDesktopKey = [finder objectForKey:@"CreateDesktop"] != nil;
        finderDrewDesktop = !finderHadDesktopKey
                          || [[finder objectForKey:@"CreateDesktop"] boolValue];
        harmonyRemembered = YES;
    }

    /*
     * Turning Harmony off puts this Mac back as it was, and a setting that
     * was never there is removed rather than written: a Mac that had no
     * opinion about its Dock should not be left with one because PowerEmu
     * borrowed it for an afternoon.
     */
    [self set:@"com.apple.dock" key:@"autohide"
          yes:on ? YES : dockWasAutohidden
         keep:on || dockHadAutohide];
    /*
     * Auto-hiding alone is not enough: the Dock still slides out whenever the
     * pointer touches the bottom of the screen, and in Harmony that bottom edge
     * is this Mac's, not the guest's.  Pin it away by making it take a thousand
     * seconds to decide to appear, and no time at all to go.  Both settings are
     * removed again on the way out, so a reader who set their own keeps it.
     */
    NSString *defaultsTool = @"/usr/bin/defaults";
    if (on) {
        [self run:defaultsTool with:[NSArray arrayWithObjects:@"write", @"com.apple.dock",
             @"autohide-delay", @"-float", @"1000", nil]];
        [self run:defaultsTool with:[NSArray arrayWithObjects:@"write", @"com.apple.dock",
             @"autohide-time-modifier", @"-float", @"0", nil]];
    } else {
        [self run:defaultsTool with:[NSArray arrayWithObjects:@"delete", @"com.apple.dock",
             @"autohide-delay", nil]];
        [self run:defaultsTool with:[NSArray arrayWithObjects:@"delete", @"com.apple.dock",
             @"autohide-time-modifier", nil]];
    }
    [self run:killall with:[NSArray arrayWithObject:@"Dock"]];

    /* Finder may restore older windows when restarted. Do not try to close
     * them by comparing titles: titles change, duplicate names are common,
     * and a delayed pass can close windows opened by the user meanwhile.
     * Harmony transitions must never issue Finder window-close commands. */
    /* Complete backing-store capture excludes desktop windows already. Keep
     * Finder alive so current folders, window identities and unsaved UI state
     * survive. Legacy screen masking still needs CreateDesktop. Latch this
     * choice: the host sends CAPTUREMODE 0 before HARMONY 0 on exit. */
    if (on) harmonyChangedFinder = !completeCaptureMode;
    if (harmonyChangedFinder) {
        [self set:@"com.apple.finder" key:@"CreateDesktop"
              yes:on ? NO : finderDrewDesktop
             keep:on || finderHadDesktopKey];
        [self run:killall with:[NSArray arrayWithObject:@"Finder"]];
    }

    [self send:@"LOG" data:[(on ? @"harmony on" : @"harmony off")
                            dataUsingEncoding:NSUTF8StringEncoding]];

    /*
     * While Harmony is on, keep PowerEmu told where the windows are.  It shows
     * exactly those and leaves the rest of the guest's screen -- wallpaper,
     * menu bar, Dock, everything -- see-through, so nothing of the guest's own
     * desktop leaks onto this Mac's.
     */
    if (on) {
        menuBarPid = 0;                 /* report the front app's menus afresh */
        if (!windowTimer) {
            /* ~30 Hz: fast enough that the mask keeps up with a dragged window,
             * so no strip of desktop shows along its trailing edge. */
            /* Twelve times a second is plenty: PowerEmu redraws a window from
             * the frames the card produces, not from this report, and windows
             * are dragged on the host's side.  Thirty had the guest walking its
             * whole window list -- a CGS round trip each -- often enough to be
             * felt in everything else it was doing. */
            /* Twenty-four times a second.  It was twelve, to spare the guest
             * -- but the emulator turns out to be using under half a core even
             * while the guest holds thirty frames a second, and what this
             * report costs buys a much tighter answer about what covers what,
             * which is what decides whether a window may be read at all. */
            windowTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0 / 24.0 target:self
                selector:@selector(reportWindows:) userInfo:nil repeats:YES] retain];
        }
        [self reportWindows:nil];
        [self setMinimiseEffect:@"scale"];
    } else {
        [self setMinimiseEffect:nil];
        [windowTimer invalidate];
        [windowTimer release];
        windowTimer = nil;
        harmonyChangedFinder = NO;
        harmonyRemembered = NO;
        menuBarPid = 0;
        [self send:@"DRAGWINDOWS" text:@""];
        [self send:@"SHEETS" text:@""];
        [self send:@"WINDOWS" text:@""];        /* clear the mask */
        [self send:@"MENUS" text:@""];          /* give this Mac its menus back */
    }
}

/*
 * Genie or scale, while Harmony is on.
 *
 * The other Mac shows this one's windows by copying them out of the screen
 * everything is drawn into, so this Mac's minimize animation is drawn over the
 * top of whatever it passes -- and it is drawn by the window server itself,
 * not as a window, so nothing PowerEmu can ask about windows will admit it is
 * there.  The genie sweeps most of the screen for most of a second.  Scale is
 * smaller and much shorter, so there is far less of it to go wrong, and it is
 * what was asked for anyway.  Whatever was set before comes back when Harmony
 * does.
 */
- (void)setMinimiseEffect:(NSString *)effect
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *dock = [d persistentDomainForName:@"com.apple.dock"];
    NSMutableDictionary *m = dock ? [[dock mutableCopy] autorelease]
                                  : [NSMutableDictionary dictionary];
    NSString *now = [m objectForKey:@"mineffect"];
    if (effect) {
        if ([now isEqualToString:effect]) return;       /* already there */
        if (!savedMinEffect) savedMinEffect = [(now ? now : @"") retain];
        [m setObject:effect forKey:@"mineffect"];
    } else {
        if (!savedMinEffect) return;                    /* never changed it */
        if ([savedMinEffect length]) [m setObject:savedMinEffect forKey:@"mineffect"];
        else [m removeObjectForKey:@"mineffect"];
        [savedMinEffect release];
        savedMinEffect = nil;
    }
    [d setPersistentDomain:m forName:@"com.apple.dock"];
    [d synchronize];
    /* The Dock only reads this when it starts.  It is hidden in Harmony and
     * comes back by itself, so this is cheaper than it looks. */
    system("/usr/bin/killall Dock >/dev/null 2>&1");
}

/*
 * The rectangles of the guest's on-screen windows, in screen points, as
 * "x,y,w,h;x,y,w,h;...".  The desktop, the Dock and the menu bar are left out
 * by their window level, so PowerEmu masks them away.  Menus, palettes and
 * dialogs are windows and are kept.
 */
/*
 * Say which window is on top, and which application's menus go with it.
 *
 * Sent on every report, and again the moment a window is raised: waiting for
 * the next report put a twelfth of a second between clicking a window and
 * PowerEmu believing it, which showed as the window not coming alive and this
 * Mac's menu bar still carrying the application the user had just left.
 */
/*
 * What covers what, worked out by asking the window server which of two
 * windows it draws where they overlap.
 *
 * Asking once, at the middle of the overlap, is not enough, and that was the
 * bug: when some third window happened to own that one point, the server
 * answered neither of the two being compared, and the pair was abandoned --
 * so a window really sitting over another went unrecorded, and PowerEmu read
 * the covered one out of the shared frame with its neighbor's pixels baked
 * in.  Each surface ended up carrying pieces of the others.
 *
 * So each pair is now sampled until the server names one of the two, which
 * settles which is on top -- and since the stack is a single order, that one
 * answer holds across the whole overlap.  A pair the server never settles
 * (every sample owned by something PowerEmu was not told about, such as a
 * screensaver) is taken as covering both ways: the windows keep their last
 * good copy rather than absorb something unknown.
 */
#define PE_OCCL_MAX 96
/*
 * How many passes in a row an unlisted window has been seen over this one.
 * Kept by window id, because the index into a pass's arrays is not the same
 * thing from one pass to the next.
 */
static int pe_unknown_set(CGSWindowID wid, int seen)
{
    static CGSWindowID ids[PE_OCCL_MAX];
    static int runs[PE_OCCL_MAX];
    static int used;
    int i, free_slot = -1;

    for (i = 0; i < used; i++) {
        if (ids[i] == wid) {
            runs[i] = seen ? runs[i] + 1 : 0;
            return runs[i];
        }
        if (runs[i] == 0 && free_slot < 0) free_slot = i;
    }
    if (used < PE_OCCL_MAX) free_slot = used++;
    if (free_slot < 0) return seen;         /* full: fail safe, count it once */
    ids[free_slot] = wid;
    runs[free_slot] = seen ? 1 : 0;
    return runs[free_slot];
}
- (void)reportOcclusion:(CGSWindowID *)ids rects:(CGRect *)rects count:(int)n report:(int)report
{
    __strong NSString **occlSigOut = NULL;
    static const float fx[] = { .5, .25, .75, .25, .75, .5, .5, .08, .92 };
    static const float fy[] = { .5, .25, .25, .75, .75, .08, .92, .5, .5 };
    static unsigned char over[PE_OCCL_MAX][PE_OCCL_MAX];
    static unsigned char unknown[PE_OCCL_MAX];
    CGSConnectionID cid = _CGSDefaultConnection();
    NSMutableString *out = [NSMutableString string];
    int i, j, probes = 0;
    CFAbsoluteTime occlBegan = CFAbsoluteTimeGetCurrent();
    int occlProbes = 0;
    (void)occlProbes;
    if (!PEFindWindow()) return;                /* nothing to say without it */
    if (n > PE_OCCL_MAX) n = PE_OCCL_MAX;
    /*
     * Nothing has moved, so nothing can be covering anything new.
     *
     * Working this out means asking the window server about a point at a time,
     * each one a round trip, and this Mac is being emulated: measured at seven
     * windows it was seventeen milliseconds a pass, twenty-four times a
     * second -- some forty per cent of the processor, spent almost entirely on
     * re-deriving an answer identical to the last one.  The virtual Mac cannot
     * spare that.  It is also the reason the picture froze for seconds at a
     * time: the other Mac only gets a frame when the emulator can be
     * interrupted to hand one over, and a guest with no processor left to give
     * hands over nothing.
     *
     * Which window is drawn where depends on where the windows are and how
     * they are stacked, and both of those are in the list already: same list,
     * same rectangles, same front window, same answer.  So it is worked out
     * afresh only when one of them changes, and the previous answer is re-sent
     * otherwise -- sent, not skipped, because the other side treats each
     * answer as the moment its pixels belong to.
     */
    {
        static NSString *lastSig, *lastOut;
        NSMutableString *sig = [NSMutableString stringWithFormat:@"%d/%d;", n, report];
        int k;
        for (k = 0; k < n; k++) {
            [sig appendFormat:@"%d,%d,%d,%d,%d;", (int)ids[k],
                 (int)rects[k].origin.x, (int)rects[k].origin.y,
                 (int)rects[k].size.width, (int)rects[k].size.height];
        }
        /*
         * And which application is in front.  The list's own order carries
         * most of a stacking change already -- it is grouped by connection,
         * and a raise reorders the group -- but a window coming forward within
         * one application need not move anything in it, and reusing the last
         * answer through that is exactly how a window ends up holding a piece
         * of its neighbor.  Two calls, against dozens of round trips saved.
         */
        {
            ProcessSerialNumber front;
            if (GetFrontProcess(&front) == noErr) {
                [sig appendFormat:@"f%u.%u", (unsigned)front.highLongOfPSN,
                     (unsigned)front.lowLongOfPSN];
            }
        }
        if (lastSig && lastOut && [sig isEqualToString:lastSig]) {
            [self send:@"OCCLUDE" text:lastOut];
            return;
        }
        [lastSig release];
        lastSig = [sig copy];
        occlSigOut = &lastOut;
    }
    if (report > n) report = n;
    memset(over, 0, sizeof over);
    memset(unknown, 0, sizeof unknown);
    /*
     * Only the windows PowerEmu draws need an answer, but anything at all can
     * be the thing covering them, so the pairs run against the whole list --
     * the Dock and the menu bar included.  A pair with both indices below
     * `report` is still tested once: when the lower of the two is the outer.
     */
    for (i = 0; i < report; i++) {
        for (j = i + 1; j < n; j++) {
            CGRect hit = CGRectIntersection(rects[i], rects[j]);
            int s, settled = 0;
            if (CGRectIsEmpty(hit) || hit.size.width < 2 || hit.size.height < 2) continue;
            for (s = 0; s < (int)(sizeof fx / sizeof fx[0]) && !settled; s++) {
                CGPoint p = CGPointMake(hit.origin.x + hit.size.width * fx[s],
                                        hit.origin.y + hit.size.height * fy[s]);
                CGSWindowID at;
                if (probes >= 600) break;       /* a busy screen stays cheap */
                at = PEWindowAtPoint(cid, p);
                probes++;
                if (at == ids[i])      { over[i][j] = 1; settled = 1; }
                else if (at == ids[j]) { over[j][i] = 1; settled = 1; }
            }
            if (!settled) { over[i][j] = 1; over[j][i] = 1; }
        }
    }
    /*
     * Something nobody told us about.
     *
     * The pair test can only speak about windows it was given, so a window
     * with nothing tracked over it reads as clear even when it is buried --
     * which is what the screensaver did: it covers the screen, it is in
     * nobody's list, and every window cheerfully absorbed black and kept it.
     * So a window with nothing known over it is also asked about directly, at
     * a few points of its own, and an answer naming something that is not in
     * the list at all means it cannot be read.
     *
     * Twice, though, before it counts.  The window list is gathered a moment
     * before these points are sampled, so anything that appears in between --
     * a menu coming down, a window being dragged, a sheet opening -- is
     * momentarily "not in the list", and taking that at face value threw away
     * whole windows for a frame at a time.  While dragging, where something is
     * changing constantly, that was most of them: the desktop showed through,
     * and it took until everything went quiet to recover.  A screensaver is
     * still there on the next pass; a window that was mid-flight is not.
     */
    for (i = 0; i < report; i++) {
        int s2, any = 0, hit = 0;
        for (j = 0; j < n; j++) if (over[j][i]) { any = 1; break; }
        if (any) {
            pe_unknown_set(ids[i], 0);
            continue;               /* already covered; no need to ask */
        }
        for (s2 = 0; s2 < 3 && !hit; s2++) {
            CGPoint p = CGPointMake(rects[i].origin.x + rects[i].size.width * fx[s2],
                                    rects[i].origin.y + rects[i].size.height * fy[s2]);
            CGSWindowID at;
            int k, known = 0;
            if (probes >= 900) break;
            at = PEWindowAtPoint(cid, p);
            probes++;
            if (at == 0 || at == ids[i]) continue;   /* clear, or cannot be told */
            for (k = 0; k < n; k++) if (ids[k] == at) { known = 1; break; }
            if (!known) hit = 1;
        }
        unknown[i] = pe_unknown_set(ids[i], hit) >= 2;
    }
    for (i = 0; i < report; i++) {
        NSMutableString *covers = [NSMutableString string];
        if (unknown[i]) {
            [out appendFormat:@"%d\t%d,%d,%d,%d\n", (int)ids[i],
                 (int)rects[i].origin.x, (int)rects[i].origin.y,
                 (int)rects[i].size.width, (int)rects[i].size.height];
            continue;
        }
        for (j = 0; j < n; j++) {
            CGRect hit;
            if (!over[j][i]) continue;
            hit = CGRectIntersection(rects[i], rects[j]);
            if (CGRectIsEmpty(hit)) continue;
            [covers appendFormat:@"%s%d,%d,%d,%d", [covers length] ? "|" : "",
                 (int)hit.origin.x, (int)hit.origin.y,
                 (int)hit.size.width, (int)hit.size.height];
        }
        if ([covers length]) [out appendFormat:@"%d\t%@\n", (int)ids[i], covers];
    }
    if (occlSigOut) {
        [*occlSigOut release];
        *occlSigOut = [out copy];
    }
    [self send:@"OCCLUDE" text:out];
    /*
     * What this pass cost.
     *
     * Every one of those points is a round trip to the window server, on a
     * machine that is being emulated, and the whole of Harmony's timing rests
     * on these reports arriving at the rate they claim to.  Twice a second,
     * say how many were asked and how long it took, so a report that has
     * quietly stopped keeping up shows as a number rather than as a guess
     * about why dragging looks wrong.
     */
    {
        static CFAbsoluteTime lastSaid;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        occlProbes = probes;
        if (now - lastSaid > 2.0) {
            lastSaid = now;
            [self send:@"LOG" text:[NSString stringWithFormat:
                @"OCCL windows=%d occluders=%d probes=%d took=%.1fms",
                report, n - report, probes, (now - occlBegan) * 1000.0]];
        }
    }
    if (!hitTestProbed) {
        hitTestProbed = 1;
        [self send:@"LOG" text:[NSString stringWithFormat:@"HITTEST available=1 windows=%d\n%@",
                                n, out]];
    }
}

/*
 * The icon of one of the guest's applications, so this Mac can put it in its
 * own Dock.  "APPICON <pid>" comes back as the pid, a newline, and a PNG.
 */
- (void)sendAppIcon:(NSString *)pidStr
{
    pid_t pid = (pid_t)[pidStr intValue];
    ProcessSerialNumber psn;
    FSRef ref;
    NSImage *icon = nil;
    NSMutableData *out;

    if (pid <= 0 || GetProcessForPID(pid, &psn) != noErr) return;
    if (GetProcessBundleLocation(&psn, &ref) == noErr) {
        CFURLRef url = CFURLCreateFromFSRef(NULL, &ref);
        if (url) {
            NSString *path = [(NSURL *)url path];
            icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
            CFRelease(url);
        }
    }
    if (!icon) return;

    /* 128 square: big enough for this Mac's Dock at any size it is set to. */
    [icon setSize:NSMakeSize(128, 128)];
    {
        NSBitmapImageRep *rep;
        NSData *png;
        NSImage *flat = [[[NSImage alloc] initWithSize:NSMakeSize(128, 128)] autorelease];
        [flat lockFocus];
        [icon drawInRect:NSMakeRect(0, 0, 128, 128)
                fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
        rep = [[[NSBitmapImageRep alloc]
                   initWithFocusedViewRect:NSMakeRect(0, 0, 128, 128)] autorelease];
        [flat unlockFocus];
        png = [rep representationUsingType:NSPNGFileType properties:nil];
        if (!png) return;
        out = [NSMutableData dataWithData:
                  [[NSString stringWithFormat:@"%d\n", (int)pid]
                      dataUsingEncoding:NSUTF8StringEncoding]];
        [out appendData:png];
    }
    [self send:@"APPICON" data:out];
}

#include "PEFileTransfer.inc"

- (void)reportFocused
{
    CGSConnectionID cid = _CGSDefaultConnection();

/*
 * Which window is actually on top.
 *
 * The whole on-screen list is grouped by connection, so its order is wrong
 * across applications -- but within one connection it is right.  So: ask
 * the front application for its own windows, and take the first one.
 * Activating an application brings its front window to the very top (and
 * only that one), so that window is the topmost window on the screen, and
 * the only one PowerEmu can read whole.
 *
 * This is deliberately not the Accessibility "focused" window: a palette or
 * a drawer can sit above the window holding the keyboard focus, and reading
 * the focused window then would copy the palette's pixels into it.
 */
    ProcessSerialNumber front = {0, 0};
    CGSConnectionID theirs = 0;
    CGSWindowID focused = 0;
    if (GetFrontProcess(&front) == noErr
        && CGSGetConnectionIDForPSN(cid, &front, &theirs) == kCGErrorSuccess) {
        CGSWindowID mine[128];
        int n = 0, k;
        if (CGSGetOnScreenWindowList(cid, theirs, 128, mine, &n) == kCGErrorSuccess) {
            for (k = 0; k < n; k++) {
                int lvl = 0;
                CGRect wr;
                if (CGSGetWindowLevel(cid, mine[k], &lvl) != kCGErrorSuccess) continue;
                if (lvl < 0 || (lvl >= 20 && lvl <= 25) || lvl == CGWindowLevelForKey(kCGDraggingWindowLevelKey)) continue;
                if (CGSGetScreenRectForWindow(cid, mine[k], &wr) != kCGErrorSuccess) continue;
                if (wr.size.width < 1 || wr.size.height < 1) continue;
                focused = mine[k];
                break;
            }
        }
    }
    [self send:@"FOCUSED" text:[NSString stringWithFormat:@"%d", (int)focused]];
    /*
     * And whose menus they are.  This used to be noticed only on the next
     * report, so this Mac's menu bar went on showing the application the user
     * had just clicked away from.
     */
    {
        pid_t fpid = 0;
        if (GetProcessPID(&front, &fpid) == noErr && fpid > 0 &&
            (fpid != menuBarPid || CFAbsoluteTimeGetCurrent() - menuBarReportedAt >= 2.0)) {
            if ([self reportMenuBarFor:fpid]) {
                menuBarPid = fpid;
                menuBarReportedAt = CFAbsoluteTimeGetCurrent();
            }
        }
    }
}

- (void)reportWindows:(NSTimer *)t
{
    if (deferredHarmonyExit) {
        if (!CGDisplayIsCaptured(CGMainDisplayID())) [self harmony:NO];
        return;
    }
    // Exclusive full-screen games can bypass normal window backing stores.
    // Test display ownership, not window size or our own hidden menu bar.
    if (PEFullscreenUpdate(&fullscreenState, CGDisplayIsCaptured(CGMainDisplayID()),
                           [NSDate timeIntervalSinceReferenceDate])) {
        [self send:@"FULLSCREEN" data:[@"captured" dataUsingEncoding:NSUTF8StringEncoding]];
    }
    CGSConnectionID cid = _CGSDefaultConnection();
    CGSWindowID list[512];
    CGRect above[512];
    int count = 0, nAbove = 0;
    if (CGSGetOnScreenWindowList(cid, 0, 512, list, &count) != kCGErrorSuccess) {
        return;
    }
    NSMutableString *s = [NSMutableString string];
    NSMutableString *dragWindows = [NSMutableString string];
    /*
     * Two lists, not one.  A window PowerEmu should draw is not the same thing
     * as something that can be drawn over it: the Dock and the menu bar get no
     * proxy on the other Mac, but they cover whatever slides under them, and
     * leaving them out of the occlusion test entirely meant a window beneath
     * the Dock was read as clear and took a copy of the Dock with it.  So the
     * windows to report come first, then the occluders, in one array.
     */
    CGSWindowID keptIds[256];
    CGRect keptRects[256];
    CGSWindowID occIds[256];
    CGRect occRects[256];
    int kept = 0, nocc = 0;
    int i;
    for (i = 0; i < count; i++) {
        int level = 0;
        if (CGSGetWindowLevel(cid, list[i], &level) != kCGErrorSuccess) {
            continue;
        }
        if (level == CGWindowLevelForKey(kCGDraggingWindowLevelKey))
            [dragWindows appendFormat:@"%d;",(int)list[i]];
        /*
         * Keep ordinary windows and the layers above them (floating palettes,
         * modal sheets, pop-up menus).  Leave out the desktop, and the whole
         * of the Dock and menu bar family.
         *
         * That family is a range, not two numbers, and assuming it was two is
         * a bug that has been sitting here the whole time: the Dock's own
         * window is level 20, but each *icon* in it is a separate window at
         * level 21.  Eighteen 64x64 windows along the bottom edge, reported as
         * ordinary windows, given a proxy each on the other Mac, raised and
         * hit-tested like real windows -- which is what "RAISE: no AX window
         * at (1272,1019,64,64)" in the log had been saying all along.  Counted
         * against the guest, three real windows were arriving as twenty-one.
         *
         *   20  the Dock            24  the menu bar
         *   21  its icons           25  the menu bar's extras
         */
        if (level < 0) {
            continue;                           /* the desktop covers nothing */
        }
        if (level >= 20 && level <= 25) {
            CGRect dr;
            if (nocc < 256 &&
                CGSGetScreenRectForWindow(cid, list[i], &dr) == kCGErrorSuccess &&
                dr.size.width >= 1 && dr.size.height >= 1) {
                occIds[nocc] = list[i];
                occRects[nocc] = dr;
                nocc++;
            }
            continue;                           /* covers, but is never drawn */
        }
        CGRect r;
        if (CGSGetScreenRectForWindow(cid, list[i], &r) != kCGErrorSuccess) {
            continue;
        }
        if (r.size.width < 1 || r.size.height < 1) {
            continue;
        }
        /*
         * id,x,y,w,h,vx,vy,vw,vh -- the frame, then the part of it nothing
         * covers: the frame itself when the window is clear, and nothing at
         * all when something is over it.  PowerEmu copies a window's pixels
         * out of the one screen everything is drawn into, so a window with
         * anything on top of it cannot be read and keeps its last copy.
         */
        CGRect vis = r;
        {
            int j;
            for (j = 0; j < nAbove; j++) {
                if (CGRectIntersectsRect(above[j], r)) { vis = CGRectZero; break; }
            }
            if (nAbove < 512) above[nAbove++] = r;
        }
        if (kept < 256) { keptIds[kept] = list[i]; keptRects[kept] = r; kept++; }
        [s appendFormat:@"%d,%d,%d,%d,%d,%d,%d,%d,%d;", (int)list[i],
             (int)r.origin.x, (int)r.origin.y, (int)r.size.width, (int)r.size.height,
             (int)vis.origin.x, (int)vis.origin.y, (int)vis.size.width, (int)vis.size.height];
    }
    /* Classify before geometry: the first proxy/frame must already be visual-only. */
    [self send:@"DRAGWINDOWS" text:dragWindows];
    [self send:@"WINDOWS" text:s];
    if(!sheetReportBusy && (++sheetReportTick >= 6 || count != lastWindowCount)) {
        sheetReportTick=0; sheetReportBusy=YES;
        [NSThread detachNewThreadSelector:@selector(sheetWorker:) toTarget:self
            withObject:[NSNumber numberWithUnsignedInt:sheetEpoch]];
    }
    if (!completeCaptureMode) {
        int k;
        for (k = 0; k < nocc && kept + k < 256; k++) {
            keptIds[kept + k] = occIds[k];
            keptRects[kept + k] = occRects[k];
        }
        [self reportOcclusion:keptIds rects:keptRects count:kept + k report:kept];
    }
    [self reportFocused];
    /*
     * A window that has gone may have been minimized, and PowerEmu has only a
     * moment to find out: it has to put the window in this Mac's Dock before
     * it gives up on it.  So whenever the list gets shorter, what is in the
     * guest's Dock is looked at on this tick rather than on the next second.
     */
    if (count < lastWindowCount) windowReportTick = 30;
    lastWindowCount = count;

    /*
     * The guest's applications, so PowerEmu can offer them in this Mac's Dock.
     * CGS will not tell us who owns a window that is not ours, so ask the
     * Process Manager instead: it lists every application with a user
     * interface, whoever owns it.  Once a second is plenty.
     */
    if (++windowReportTick >= 30) {
        NSMutableString *names = [NSMutableString string];
        ProcessSerialNumber psn = { 0, kNoProcess };
        windowReportTick = 0;
        while (GetNextProcess(&psn) == noErr) {
            ProcessInfoRec info;
            CFStringRef nameRef = NULL;
            pid_t pid = 0;
            memset(&info, 0, sizeof(info));
            info.processInfoLength = sizeof(info);
            if (GetProcessInformation(&psn, &info) != noErr) continue;
            /* Background-only helpers have no windows to show. */
            if (info.processMode & modeOnlyBackground) continue;
            if (GetProcessPID(&psn, &pid) != noErr) continue;
            if (CopyProcessName(&psn, &nameRef) != noErr || !nameRef) continue;
            if (![(NSString *)nameRef isEqualToString:@"PowerEmu Agent"]) {
                CGSConnectionID owner = 0;
                CGSWindowID ids[256]; int count = 0, j;
                NSMutableString *windows = [NSMutableString string];
                if (CGSGetConnectionIDForPSN(cid, &psn, &owner) == kCGErrorSuccess &&
                    CGSGetOnScreenWindowList(cid, owner, 256, ids, &count) == kCGErrorSuccess) {
                    for (j = 0; j < count; j++) [windows appendFormat:@"%s%d", j ? "," : "", ids[j]];
                }
                [names appendFormat:@"%d\t%@\t%@\n", (int)pid, (NSString *)nameRef, windows];
            }
            CFRelease(nameRef);
        }
        [self send:@"WINAPPS" text:names];
        [self sendDockApps];


        /*
         * Windows that have been put in the guest's Dock: they leave the
         * on-screen list altogether, so with the guest's Dock hidden there
         * would be no way back to them.  Accessibility still knows about them,
         * so they are offered in this Mac's Dock menu instead.
         */
        if (AXAPIEnabled()) {
            NSMutableString *mins = [NSMutableString string];
            ProcessSerialNumber mp = { 0, kNoProcess };
            while (GetNextProcess(&mp) == noErr) {
                ProcessInfoRec pi;
                pid_t pid = 0;
                AXUIElementRef app;
                CFArrayRef wins = NULL;
                memset(&pi, 0, sizeof(pi));
                pi.processInfoLength = sizeof(pi);
                if (GetProcessInformation(&mp, &pi) != noErr) continue;
                if (pi.processMode & modeOnlyBackground) continue;
                if (GetProcessPID(&mp, &pid) != noErr || pid <= 0) continue;
                app = AXUIElementCreateApplication(pid);
                if (!app) continue;
                if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute,
                                                  (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
                    CFIndex k, n = CFArrayGetCount(wins);
                    for (k = 0; k < n; k++) {
                        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(wins, k);
                        CFTypeRef minRef = NULL, titleRef = NULL;
                        if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute,
                                                          &minRef) != kAXErrorSuccess) continue;
                        if (CFGetTypeID(minRef) == CFBooleanGetTypeID()
                            && CFBooleanGetValue((CFBooleanRef)minRef)) {
                            NSString *title = @"Untitled";
                            if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute,
                                                              &titleRef) == kAXErrorSuccess
                                && titleRef && CFGetTypeID(titleRef) == CFStringGetTypeID()) {
                                title = [[(NSString *)titleRef copy] autorelease];
                            }
                            if (titleRef) CFRelease(titleRef);
                            [mins appendFormat:@"%d\t%d\t%@\n", (int)pid, (int)k, title];
                        }
                        CFRelease(minRef);
                    }
                    CFRelease(wins);
                }
                CFRelease(app);
            }
            [self send:@"MINWINDOWS" text:mins];
        }
    }
}

/*
 * The front application's menu bar: which application it is, and the titles
 * across the top.  What is in each menu is not read here -- that is many more
 * calls into the other application than this can afford at the rate the front
 * application changes -- PowerEmu asks for a menu's contents separately.
 */
- (BOOL)reportMenuBarFor:(pid_t)pid
{
    AXUIElementRef bar;
    CFArrayRef kids;
    NSMutableString *out;
    NSString *name = @"";
    CFStringRef nameRef = NULL;
    ProcessSerialNumber psn;
    CFIndex i, n;

    if (!AXAPIEnabled() || pid <= 0) return NO;
    if (GetProcessForPID(pid, &psn) == noErr
        && CopyProcessName(&psn, &nameRef) == noErr && nameRef) {
        name = [[(NSString *)nameRef copy] autorelease];
        CFRelease(nameRef);
    }
    out = [NSMutableString stringWithFormat:@"%d\t%@\n", (int)pid, name];
    bar = PECopyMenuBar(pid);
    kids = bar ? PECopyChildren(bar) : NULL;
    n = kids ? CFArrayGetCount(kids) : 0;
    /*
     * The Apple menu is left out: this Mac has its own, and its items are the
     * host's business rather than the guest's.
     */
    for (i = 1; i < n; i++) {
        AXUIElementRef it = (AXUIElementRef)CFArrayGetValueAtIndex(kids, i);
        NSString *title = PEAXString(it, kAXTitleAttribute);
        if ([title length]) [out appendFormat:@"%d\t%@\n", (int)i, title];
    }
    if (kids) CFRelease(kids);
    if (bar) CFRelease(bar);
    if (n <= 1) return NO;
    [self send:@"MENUS" text:out];
    return YES;
}

/* "<pid> <path>" -- everything in that menu, so PowerEmu can build it here. */
- (void)reportMenuItems:(NSString *)args
{
    NSArray *f = [args componentsSeparatedByString:@" "];
    pid_t pid;
    NSString *path;
    AXUIElementRef item;
    NSMutableString *out;

    if (!AXAPIEnabled() || [f count] < 2) return;
    pid = (pid_t)[[f objectAtIndex:0] intValue];
    path = [f objectAtIndex:1];
    out = [NSMutableString stringWithFormat:@"%d\t%@\n", (int)pid, path];
    item = PECopyMenuElement(pid, path);
    if (item) {
        PEAppendMenuItems(item, path, 0, out);
        CFRelease(item);
    }
    [self send:@"MENUITEMS" text:out];
}

/* "<pid> <path>" -- somebody picked it over on the host. */
- (void)pickMenuItem:(NSString *)args
{
    NSArray *f = [args componentsSeparatedByString:@" "];
    pid_t pid;
    AXUIElementRef item;
    ProcessSerialNumber psn;

    if (!AXAPIEnabled() || [f count] < 2) return;
    pid = (pid_t)[[f objectAtIndex:0] intValue];
    /*
     * Bring it to the front first: a menu command nearly always means the
     * window it acts on, and an application picked from this Mac's menu bar
     * should end up in front here too.
     */
    if (pid > 0 && GetProcessForPID(pid, &psn) == noErr) SetFrontProcess(&psn);
    item = PECopyMenuElement(pid, [f objectAtIndex:1]);
    if (item) {
        AXError result = AXUIElementPerformAction(item, kAXPressAction);
        CFRelease(item);
        if (result == kAXErrorSuccess && [f count] >= 3)
            [self performSelector:@selector(reportMenuFocus:) withObject:[f objectAtIndex:2] afterDelay:0.15];
    }
}

- (void)reportMenuFocus:(NSString *)token
{
    // Resolve the keyboard-focused AX window rather than a floating palette.
    ProcessSerialNumber front; pid_t pid=0; CGSConnectionID theirs=0;
    int cid=_CGSDefaultConnection();
    if (GetFrontProcess(&front)!=noErr || GetProcessPID(&front,&pid)!=noErr ||
        CGSGetConnectionIDForPSN(cid,&front,&theirs)!=0) return;
    AXUIElementRef app=AXUIElementCreateApplication(pid); CFTypeRef window=NULL,pos=NULL,size=NULL;
    CGRect target=CGRectZero;
    if (AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute,&window)==kAXErrorSuccess && window &&
        AXUIElementCopyAttributeValue((AXUIElementRef)window,kAXPositionAttribute,&pos)==kAXErrorSuccess &&
        AXUIElementCopyAttributeValue((AXUIElementRef)window,kAXSizeAttribute,&size)==kAXErrorSuccess &&
        pos && size && CFGetTypeID(pos)==AXValueGetTypeID() && CFGetTypeID(size)==AXValueGetTypeID()) {
        AXValueGetValue((AXValueRef)pos,kAXValueCGPointType,&target.origin);
        AXValueGetValue((AXValueRef)size,kAXValueCGSizeType,&target.size);
    }
    if(pos)CFRelease(pos);if(size)CFRelease(size);if(window)CFRelease(window);CFRelease(app);
    if(CGRectIsEmpty(target))return;
    CGSWindowID ids[128];int count=0,i;
    if(CGSGetOnScreenWindowList(cid,theirs,128,ids,&count)!=0)return;
    for(i=0;i<count;i++) {
        CGRect r;
        if(CGSGetScreenRectForWindow(cid,ids[i],&r)==0 &&
            fabs(r.origin.x-target.origin.x)<2 && fabs(r.origin.y-target.origin.y)<2 &&
            fabs(r.size.width-target.size.width)<2 && fabs(r.size.height-target.size.height)<2) {
            [self send:@"MENUFOCUS" text:[NSString stringWithFormat:@"%@ %d",token,ids[i]]];return;
        }
    }
}

/*
 * Switch the guest's screen to the resolution PowerEmu asks for ("W H"), so
 * Harmony can run the guest at this Mac's own resolution and its windows land
 * where they belong.  The best matching mode the card offers is chosen.
 */
- (void)setResolution:(NSString *)wh
{
    NSArray *f = [wh componentsSeparatedByString:@" "];
    if ([f count] < 2) {
        return;
    }
    int w = [[f objectAtIndex:0] intValue];
    int h = [[f objectAtIndex:1] intValue];
    if (w < 640 || h < 480) {
        return;
    }
    CGDirectDisplayID disp = CGMainDisplayID();
    boolean_t exact = FALSE;
    CFDictionaryRef mode = CGDisplayBestModeForParameters(disp, 32, w, h, &exact);
    if (mode) {
        CGDisplaySwitchToMode(disp, mode);
    }
}

/*
 * Bring a window (by id) to the front of the guest's own stack and its
 * application to the front, so a click on its proxy on this Mac focuses the
 * real window and routes the keyboard to it.
 */
- (void)raiseWindow:(NSString *)idStr
{
    /*
     * "id" -- bring a window to the front.
     *
     * CGSOrderWindow does not reorder a window this connection does not own,
     * and faking a click to raise it arrived right behind the reader's own
     * click, which the guest read as a double-click and minimized the window.
     * Accessibility raises it outright.  Matching the guest's stacking to the
     * host's matters for more than tidiness: the windows are all sampled out of
     * one screen, so a window that is behind another here shows that other
     * window's pixels -- and only if the two agree on the order is that wrong
     * patch hidden behind the same window on the host.
     */
    int wid = [idStr intValue];
    CGSConnectionID cid = _CGSDefaultConnection();
    CGRect r;
    CGError ge;
    pid_t pid = 0;
    AXUIElementRef w;
    if (wid <= 0) {
        [self send:@"LOG" text:[NSString stringWithFormat:@"RAISE bad id '%@'", idStr]];
        return;
    }
    ge = CGSGetScreenRectForWindow(cid, wid, &r);
    if (ge != kCGErrorSuccess) {
        [self send:@"LOG" text:[NSString stringWithFormat:@"RAISE %d: no rect err=%d", wid, (int)ge]];
        return;
    }
    w = PEFindAXWindow(r, &pid);
    if (w) {
        /* A window that has just been put in the Dock must stay there: raising
         * it would take it straight back out, which looked like minimizing
         * simply not working. */
        CFTypeRef minRef = NULL;
        if (AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess
            && minRef) {
            Boolean isMin = CFGetTypeID(minRef) == CFBooleanGetTypeID()
                            && CFBooleanGetValue((CFBooleanRef)minRef);
            CFRelease(minRef);
            if (isMin) {
                CFRelease(w);
                [self send:@"LOG" text:[NSString stringWithFormat:@"RAISE %d: minimized, left alone", wid]];
                return;
            }
        }
        AXError e = AXUIElementPerformAction(w, kAXRaiseAction);
        CFRelease(w);
        [self send:@"LOG" text:[NSString stringWithFormat:@"RAISE %d ax=%d pid=%d", wid, (int)e, (int)pid]];
    } else {
        [self send:@"LOG" text:[NSString stringWithFormat:
            @"RAISE %d: no AX window at (%g,%g,%g,%g) axEnabled=%d", wid,
            (double)r.origin.x, (double)r.origin.y, (double)r.size.width, (double)r.size.height,
            (int)AXAPIEnabled()]];
    }
    if (pid > 0) {
        ProcessSerialNumber psn;
        if (GetProcessForPID(pid, &psn) == noErr) {
            /*
             * Only the window that was asked for comes forward.
             *
             * SetFrontProcess brings every one of the application's windows up
             * with it, which is not what clicking a window does on this Mac --
             * that is what the Window menu's "Bring All to Front" is for, and
             * it would not exist if activating an application did it by itself.
             * Mirroring it put all of an application's windows over the others
             * the moment one of them was clicked.
             */
            OSStatus st = raiseBringsAppForward ? paramErr
                : SetFrontProcessWithOptions(&psn, kSetFrontProcessFrontWindowOnly);
            if (st != noErr) SetFrontProcess(&psn);
        }
    }
    /* Say so at once: waiting for the next report put a twelfth of a second
     * between the click and PowerEmu believing it. */
    [self reportFocused];
}



/* SetFrontProcess can complete asynchronously. Confirm the actual keyboard
 * focused AX window before the host releases the queued content gesture. */
/* AX can wait on another application. Keep it off the input/report loop and
 * allow only one query at a time; an old transition cannot republish sheets. */
- (void)sheetWorker:(NSNumber *)epoch
{
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    NSString *report=PESheetReport();
    [self performSelectorOnMainThread:@selector(sheetResult:)
        withObject:[NSArray arrayWithObjects:epoch,report,nil] waitUntilDone:NO];
    [pool release];
}
- (void)sheetResult:(NSArray *)result
{
    sheetReportBusy=NO;
    if(windowTimer && sock>=0 && [[result objectAtIndex:0] unsignedIntValue]==sheetEpoch)
        [self send:@"SHEETS" text:[result objectAtIndex:1]];
}

- (void)confirmFocus:(NSArray *)request
{
    int wid = [[request objectAtIndex:0] intValue];
    int sequence = [[request objectAtIndex:1] intValue];
    int attempt = [[request objectAtIndex:2] intValue];
    if (sequence != focusRequestSequence) return;
    CGRect rect;
    BOOL ok = NO;
    pid_t pid = 0, frontPID = 0;
    ProcessSerialNumber front;
    if (CGSGetScreenRectForWindow(_CGSDefaultConnection(), wid, &rect) == 0) {
        AXUIElementRef target = PEFindAXWindow(rect, &pid);
        if (target && GetFrontProcess(&front) == noErr && GetProcessPID(&front, &frontPID) == noErr && pid == frontPID) {
            AXUIElementRef app = AXUIElementCreateApplication(pid);
            CFTypeRef focused = NULL;
            if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &focused) == kAXErrorSuccess && focused) {
                ok = CFEqual(target, focused) || PESheetBelongsToFocus(target, (AXUIElementRef)focused);
                CFArrayRef blocking=PECopySheets(target);
                if(blocking && CFArrayGetCount(blocking)>0)ok=NO;
                if(blocking)CFRelease(blocking);
                CFRelease(focused);
            }
            CFRelease(app);
        }
        if (target) CFRelease(target);
    }
    if (!ok && attempt < 30) {
        [self performSelector:@selector(confirmFocus:) withObject:[NSArray arrayWithObjects:
            [request objectAtIndex:0], [request objectAtIndex:1], [NSString stringWithFormat:@"%d", attempt + 1], nil]
            afterDelay:0.02];
        return;
    }
    [self send:@"FOCUSREADY" text:[NSString stringWithFormat:@"%d %d %d", wid, sequence, ok]];
    if (ok) { menuBarPid = 0; [self reportFocused]; }
}

/*
 * Move a window (by id) so the guest's window follows the proxy the user is
 * dragging on this Mac.  "id x y", top-left in screen points.
 */
- (void)moveWindow:(NSString *)args
{
    /* "id grabX grabY endX endY" -- only the id and the end matter now that the
     * window can simply be put where it belongs. */
    NSArray *f = [args componentsSeparatedByString:@" "];
    if ([f count] != 3 && [f count] != 5) {
        return;
    }
    int wid = [[f objectAtIndex:0] intValue];
    CGPoint grab = CGPointMake([[f objectAtIndex:1] floatValue], [[f objectAtIndex:2] floatValue]);
    CGPoint end = grab;
    if ([f count] == 5) end = CGPointMake([[f objectAtIndex:3] floatValue], [[f objectAtIndex:4] floatValue]);
    CGSConnectionID cid = _CGSDefaultConnection();
    CGRect r;
    pid_t pid = 0;
    AXUIElementRef w;
    if (CGSGetScreenRectForWindow(cid, wid, &r) != kCGErrorSuccess) {
        [self send:@"LOG" text:[NSString stringWithFormat:@"MOVEWINDOW %d: no rect", wid]];
        return;
    }
    /* Where the window's top-left should end up: it moves by as much as the
     * grab point did. */
    CGPoint target = [f count] == 3 ? end : CGPointMake(r.origin.x + (end.x - grab.x), r.origin.y + (end.y - grab.y));
    w = PEFindAXWindow(r, &pid);
    if (w) {
        AXValueRef v = AXValueCreate(kAXValueCGPointType, &target);
        AXError e = AXUIElementSetAttributeValue(w, kAXPositionAttribute, v);
        CFRelease(v);
        CFRelease(w);
        [self send:@"LOG" text:[NSString stringWithFormat:@"MOVEWINDOW %d -> (%g,%g) ax=%d",
                                wid, (double)target.x, (double)target.y, (int)e]];
        return;
    }
    [self send:@"LOG" text:[NSString stringWithFormat:
        @"MOVEWINDOW %d: no window control -- turn on access for assistive devices", wid]];
}




/*
 * Put a window in the Dock, asked for from the other Mac.
 *
 * The other side can only miniaturise its own proxy; the real window stays
 * where it is unless somebody tells it otherwise, and then the next report
 * says the window is still on screen and the proxy is pulled straight back
 * out of the Dock again.  That is the window "bouncing".  So the yellow
 * button is passed through to the window it stands for.
 */
- (void)minimizeWindow:(NSString *)args
{
    int wid = [args intValue];
    CGSConnectionID cid = _CGSDefaultConnection();
    CGRect r;
    pid_t pid = 0;
    AXUIElementRef w;
    if (CGSGetScreenRectForWindow(cid, wid, &r) != kCGErrorSuccess) {
        [self send:@"LOG" text:[NSString stringWithFormat:@"MINIMIZE %d: no rect", wid]];
        return;
    }
    w = PEFindAXWindow(r, &pid);
    if (w) {
        AXError e = AXUIElementSetAttributeValue(w, kAXMinimizedAttribute,
                                                 kCFBooleanTrue);
        CFRelease(w);
        [self send:@"LOG" text:[NSString stringWithFormat:@"MINIMIZE %d ax=%d pid=%d",
                                wid, (int)e, (int)pid]];
        return;
    }
    [self send:@"LOG" text:[NSString stringWithFormat:
        @"MINIMIZE %d: no window control -- turn on access for assistive devices", wid]];
}

/* Mount a shared folder the way Connect to Server does. */
- (void)mount:(NSString *)spec
{
    NSArray *f = [spec componentsSeparatedByString:@"\t"];
    if ([f count] < 1) return;
    NSString *url = [f objectAtIndex:0];
    if (MountPointFor(url)) return;                 /* already there */
    NSMutableString *q = [NSMutableString stringWithString:url];
    [q replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, [q length])];
    [q replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, [q length])];
    NSString *src = [NSString stringWithFormat:@"mount volume \"%@\"", q];
    NSAppleScript *as = [[[NSAppleScript alloc] initWithSource:src] autorelease];
    NSDictionary *err = nil;
    if (![as executeAndReturnError:&err])
        [self send:@"LOG" text:[NSString stringWithFormat:@"mount %@ failed: %@", url, err]];
}

/* Unmount the shared folder served at http://10.0.2.100/<name>/. */
- (void)unmount:(NSString *)name
{
    NSString *url = [NSString stringWithFormat:@"http://10.0.2.100/%@/", name];
    NSString *path = MountPointFor(url);
    if (!path) return;
    /* NSWorkspace declines network volumes on 10.4; the user mounted it,
     * so the user may unmount it. */
    if (![[NSWorkspace sharedWorkspace] unmountAndEjectDeviceAtPath:path] &&
        unmount([path fileSystemRepresentation], 0) != 0)
        [self send:@"LOG" text:[NSString stringWithFormat:@"unmount %@ failed: %s", path, strerror(errno)]];
}

/* Folders changed on the host.  Finder learns about changes on a WebDAV
 * volume by checking each open folder's modification date, but webdavfs
 * answers that from a cache that lasts about half a minute -- so new files
 * took that long to appear.  Reading the folder refreshes webdavfs's copy
 * (measured: Finder then shows the change within a second); the FNNotify
 * is for anything else watching the folder. */
- (void)changed:(NSString *)list
{
    NSEnumerator *e = [[list componentsSeparatedByString:@"\n"] objectEnumerator];
    NSString *line;
    while ((line = [e nextObject])) {
        NSArray *f = [line componentsSeparatedByString:@"\t"];
        if ([f count] < 2) continue;
        NSString *rel = [f objectAtIndex:1];
        if ([[rel pathComponents] containsObject:@".."]) continue;
        NSString *mp = MountPointFor([NSString stringWithFormat:@"http://10.0.2.100/%@/", [f objectAtIndex:0]]);
        if (!mp) continue;
        NSString *path = [rel length] ? [mp stringByAppendingPathComponent:rel] : mp;
        DIR *d = opendir([path fileSystemRepresentation]);
        if (!d) continue;                           /* gone, or not a folder */
        while (readdir(d)) {}
        closedir(d);
        struct stat st;
        stat([path fileSystemRepresentation], &st);
        FNNotifyByPath((const UInt8 *)[path fileSystemRepresentation], kFNDirectoryModifiedMessage, kNilOptions);
    }
}

/* Poll the pasteboard: Cocoa has no change notification. */
- (void)checkPasteboard:(NSTimer *)t
{
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    int cc = [pb changeCount];
    if (cc == lastChangeCount) return;
    lastChangeCount = cc;
    if (sock < 0) return;
    if (![pb availableTypeFromArray:[NSArray arrayWithObject:NSStringPboardType]]) return;
    NSString *s = [pb stringForType:NSStringPboardType];
    if (!s || (lastClip && [s isEqualToString:lastClip])) return;
    [lastClip release];
    lastClip = [s copy];
    [self send:@"CLIP" text:s];
}

@end

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    signal(SIGPIPE, SIG_IGN);
    [NSApplication sharedApplication];
    PERefreshAccessibilityState();
    PEAgent *agent = [[PEAgent alloc] init];
    [agent connect];
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:agent
        selector:@selector(checkPasteboard:) userInfo:nil repeats:YES];
    [NSApp run];
    [pool release];
    return 0;
}
