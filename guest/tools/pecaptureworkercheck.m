/* Bounded dispatch comparison for the production capture queue. Run with
 * PE_PROFILE_DISPATCH=thread or persistent; captures are read-only. */
/* Read-only integration check against a stationary guest window. Compile on
 * the G4 with the same SDK/framework flags as PEAgent.m, then run in Tiger:
 * pecapturecheck WINDOW_ID. No input, focus, or window changes are performed. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main

@interface PECaptureCheckAgent : PEAgent { @public NSConditionLock *finished; int workerFailures; BOOL queueTest; NSConditionLock *entered, *gate; NSMutableArray *calls; }
- (BOOL)verifyScratchIsolation:(int)window;
@end
@implementation PECaptureCheckAgent
- (BOOL)verifyScratchIsolation:(int)window
{
    NSData *cached = [[captureHistory objectForKey:[NSString stringWithFormat:@"%d", window]] objectForKey:@"pixels"];
    if (!cached || !captureScratch || [cached bytes] == [captureScratch bytes]) return NO;
    NSData *before = [[cached copy] autorelease];
    memset([captureScratch mutableBytes], 0xa5, [captureScratch length]);
    return [cached isEqualToData:before];
}
@end

static int inspect(PEAgent *agent, int window, int sequence, int accepted,
                   int expectedEncoding, int expectedWidth)
{
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSData *packet = [agent captureWindow:[NSString stringWithFormat:@"%d %d %d%@", window, sequence, accepted, getenv("PE_PROFILE_CODECS") ? @" rle32 tiles32" : @""]];
    const char *bytes = [packet bytes];
    const char *end = memchr(bytes, '\n', [packet length]);
    if (!end) return 1;
    NSString *head = [[[NSString alloc] initWithBytes:bytes length:end - bytes encoding:NSASCIIStringEncoding] autorelease];
    int wid = 0, w = 0, h = 0, encoding = -1, replySequence = 0;
    if (sscanf([head UTF8String], "%d %d %d %d %d", &wid, &w, &h, &encoding, &replySequence) != 5) return 1;
    printf("request=%d accepted=%d encoding=%d size=%dx%d bytes=%lu elapsed_ms=%.2f\n",
        sequence, accepted, encoding, w, h, (unsigned long)[packet length],
        (CFAbsoluteTimeGetCurrent() - start) * 1000);
    if (wid != window || replySequence != sequence) return 1;
    if (expectedWidth == 0) return w != 0 || h != 0;
    if (w <= 0 || h <= 0) return 1;
    if (expectedEncoding == 2) return encoding != 2 || [packet length] != end - bytes + 1;
    return encoding != 0 && encoding != 1 && encoding != 3 && encoding != 4;
}

@implementation PECaptureCheckAgent (DispatchCheck)
- (void)captureWorker:(NSArray *)job {
 NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
 if(queueTest) {
  if([[job objectAtIndex:0] isEqualToString:@"blocked"]) { [entered lock];[entered unlockWithCondition:1];[gate lockWhenCondition:1];[gate unlockWithCondition:1]; }
  [finished lock];[calls addObject:[job objectAtIndex:0]];[finished unlockWithCondition:1];[pool drain];return;
 }
 int wid=[[job objectAtIndex:0] intValue],seq=[[job objectAtIndex:1] intValue];
 workerFailures=inspect(self,wid,seq,seq%2 ? 0 : seq-1,seq%2 ? 1 : 2,1);
 [finished lock];[finished unlockWithCondition:1];[pool drain];
}
@end
int main(int argc, const char *argv[])
{
    if (argc != 2) { fprintf(stderr, "usage: pecapturecheck STATIONARY_WINDOW_ID\n"); return 2; }
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSApplicationLoad();
    PECaptureCheckAgent *agent = [[PECaptureCheckAgent alloc] init];
    if(getenv("PE_PROFILE_REFRESH_TRIGGER")) {
      NSWindow *hint=[[NSWindow alloc] initWithContentRect:NSMakeRect(10,10,8,8) styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
      [hint orderFront:nil];[hint display];CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.1,false);
      [hint orderOut:nil];CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.1,false);[hint release];
    }
    int window = atoi(argv[1]), failures = 0;
    if(getenv("PE_PROFILE_QUEUE_TEST")) {
      agent->queueTest=YES;
      agent->finished=[[NSConditionLock alloc] initWithCondition:0];
      agent->entered=[[NSConditionLock alloc] initWithCondition:0];
      agent->gate=[[NSConditionLock alloc] initWithCondition:0];
      agent->calls=[[NSMutableArray alloc] init];
      [agent queueCapture:[NSArray arrayWithObject:@"blocked"]];
      [agent->entered lockWhenCondition:1];[agent->entered unlockWithCondition:1];
      [agent queueCapture:[NSArray arrayWithObject:@"superseded"]];
      [agent queueCapture:[NSArray arrayWithObject:@"latest"]];
      [agent->gate lock];[agent->gate unlockWithCondition:1];
      for(;;) {
        [agent->finished lockWhenCondition:1];
        BOOL done=[agent->calls count]>=2;
        if(done) failures=!([agent->calls count]==2 && [[agent->calls objectAtIndex:0] isEqualToString:@"blocked"] && [[agent->calls objectAtIndex:1] isEqualToString:@"latest"]);
        [agent->finished unlockWithCondition:0];if(done)break;
      }
      printf("%s bounded queue keeps executing job and latest pending job\n",failures?"FAIL":"PASS");
      [pool drain];return failures?1:0;
    }
    if (window < 0) {
        int ids[256], count = 0, i, cid = _CGSDefaultConnection();
        if (CGSGetOnScreenWindowList(cid, 0, 256, ids, &count) != kCGErrorSuccess) return 3;
        for (i = 0; i < count; i++) {
            int level = -1; CGRect rect;
            if (CGSGetWindowLevel(cid, ids[i], &level) == kCGErrorSuccess && level == 0 &&
                CGSGetScreenRectForWindow(cid, ids[i], &rect) == kCGErrorSuccess && rect.size.width > 400) {
                window = ids[i]; break;
            }
        }
        if (window < 0) return 4;
    }
    const char *dispatch=getenv("PE_PROFILE_DISPATCH");
    if(dispatch) {
      agent->finished=[[NSConditionLock alloc] initWithCondition:0];
      int seq;
      for(seq=1;seq<=30;seq++) {
        CFAbsoluteTime began=CFAbsoluteTimeGetCurrent();
        NSArray *job=[NSArray arrayWithObjects:[NSString stringWithFormat:@"%d",window], [NSNumber numberWithInt:seq],nil];
        if(!strcmp(dispatch,"persistent")) [agent queueCapture:job];
        else [NSThread detachNewThreadSelector:@selector(captureWorker:) toTarget:agent withObject:job];
        [agent->finished lockWhenCondition:1];
        failures+=agent->workerFailures;
        [agent->finished unlockWithCondition:0];
        printf("PEDISPATCH mode=%s seq=%d totalMS=%.3f\n",dispatch,seq,(CFAbsoluteTimeGetCurrent()-began)*1000);
      }
      printf("%s dispatch pixels/sequence/unchanged validation\n",failures?"FAIL":"PASS");
      [pool drain];return failures?1:0;
    }
    int repeats = getenv("PE_PROFILE_REPEAT") ? atoi(getenv("PE_PROFILE_REPEAT")) : 0;
    if (repeats > 0) {
        if (repeats > 200) return 2;
        int run;
        for (run = 1; run <= repeats; run++) {
            NSAutoreleasePool *iteration = [[NSAutoreleasePool alloc] init];
            if(getenv("PE_PROFILE_REFRESH_TRIGGER")) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.001,false);
            // Alternate full and acknowledged captures of the same stationary window.
            failures += inspect(agent, window, run, run % 2 ? 0 : run-1, run % 2 ? 1 : 2, 1);
            [iteration drain];
        }
        [agent release]; [pool drain]; return failures ? 1 : 0;
    }
    failures += inspect(agent, window, 1, 0, 1, 1);
    failures += inspect(agent, window, 2, 1, 2, 1);
    failures += inspect(agent, window, 3, 0, 1, 1); // host lost its image
    failures += inspect(agent, window, 4, 2, 1, 1); // stale acknowledgment
    failures += inspect(agent, -1, 5, 0, 0, 0);    // nonexistent window
    if (getenv("PE_CAPTURE_REUSE")) {
        failures += inspect(agent, window, 6, 4, 2, 1);
        if (![agent verifyScratchIsolation:window]) failures++;
        // Repainting poisoned scratch must reproduce the unchanged full image,
        // including pixels the capture API leaves transparent.
        failures += inspect(agent, window, 7, 6, 2, 1);
        int ids[256], count = 0, i, other = 0, cid = _CGSDefaultConnection();
        CGRect original;
        CGSGetScreenRectForWindow(cid, window, &original);
        CGSGetOnScreenWindowList(cid, 0, 256, ids, &count);
        for (i = 0; i < count; i++) {
            CGRect rect;
            if (ids[i] != window && CGSGetScreenRectForWindow(cid, ids[i], &rect) == kCGErrorSuccess &&
                rect.size.width > 0 && rect.size.height > 0 && !CGSizeEqualToSize(rect.size, original.size)) {
                other = ids[i]; break;
            }
        }
        if (!other) { fprintf(stderr, "No second window size available for context replacement test\n"); failures++; }
        else {
            failures += inspect(agent, other, 8, 0, 1, 1);
            failures += inspect(agent, window, 9, 7, 2, 1);
            printf("PASS checks exercised: scratch isolation, cleared corners, context size replacement\n");
        }
    }
    printf("%s: complete frame, unchanged acknowledgment, missing/stale base, invalid window\n", failures ? "FAIL" : "PASS");
    [agent release]; [pool drain];
    return failures ? 1 : 0;
}
