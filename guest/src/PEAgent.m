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

#define PE_AGENT_VERSION "1.6"

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
    int sock;
    NSFileHandle *handle;
    NSMutableData *inbox;
    int lastChangeCount;        /* pasteboard change we have dealt with */
    NSString *lastClip;         /* text last exchanged, to stop echoes */
    BOOL harmonyRemembered;     /* whether the two below have been read yet */
    BOOL dockHadAutohide;       /* whether these were set at all before */
    BOOL dockWasAutohidden;     /* what this Mac looked like before Harmony */
    BOOL finderHadDesktopKey;
    BOOL finderDrewDesktop;
    NSTimer *windowTimer;
    int windowReportTick;       /* reports window rectangles while Harmony is on */
    int lastWindowCount;        /* so a window going away is noticed at once */
    BOOL raiseBringsAppForward; /* RAISEHARD: raise the whole application */
    int hitTestProbed;
    pid_t menuBarPid;           /* application whose menus PowerEmu is showing */
}
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
- (void)set:(NSString *)domain key:(NSString *)key yes:(BOOL)yes keep:(BOOL)keep;
- (void)run:(NSString *)tool with:(NSArray *)args;
- (void)sendAppIcon:(NSString *)pidStr;
- (void)reportMenuBarFor:(pid_t)pid;
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
            CFIndex i, n = CFArrayGetCount(windows);
            for (i = 0; i < n; i++) {
                AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
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
        inbox = [[NSMutableData alloc] init];
        lastChangeCount = [[NSPasteboard generalPasteboard] changeCount];
    }
    return self;
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

- (void)retryLater
{
    [self performSelector:@selector(connect) withObject:nil afterDelay:5.0];
}

- (void)connect
{
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
    if (sock < 0) return;
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
    if ([verb isEqualToString:@"CLIP"]) {
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
    } else if ([verb isEqualToString:@"APPICON"]) {
        [self sendAppIcon:text];
    } else if ([verb isEqualToString:@"MENUS"]) {
        menuBarPid = 0;                      /* force the next tick to re-read */
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
    NSString *killall = @"/usr/bin/killall";

    /*
     * Remember what this Mac looked like before, once, so turning Harmony
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

    [self set:@"com.apple.finder" key:@"CreateDesktop"
          yes:on ? NO : finderDrewDesktop
         keep:on || finderHadDesktopKey];
    [self run:killall with:[NSArray arrayWithObject:@"Finder"]];

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
    } else {
        [windowTimer invalidate];
        [windowTimer release];
        windowTimer = nil;
        menuBarPid = 0;
        [self send:@"WINDOWS" text:@""];        /* clear the mask */
        [self send:@"MENUS" text:@""];          /* give this Mac its menus back */
    }
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
 * What covers what, asked of the window server a point at a time.
 *
 * For each window, every other window it overlaps is tested once, at the
 * middle of the overlap: if the server says some other window is drawn there,
 * that patch of this window cannot be read out of the shared frame.  Which
 * other window it is does not matter, so no ordering has to be worked out --
 * and the window list's order, which is grouped by connection and wrong across
 * applications, is not needed at all.
 */
- (void)reportOcclusion:(CGSWindowID *)ids rects:(CGRect *)rects count:(int)n
{
    CGSConnectionID cid = _CGSDefaultConnection();
    NSMutableString *out = [NSMutableString string];
    int i, j;
    if (!PEFindWindow()) return;                /* nothing to say without it */
    for (i = 0; i < n; i++) {
        NSMutableString *covers = [NSMutableString string];
        for (j = 0; j < n; j++) {
            CGRect hit;
            CGPoint mid;
            if (i == j) continue;
            hit = CGRectIntersection(rects[i], rects[j]);
            if (CGRectIsEmpty(hit) || hit.size.width < 2 || hit.size.height < 2) continue;
            mid = CGPointMake(hit.origin.x + hit.size.width / 2,
                              hit.origin.y + hit.size.height / 2);
            {
                CGSWindowID at = PEWindowAtPoint(cid, mid);
                int k;
                /*
                 * Ours, or the server would not say: either way this is not a
                 * reason to stop reading the window.
                 */
                if (at == 0 || at == ids[i]) continue;
                /*
                 * Something else is drawn at that point -- but not necessarily
                 * the window whose overlap was being tested.  Record the
                 * overlap with whatever is *actually* on top there, which is
                 * usually far smaller: reporting the whole of i-against-j
                 * whenever some third window won the point declared most of a
                 * window covered, and a window declared covered is a window
                 * that never gets copied.
                 */
                for (k = 0; k < n; k++) {
                    if (ids[k] != at) continue;
                    hit = CGRectIntersection(rects[i], rects[k]);
                    break;
                }
                if (CGRectIsEmpty(hit) || hit.size.width < 2 || hit.size.height < 2) continue;
            }
            [covers appendFormat:@"%s%d,%d,%d,%d", [covers length] ? "|" : "",
                 (int)hit.origin.x, (int)hit.origin.y,
                 (int)hit.size.width, (int)hit.size.height];
        }
        if ([covers length]) [out appendFormat:@"%d\t%@\n", (int)ids[i], covers];
    }
    [self send:@"OCCLUDE" text:out];
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
    ProcessSerialNumber front;
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
                if (lvl < 0 || lvl == 20 || lvl == 24) continue;
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
        if (GetProcessPID(&front, &fpid) == noErr && fpid > 0 && fpid != menuBarPid) {
            menuBarPid = fpid;
            [self reportMenuBarFor:fpid];
        }
    }
}

