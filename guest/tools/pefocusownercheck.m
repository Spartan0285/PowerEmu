/* Bounded, read-only comparison of legacy geometry search and the optional
 * exact-CGS-owner lookup. This fixture never raises, focuses, moves, or posts
 * input to a guest window. Run as an Aqua app with Accessibility enabled. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <unistd.h>

@interface PEOwnerCheckDelegate : NSObject
- (void)sheetDidEnd:(NSWindow *)sheet returnCode:(int)code contextInfo:(void *)context;
@end
@implementation PEOwnerCheckDelegate
- (void)sheetDidEnd:(NSWindow *)sheet returnCode:(int)code contextInfo:(void *)context
{ [sheet orderOut:nil]; }
@end

static double PEMilliseconds(uint64_t ticks)
{
    static mach_timebase_info_data_t scale;
    if (!scale.denom) mach_timebase_info(&scale);
    return ((double)ticks * (double)scale.numer / (double)scale.denom) / 1000000.0;
}

static double PECpuMilliseconds(void)
{
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
    return (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000.0 +
        (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000.0;
}

static BOOL PEAXRect(AXUIElementRef element, CGRect *rect)
{
    CFTypeRef pos = NULL, size = NULL;
    BOOL ok = NO;
    if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &pos) == kAXErrorSuccess && pos &&
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &size) == kAXErrorSuccess && size &&
        AXValueGetValue((AXValueRef)pos, kAXValueCGPointType, &rect->origin) &&
        AXValueGetValue((AXValueRef)size, kAXValueCGSizeType, &rect->size)) ok = YES;
    if (pos) CFRelease(pos);
    if (size) CFRelease(size);
    return ok;
}

static BOOL PEEqualRect(CGRect a, CGRect b)
{
    return fabs(a.origin.x-b.origin.x)<=4 && fabs(a.origin.y-b.origin.y)<=4 &&
        fabs(a.size.width-b.size.width)<=4 && fabs(a.size.height-b.size.height)<=4;
}

static BOOL PECompare(CGRect rect, CGSWindowID wid, AXUIElementRef expected,
                      pid_t expectedPID, const char *label, unsigned repetitions)
{
    unsigned i;
    double total[3] = {0,0,0};
    unsigned long processes[3] = {0,0,0}, windows[3] = {0,0,0};
    double cpu[3] = {0,0,0};
    BOOL ok = YES;
    for (i=0; i<repetitions; i++) {
        AXUIElementRef result[3] = {NULL,NULL,NULL};
        PEAXLookupStats stats[3];
        const char *names[3] = {"baseline","candidate","return"};
        int pass;
        for (pass=0; pass<3; pass++) {
            uint64_t start = mach_absolute_time();
            double cpuStart = PECpuMilliseconds();
            if (pass == 1) setenv("PE_FOCUS_OWNER_LOOKUP", "1", 1);
            else unsetenv("PE_FOCUS_OWNER_LOOKUP");
            result[pass] = PEFindAXWindowForWindow(rect, wid, NULL, &stats[pass]);
            total[pass] += PEMilliseconds(mach_absolute_time()-start);
            cpu[pass] += PECpuMilliseconds()-cpuStart;
            processes[pass] += stats[pass].processesVisited;
            windows[pass] += stats[pass].axWindowsVisited;
            BOOL match = result[pass] && CFEqual(result[pass], expected);
            if (!match) ok = NO;
            printf("LOOKUP case=%s iteration=%u mode=%s processes=%u axWindows=%u match=%d\n",
                   label, i, names[pass], stats[pass].processesVisited,
                   stats[pass].axWindowsVisited, match);
            if (result[pass]) CFRelease(result[pass]);
        }
        /* Owner validation itself is repeated in the candidate and must name
         * this fixture's process, independently of AX geometry equality. */
        CGSConnectionID owner = 0, mapped = 0;
        ProcessSerialNumber psn = {0,kNoProcess}; pid_t ownerPID = 0;
        if (CGSGetWindowOwner(_CGSDefaultConnection(), wid, &owner) != kCGErrorSuccess || !owner) ok=NO;
        while (owner && GetNextProcess(&psn) == noErr) {
            if (CGSGetConnectionIDForPSN(_CGSDefaultConnection(), &psn, &mapped)==kCGErrorSuccess && mapped==owner) {
                if (GetProcessPID(&psn, &ownerPID)!=noErr) ownerPID=0;
                break;
            }
        }
        if (ownerPID != expectedPID) ok=NO;
        printf("OWNER case=%s wid=%d connection=%d pid=%d expectedPID=%d valid=%d\n",
               label, wid, owner, ownerPID, expectedPID, ownerPID==expectedPID);
    }
    setenv("PE_FOCUS_OWNER_LOOKUP", "1", 1);
    PEAXLookupStats invalidStats;
    AXUIElementRef invalid = PEFindAXWindowForWindow(rect, 0, NULL, &invalidStats);
    if (invalid) { CFRelease(invalid); ok=NO; }
    printf("FAIL-CLOSED case=%s invalidWidResult=%s\n",label,invalid?"FAIL":"nil");
    printf("SUMMARY case=%s repetitions=%u result=%s baselineMeanMS=%.3f candidateMeanMS=%.3f returnMeanMS=%.3f "
           "baselineCpuMS=%.3f candidateCpuMS=%.3f returnCpuMS=%.3f "
           "baselineScans=%lu/%lu candidateScans=%lu/%lu returnScans=%lu/%lu\n",
           label, repetitions, ok?"PASS":"FAIL", total[0]/repetitions, total[1]/repetitions,
           total[2]/repetitions, cpu[0], cpu[1], cpu[2], processes[0], windows[0], processes[1], windows[1],
           processes[2], windows[2]);
    return ok;
}

