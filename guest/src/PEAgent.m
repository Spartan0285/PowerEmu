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

#define PE_AGENT_VERSION "1.1"
#define PE_HOST_ADDR     "10.0.2.100"
#define PE_HOST_PORT     7700

@interface PEAgent : NSObject {
    int sock;
    NSFileHandle *handle;
    NSMutableData *inbox;
    int lastChangeCount;        /* pasteboard change we have dealt with */
    NSString *lastClip;         /* text last exchanged, to stop echoes */
}
- (void)connect;
- (void)disconnected;
- (void)processInbox;
- (void)handle:(NSString *)verb payload:(NSData *)payload;
- (void)mount:(NSString *)spec;
- (void)unmount:(NSString *)name;
- (void)changed:(NSString *)list;
@end

/* Where the volume mounted from `from` (a WebDAV URL) is, or nil. */
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
    a.sin_port = htons(PE_HOST_PORT);
    a.sin_addr.s_addr = inet_addr(PE_HOST_ADDR);
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
    } else if ([verb isEqualToString:@"PING"]) {
        [self send:@"PONG" data:nil];
    }
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
