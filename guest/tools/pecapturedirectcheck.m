/* Uses the actual capture-only receiver with a recording worker, not window
 * capture. Main thread never runs its run loop during the request test. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
#include <sys/socket.h>
#include <pthread.h>
static pthread_t testMainThread;
@interface DirectCheck:PEAgent { @public NSConditionLock *finished;unsigned calls,failures; }
@end
@implementation DirectCheck
- (void)captureWorker:(NSArray *)job {
    if(pthread_equal(pthread_self(),testMainThread)||![ [[job objectAtIndex:0] componentsSeparatedByString:@" "] count] || ![[job objectAtIndex:1] isEqual:@"fixture-session"])failures++;
    calls++;
}
- (void)runReceiver:(NSArray *)context {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];[self readCaptureRequests:context];
    [finished lock];[finished unlockWithCondition:1];[pool drain];
}
@end
int main(void) {
    testMainThread=pthread_self();NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];NSApplicationLoad();
    int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))return 2;
    DirectCheck *agent=[[DirectCheck alloc] init];agent->finished=[[NSConditionLock alloc] initWithCondition:0];
    [NSThread detachNewThreadSelector:@selector(runReceiver:) toTarget:agent withObject:
        [NSArray arrayWithObjects:[NSNumber numberWithInt:pair[1]],@"fixture-session",nil]];
    const char *wire="WINDOWFRAME 20\n12 1 0 rle32 tiles32WINDOWFRAME 26\n12 2 1 rle32 tiles32 freshRUN 4\nnoop";
    size_t n=strlen(wire);if(write(pair[0],wire,n)!=(ssize_t)n)return 3;shutdown(pair[0],SHUT_WR);
    BOOL done=[agent->finished lockWhenCondition:1 beforeDate:[NSDate dateWithTimeIntervalSinceNow:5]];
    if(done)[agent->finished unlockWithCondition:1];
    int failure=!done||agent->calls!=2||agent->failures;
    printf("%s direct receiver: two valid jobs, rejects RUN, no main run loop serviced\n",failure?"FAIL":"PASS");
    close(pair[0]);close(pair[1]);[pool drain];return failure;
}
