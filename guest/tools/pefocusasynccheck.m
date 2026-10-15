/* Bounded PPC state/lifecycle fixture for PE_FOCUS_ASYNC. It exercises the
 * production coalescing/generation and target-lease primitives with a fake
 * worker stall; it never sends input or raises a real guest window. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
#include <mach/mach_time.h>
#include <pthread.h>
#include <unistd.h>

static volatile int fakeWorkerEntered;
static volatile int fakeWorkerFinished;
static unsigned heartbeatTicks;
@interface PEFocusHeartbeat : NSObject
- (void)tick:(NSTimer *)timer;
@end
@implementation PEFocusHeartbeat
- (void)tick:(NSTimer *)timer { heartbeatTicks++; }
@end
static void *PEFakeBlockedQuery(void *unused)
{
    fakeWorkerEntered=1;
    usleep(250000);
    fakeWorkerFinished=1;
    return NULL;
}

static double PEMs(uint64_t ticks)
{
    static mach_timebase_info_data_t info;
    if(!info.denom)mach_timebase_info(&info);
    return (double)ticks*(double)info.numer/(double)info.denom/1000000.0;
}

int main(void)
{
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    alarm(5);
    int failures=0;
    PEFocusAsyncState state; PEFocusAsyncJob active={0},pending={0};
    PEFocusStateInit(&state); PEFocusStateSession(&state,YES); PEFocusStateHarmony(&state,YES);

    PEFocusStateEnqueue(&state,40,10,NO); PEFocusStateTake(&state,&active);
    if(!PEFocusStateCurrent(&state,active))failures++;
    PEFocusStateEnqueue(&state,41,11,NO); PEFocusStateEnqueue(&state,42,12,YES);
    if(!PEFocusStateTake(&state,&pending) || pending.wid!=42 || pending.sequence!=12)failures++;
    BOOL coalesced=(pending.wid==42&&pending.sequence==12&&pending.bringAppForward);
    if(!coalesced)failures++;
    printf("COALESCE active=%d/%d pending=%d/%d replaced=1 modeSnapshot=%d result=%s\n",active.wid,active.sequence,
           pending.wid,pending.sequence,pending.bringAppForward,coalesced?"PASS":"FAIL");

    pthread_t worker; fakeWorkerEntered=0; fakeWorkerFinished=0;
    if(pthread_create(&worker,NULL,PEFakeBlockedQuery,NULL)!=0)failures++;
    while(!fakeWorkerEntered)usleep(1000);
    uint64_t start=mach_absolute_time();
    PEFocusStateEnqueue(&state,43,13,NO); PEFocusStateEnqueue(&state,44,14,NO);
    double enqueueMS=PEMs(mach_absolute_time()-start);
    if(enqueueMS>50.0 || !PEFocusStateTake(&state,&pending) || pending.wid!=44)failures++;
    heartbeatTicks=0; PEFocusHeartbeat *heartbeat=[[PEFocusHeartbeat alloc]init];
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:0.16];
    NSTimer *timer=[NSTimer scheduledTimerWithTimeInterval:0.01 target:heartbeat
        selector:@selector(tick:) userInfo:nil repeats:YES];
    while([until timeIntervalSinceNow]>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
    [timer invalidate]; pthread_join(worker,NULL);
    if(!fakeWorkerFinished || heartbeatTicks==0)failures++;
    printf("BLOCKED-WORKER enqueueMS=%.3f mainRunLoopTicks=%u workerFinished=%d result=%s\n",enqueueMS,heartbeatTicks,
           fakeWorkerFinished,(enqueueMS<=50.0&&heartbeatTicks>0&&fakeWorkerFinished)?"PASS":"FAIL");
    [heartbeat release];

    PEFocusStateEnqueue(&state,45,15,NO); PEFocusStateTake(&state,&active);
    PEFocusStateSession(&state,NO);
    BOOL disconnectCurrent=PEFocusStateCurrent(&state,active);
    BOOL disconnectAck=disconnectCurrent && PEFocusCanAcknowledge(YES,NO,YES,YES,NO,YES);
    if(disconnectCurrent || disconnectAck)failures++;
    printf("STALE-DISCONNECT beforeActivation=%s noAck=%s\n",!disconnectCurrent?"PASS":"FAIL",!disconnectAck?"PASS":"FAIL");
    PEFocusStateSession(&state,YES); PEFocusStateHarmony(&state,YES);
    if(PEFocusStateCurrent(&state,active))failures++;
    PEFocusStateEnqueue(&state,46,16,NO); PEFocusStateTake(&state,&active);
    PEFocusStateSession(&state,NO); PEFocusStateSession(&state,YES);
    BOOL newSessionCurrent=PEFocusStateCurrent(&state,active);
    BOOL newSessionAck=newSessionCurrent && PEFocusCanAcknowledge(YES,NO,YES,YES,NO,YES);
    if(newSessionCurrent || newSessionAck)failures++;
    printf("STALE-NEW-SESSION beforeActivation=%s noAck=%s\n",!newSessionCurrent?"PASS":"FAIL",!newSessionAck?"PASS":"FAIL");
    PEFocusStateHarmony(&state,YES);
    PEFocusStateEnqueue(&state,46,16,NO); PEFocusStateTake(&state,&active);
    PEFocusStateEnqueue(&state,47,17,NO);
    if(PEFocusStateCurrent(&state,active))failures++;
    PEFocusStateTake(&state,&pending);
    PEFocusStateHarmony(&state,NO);
    BOOL exitCurrent=PEFocusStateCurrent(&state,pending);
    BOOL exitAck=exitCurrent && PEFocusCanAcknowledge(YES,NO,YES,YES,NO,YES);
    if(exitCurrent || exitAck || PEFocusStateCurrent(&state,active))failures++;
    printf("STALE sessionEpochSequence harmonyExit=%s staleBeforeActivation=%s noAckAfterExit=%s\n",
        !exitCurrent?"PASS":"FAIL",!PEFocusStateCurrent(&state,active)?"PASS":"FAIL",!exitAck?"PASS":"FAIL");

    BOOL cases[]={
        PEFocusCanAcknowledge(YES,NO,YES,YES,NO,YES),
        PEFocusCanAcknowledge(YES,YES,YES,YES,NO,YES),
        PEFocusCanAcknowledge(YES,NO,YES,YES,YES,YES),
        PEFocusCanAcknowledge(YES,NO,YES,NO,NO,YES),
        PEFocusCanAcknowledge(YES,NO,YES,YES,NO,NO),
        PEFocusCanAcknowledge(NO,NO,YES,YES,NO,YES)
    };
    if(!cases[0])failures++;
    int i;for(i=1;i<6;i++)if(cases[i])failures++;
    printf("ACK-POLICY success=%d minimized=%d sheet=%d focusMismatch=%d staleGeometry=%d noTarget=%d result=%s\n",
           cases[0],cases[1],cases[2],cases[3],cases[4],cases[5],(!failures)?"PASS":"FAIL");

    BOOL finalCases[]={
        PEFocusFinalAckAllowed(YES,188,188,YES,YES,YES),
        PEFocusFinalAckAllowed(YES,188,222,YES,YES,YES),
        PEFocusFinalAckAllowed(YES,188,188,NO,YES,YES),
        PEFocusFinalAckAllowed(YES,188,188,YES,NO,YES),
        PEFocusFinalAckAllowed(YES,188,188,YES,YES,NO)
    };
    if(!finalCases[0])failures++;
    for(i=1;i<5;i++)if(finalCases[i])failures++;
    printf("FINAL-ACK positive=%d foregroundChanged=%d closedOrResized=%d ownerChanged=%d staleRequest=%d result=%s\n",
        finalCases[0],finalCases[1],finalCases[2],finalCases[3],finalCases[4],
        (finalCases[0]&&!finalCases[1]&&!finalCases[2]&&!finalCases[3]&&!finalCases[4])?"PASS":"FAIL");

    PEMenuAsyncState menus; PEMenuAsyncJob menuA={0},menuB={0},menuC={0};
    PEMenuStateInit(&menus);
    BOOL menuAccepted=PEMenuStateRequest(&menus,188,3,7,&menuA);
    BOOL duplicateAccepted=PEMenuStateRequest(&menus,188,3,7,NULL);
    BOOL replacementAccepted=PEMenuStateRequest(&menus,222,3,7,&menuB);
    PEMenuStateTake(&menus,&menuC);
    BOOL replaced=menuC.pid==222 && menuC.generation==menuB.generation && !PEMenuStateCurrent(&menus,menuA);
    PEMenuStateInvalidate(&menus);
    BOOL invalidated=!PEMenuStateCurrent(&menus,menuB);
    if(!menuAccepted||duplicateAccepted||!replacementAccepted||!replaced||!invalidated)failures++;
    printf("MENU-QUEUE first=%d samePIDCoalesced=%d replacedPID=%d staleResultSuppressed=%d result=%s\n",
        menuAccepted,!duplicateAccepted,replaced,invalidated,
        (menuAccepted&&!duplicateAccepted&&replacementAccepted&&replaced&&invalidated)?"PASS":"FAIL");

    CFStringRef expected=CFStringCreateWithCString(NULL,"retained-target",kCFStringEncodingUTF8);
    PEFocusAsyncJob leaseJob={48,18,state.session,state.epoch,NO};
    PEFocusTargetLease *lease=[[PEFocusTargetLease alloc]initWithTarget:(AXUIElementRef)expected
        pid:188 rect:CGRectMake(1,2,3,4) job:leaseJob];
    BOOL retained=lease->target && CFEqual((CFTypeRef)lease->target,(CFTypeRef)expected) && CFGetRetainCount(expected)==2;
    PEFocusStateSession(&state,NO); /* Invalidate delivery without freeing executing lease. */
    BOOL staleLeaseRetained=lease->target && !PEFocusStateCurrent(&state,lease->job);
    [lease release];
    BOOL releasedAfterStale=CFGetRetainCount(expected)==1;
    PEFocusTargetLease *completedLease=[[PEFocusTargetLease alloc]initWithTarget:(AXUIElementRef)expected
        pid:188 rect:CGRectMake(1,2,3,4) job:leaseJob];
    BOOL heldThroughCompletion=CFGetRetainCount(expected)==2;
    [completedLease release];
    BOOL releasedAfterCompletion=CFGetRetainCount(expected)==1;
    CFRelease(expected);
    if(!retained || !staleLeaseRetained || !releasedAfterStale || !heldThroughCompletion || !releasedAfterCompletion)failures++;
    printf("LEASE retained=%d staleDeliveryRejected=%d releaseAfterStale=%d heldThroughCompletion=%d releaseAfterCompletion=%d result=%s\n",retained,
           staleLeaseRetained,releasedAfterStale,heldThroughCompletion,releasedAfterCompletion,
           (retained&&staleLeaseRetained&&releasedAfterStale&&heldThroughCompletion&&releasedAfterCompletion)?"PASS":"FAIL");
    printf("FINAL %s failures=%d\n",failures?"FAIL":"PASS",failures);
    [pool drain]; return failures?1:0;
}