/* Read-only mode for an already visible guest window. It does not create a
 * window, activate an application, or call any focus/raise/input operation. */
static int PEExternalWindowMode(int wid, pid_t expectedPID)
{
    CGRect rect, axRect;
    pid_t resolvedPID=0;
    PEAXLookupStats initial;
    uint64_t monoStart;
    double cpuStart, elapsed, cpuMS;
    AXUIElementRef expected;
    BOOL ok;
    NSApplicationLoad();
    [NSApplication sharedApplication];
    if (CGSGetScreenRectForWindow(_CGSDefaultConnection(),wid,&rect)!=kCGErrorSuccess) {
        fprintf(stderr,"FAIL: external window %d has no CGS rectangle\n",wid); return 1;
    }
    if (!AXAPIEnabled()) {
        fprintf(stderr,"SKIP: Accessibility API is unavailable or not authorized\n"); return 77;
    }
    cpuStart=PECpuMilliseconds(); monoStart=mach_absolute_time();
    expected=PEFindAXWindowWithStats(rect,&resolvedPID,&initial);
    elapsed=PEMilliseconds(mach_absolute_time()-monoStart); cpuMS=PECpuMilliseconds()-cpuStart;
    if (!expected || resolvedPID!=expectedPID) {
        fprintf(stderr,"FAIL: legacy AX lookup resolved pid=%d expected=%d for wid=%d\n",
                resolvedPID,expectedPID,wid);
        if(expected)CFRelease(expected); return 1;
    }
    if (!PEAXRect(expected,&axRect) || !PEEqualRect(rect,axRect)) {
        fprintf(stderr,"FAIL: external CGS/AX geometry mismatch wid=%d pid=%d\n",wid,resolvedPID);
        CFRelease(expected); return 1;
    }
    printf("ENV mode=external-read-only wid=%d expectedPID=%d legacyPID=%d monotonicBaselineMS=%.3f "
           "cpuDeltaMS=%.3f baselineProcesses=%u baselineAXWindows=%u\n",
           wid,expectedPID,resolvedPID,elapsed,cpuMS,initial.processesVisited,initial.axWindowsVisited);
    ok=PECompare(rect,wid,expected,expectedPID,"external-window",12);
    CFArrayRef sheets=PECopySheets(expected);
    if (sheets && CFArrayGetCount(sheets)>0) {
        AXUIElementRef child=(AXUIElementRef)CFArrayGetValueAtIndex(sheets,0);
        CGRect childRect; int ids[128],count=0,i,found=0; CGSConnectionID owner=0;
        ProcessSerialNumber psn={0,kNoProcess};
        while(GetNextProcess(&psn)==noErr) {
            pid_t processPID=0;
            if(GetProcessPID(&psn,&processPID)==noErr && processPID==expectedPID) {
                if(CGSGetConnectionIDForPSN(_CGSDefaultConnection(),&psn,&owner)!=kCGErrorSuccess)owner=0;
                break;
            }
        }
        if (PEAXRect(child,&childRect) && owner &&
            CGSGetOnScreenWindowList(_CGSDefaultConnection(),owner,128,ids,&count)==kCGErrorSuccess) {
            for(i=0;i<count;i++){CGRect g;if(CGSGetScreenRectForWindow(_CGSDefaultConnection(),ids[i],&g)==0 && PEEqualRect(g,childRect)){if(found){found=0;break;}found=ids[i];}}
            if(found && !PESheetBelongsToFocus(child,expected)) ok=NO;
            if(found) ok=PECompare(childRect,found,child,expectedPID,"external-attached-sheet",4) && ok;
        }
        printf("SHEET mode=external exposed=%d identityRelationship=%d\n",found!=0,
               found && PESheetBelongsToFocus(child,expected));
        if(!found)ok=NO;
    } else printf("SHEET mode=external exposed=0 identityRelationship=not-applicable\n");
    if(sheets)CFRelease(sheets);
    printf("FINAL mode=external-read-only %s\n",ok?"PASS":"FAIL");
    CFRelease(expected); return ok?0:1;
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    setvbuf(stdout,NULL,_IOLBF,0);
    alarm(30); /* AX IPC can stall; the fixture has a hard process deadline. */
    if (argc == 3) {
        int result=PEExternalWindowMode(atoi(argv[1]),(pid_t)atoi(argv[2]));
        [pool drain]; return result;
    }
    [NSApplication sharedApplication];
    ProcessSerialNumber selfPSN;
    GetCurrentProcess(&selfPSN); TransformProcessType(&selfPSN, kProcessTransformToForegroundApplication);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(180,180,420,280)
        styleMask:NSTitledWindowMask|NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"PowerEmu owner lookup fixture"];
    [NSApp finishLaunching]; [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    NSWindow *sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,340,180)
        styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [sheet setTitle:@"Owner lookup attached sheet"];
    PEOwnerCheckDelegate *delegate = [[PEOwnerCheckDelegate alloc] init];
    [NSApp beginSheet:sheet modalForWindow:window modalDelegate:delegate
        didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:NULL];
    NSDate *ready = [NSDate dateWithTimeIntervalSinceNow:0.6];
    while ([ready timeIntervalSinceNow] > 0) {
        NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:ready
            inMode:NSDefaultRunLoopMode dequeue:YES]; if(event)[NSApp sendEvent:event];
    }
    if (!AXAPIEnabled()) {
        fprintf(stderr, "SKIP: Accessibility API is unavailable or not authorized\n");
        [NSApp endSheet:sheet]; [window orderOut:nil]; [window release]; [sheet release];
        [delegate release]; [pool drain]; return 77;
    }
    CGSWindowID wid = (CGSWindowID)[window windowNumber];
    CGRect rect; pid_t pid=0; PEAXLookupStats initial;
    if (CGSGetScreenRectForWindow(_CGSDefaultConnection(),wid,&rect)!=kCGErrorSuccess) {
        fprintf(stderr,"FAIL: fixture window has no CGS rectangle\n"); return 1;
    }
    double cpuStart=PECpuMilliseconds(); uint64_t monoStart=mach_absolute_time();
    AXUIElementRef expected=PEFindAXWindowWithStats(rect,&pid,&initial);
    double baselineMS=PEMilliseconds(mach_absolute_time()-monoStart), cpuMS=PECpuMilliseconds()-cpuStart;
    if (!expected || pid!=getpid()) {
        fprintf(stderr,"FAIL: baseline could not resolve the fixture-owned window (pid=%d)\n",pid);
        if(expected)CFRelease(expected);return 1;
    }
    CGRect axRect;
    if (!PEAXRect(expected,&axRect) || !PEEqualRect(rect,axRect)) {
        fprintf(stderr,"FAIL: AX/CGS geometry mismatch\n"); CFRelease(expected); return 1;
    }
    printf("ENV ax=1 guestPID=%d monotonicBaselineMS=%.3f cpuDeltaMS=%.3f baselineProcesses=%u baselineAXWindows=%u\n",
           getpid(),baselineMS,cpuMS,initial.processesVisited,initial.axWindowsVisited);
    BOOL ok=PECompare(rect,wid,expected,getpid(),"main-window",12);

    /* If the system exposes an attached sheet through AX, compare that exact
     * child identity through the same owner filter as a second geometry case. */
    CFArrayRef sheets=PECopySheets(expected);
    if (sheets && CFArrayGetCount(sheets)>0) {
        AXUIElementRef child=(AXUIElementRef)CFArrayGetValueAtIndex(sheets,0);
        CGRect childRect; int ids[128],count=0,i,found=0; CGSConnectionID owner=0;
        if (CGSGetConnectionIDForPSN(_CGSDefaultConnection(),&selfPSN,&owner)!=kCGErrorSuccess) owner=0;
        if (PEAXRect(child,&childRect) &&
            owner && CGSGetOnScreenWindowList(_CGSDefaultConnection(),owner,128,ids,&count)==kCGErrorSuccess) {
            for(i=0;i<count;i++){CGRect g;if(CGSGetScreenRectForWindow(_CGSDefaultConnection(),ids[i],&g)==0 && PEEqualRect(g,childRect)){if(found){found=0;break;}found=ids[i];}}
            BOOL semanticForward=PESheetBelongsToFocus(child,expected);
            BOOL semanticReverseRejected=!PESheetBelongsToFocus(expected,child);
            if(found && !semanticForward) ok=NO;
            if(found) ok=PECompare(childRect,found,child,getpid(),"attached-sheet",4) && ok;
            if(!semanticForward || !semanticReverseRejected) ok=NO;
            printf("SHEET-SEMANTICS targetIsAttachedSheet=%d reverseRejected=%d\n",
                   semanticForward,semanticReverseRejected);
        }
        printf("SHEET exposed=%d identityRelationship=%d\n",found!=0,
               found && PESheetBelongsToFocus(child,expected));
        if (!found) ok=NO;
    } else { printf("SHEET exposed=0 identityRelationship=FAIL\n"); ok=NO; }
    if(sheets)CFRelease(sheets);
    printf("FINAL %s\n",ok?"PASS":"FAIL");
    CFRelease(expected); [NSApp endSheet:sheet]; [window orderOut:nil]; [window release];
    [sheet release]; [delegate release]; [pool drain];
    return ok?0:1;
}
