/* Pure bounded-queue/lifecycle fixture for the optional async MENUITEMS path. */
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <unistd.h>
#include "../src/PEMenuItemsAsyncState.h"

int main(void)
{
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    alarm(5);
    int failures=0, i;
    PEMenuItemsState state; PEMenuItemsJob job, active, next;
    PEMenuItemsStateInit(&state);
    PEMenuItemsStateSetForeground(&state,188,3,7);

    for(i=0;i<20;i++) {
        char path[16]; sprintf(path,"%d",i);
        if(!PEMenuItemsStateEnqueue(&state,188,path,3,7,NULL)) failures++;
    }
    BOOL bounded=state.count==PE_MENU_ITEMS_PENDING_MAX &&
        !strcmp(state.pending[0].path,"4") && !strcmp(state.pending[15].path,"19");
    if(!bounded)failures++;
    printf("BOUND pending=%u first=%s last=%s result=%s\n",state.count,state.pending[0].path,
        state.pending[state.count-1].path,bounded?"PASS":"FAIL");

    PEMenuItemsState staleQueue; PEMenuItemsJob fresh;
    PEMenuItemsStateInit(&staleQueue); PEMenuItemsStateSetForeground(&staleQueue,188,3,7);
    for(i=0;i<8;i++) { char path[16]; sprintf(path,"%d",i);
        PEMenuItemsStateEnqueue(&staleQueue,188,path,3,7,NULL); }
    unsigned dropped=PEMenuItemsStateSetForeground(&staleQueue,222,3,7);
    PEMenuItemsStateEnqueue(&staleQueue,222,"0",3,7,NULL);
    BOOL oldQueueDropped=dropped==8 && staleQueue.count==1 &&
        PEMenuItemsStateTake(&staleQueue,&fresh) && fresh.pid==222;
    if(!oldQueueDropped)failures++;
    printf("FOREGROUND queuedOldPIDDropped=%u nextPID=%d result=%s\n",dropped,fresh.pid,
        oldQueueDropped?"PASS":"FAIL");

    BOOL took=PEMenuItemsStateTake(&state,&active);
    BOOL duplicateActive=!PEMenuItemsStateEnqueue(&state,188,active.path,3,7,NULL);
    BOOL duplicatePending=!PEMenuItemsStateEnqueue(&state,188,"5",3,7,NULL);
    BOOL activePublish=PEMenuItemsStateCanPublish(&state,active,YES,YES,3,7,188);
    BOOL wrongFrontRejected=!PEMenuItemsStateCanPublish(&state,active,YES,YES,3,7,222);
    BOOL noSpinWhileActive=!PEMenuItemsStateReady(&state);
    if(!took||!duplicateActive||!duplicatePending||!activePublish||!wrongFrontRejected||!noSpinWhileActive)failures++;

    BOOL wrongSession=!PEMenuItemsStateCanPublish(&state,active,YES,YES,4,7,188);
    BOOL wrongEpoch=!PEMenuItemsStateCanPublish(&state,active,YES,YES,3,8,188);
    BOOL disconnected=!PEMenuItemsStateCanPublish(&state,active,NO,YES,3,7,188);
    BOOL harmonyExit=!PEMenuItemsStateCanPublish(&state,active,YES,NO,3,7,188);
    if(wrongSession==NO||wrongEpoch==NO||disconnected==NO||harmonyExit==NO)failures++;
    printf("STALE session=%d epoch=%d disconnect=%d harmonyExit=%d result=%s\n",
        wrongSession,wrongEpoch,disconnected,harmonyExit,
        (wrongSession&&wrongEpoch&&disconnected&&harmonyExit)?"PASS":"FAIL");

    PEMenuItemsStateFinish(&state,active);
    BOOL pendingWakesWorker=PEMenuItemsStateReady(&state);
    if(!pendingWakesWorker)failures++;
    printf("DEDUP active=%d pending=%d currentFront=%d wrongFrontRejected=%d readyAfterAck=%d result=%s\n",
        duplicateActive,duplicatePending,activePublish,wrongFrontRejected,pendingWakesWorker,
        (took&&duplicateActive&&duplicatePending&&activePublish&&wrongFrontRejected&&
         noSpinWhileActive&&pendingWakesWorker)?"PASS":"FAIL");

    PEMenuItemsStateInvalidate(&state);
    BOOL invalidationRejected=!PEMenuItemsStateCanPublish(&state,active,YES,YES,3,7,188);
    BOOL emptyAfterExit=state.count==0;
    if(!invalidationRejected||!emptyAfterExit)failures++;
    PEMenuItemsStateInvalidate(&state); /* disconnect/new session boundary */
    PEMenuItemsStateSetForeground(&state,188,4,8);
    if(!PEMenuItemsStateEnqueue(&state,188,"0",4,8,&job) ||
       !PEMenuItemsStateTake(&state,&next)) failures++;
    BOOL freshSession=PEMenuItemsStateCanPublish(&state,next,YES,YES,4,8,188);
    BOOL oldCannotPublish=!PEMenuItemsStateCanPublish(&state,active,YES,YES,4,8,188);
    if(!freshSession||!oldCannotPublish)failures++;
    printf("INVALIDATE queueCleared=%d oldResultDropped=%d newSessionAccepted=%d result=%s\n",
        emptyAfterExit,invalidationRejected&&oldCannotPublish,freshSession,
        (emptyAfterExit&&invalidationRejected&&freshSession&&oldCannotPublish)?"PASS":"FAIL");

    PEMenuItemsStateFinish(&state,next);
    BOOL returned=PEMenuItemsStateEnqueue(&state,188,"0",4,8,NULL);
    BOOL tailBound=PEMenuItemsStateEnqueue(&state,188,"0.1",4,8,NULL);
    if(!returned||!tailBound) failures++;
    printf("RETURN sameKeyCanRetry=%d distinctPathAccepted=%d result=%s\n",returned,tailBound,
        (returned&&tailBound)?"PASS":"FAIL");
    printf("FINAL %s failures=%d\n",failures?"FAIL":"PASS",failures);
    [pool drain]; return failures?1:0;
}