- (void)reportWindows:(NSTimer *)t
{
    CGSConnectionID cid = _CGSDefaultConnection();
    CGSWindowID list[512];
    CGRect above[512];
    int count = 0, nAbove = 0;
    if (CGSGetOnScreenWindowList(cid, 0, 512, list, &count) != kCGErrorSuccess) {
        return;
    }
    NSMutableString *s = [NSMutableString string];
    CGSWindowID keptIds[256];
    CGRect keptRects[256];
    int kept = 0;
    int i;
    for (i = 0; i < count; i++) {
        int level = 0;
        if (CGSGetWindowLevel(cid, list[i], &level) != kCGErrorSuccess) {
            continue;
        }
        /*
         * Keep ordinary windows and the layers above them (floating palettes,
         * modal sheets, pop-up menus).  Leave out the desktop (below zero),
         * the Dock (level 20) and the menu bar (level 24).
         */
        if (level < 0 || level == 20 || level == 24) {
            continue;
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
    [self send:@"WINDOWS" text:s];
    [self reportOcclusion:keptIds rects:keptRects count:kept];
    [self reportFocused];
    /*
     * A window that has gone may have been minimised, and PowerEmu has only a
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
                [names appendFormat:@"%d\t%@\n", (int)pid, (NSString *)nameRef];
            }
            CFRelease(nameRef);
        }
        [self send:@"WINAPPS" text:names];

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
- (void)reportMenuBarFor:(pid_t)pid
{
    AXUIElementRef bar;
    CFArrayRef kids;
    NSMutableString *out;
    NSString *name = @"";
    CFStringRef nameRef = NULL;
    ProcessSerialNumber psn;
    CFIndex i, n;

    if (!AXAPIEnabled() || pid <= 0) return;
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
    [self send:@"MENUS" text:out];
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
        AXUIElementPerformAction(item, kAXPressAction);
        CFRelease(item);
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
     * click, which the guest read as a double-click and minimised the window.
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
         * it would take it straight back out, which looked like minimising
         * simply not working. */
        CFTypeRef minRef = NULL;
        if (AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess
            && minRef) {
            Boolean isMin = CFGetTypeID(minRef) == CFBooleanGetTypeID()
                            && CFBooleanGetValue((CFBooleanRef)minRef);
            CFRelease(minRef);
            if (isMin) {
                CFRelease(w);
                [self send:@"LOG" text:[NSString stringWithFormat:@"RAISE %d: minimised, left alone", wid]];
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



/*
 * Move a window (by id) so the guest's window follows the proxy the user is
 * dragging on this Mac.  "id x y", top-left in screen points.
 */
- (void)moveWindow:(NSString *)args
{
    /* "id grabX grabY endX endY" -- only the id and the end matter now that the
     * window can simply be put where it belongs. */
    NSArray *f = [args componentsSeparatedByString:@" "];
    if ([f count] < 5) {
        return;
    }
    int wid = [[f objectAtIndex:0] intValue];
    CGPoint grab = CGPointMake([[f objectAtIndex:1] floatValue], [[f objectAtIndex:2] floatValue]);
    CGPoint end  = CGPointMake([[f objectAtIndex:3] floatValue], [[f objectAtIndex:4] floatValue]);
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
    CGPoint target = CGPointMake(r.origin.x + (end.x - grab.x), r.origin.y + (end.y - grab.y));
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
    PEAgent *agent = [[PEAgent alloc] init];
    [agent connect];
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:agent
        selector:@selector(checkPasteboard:) userInfo:nil repeats:YES];
    [NSApp run];
    [pool release];
    return 0;
}
