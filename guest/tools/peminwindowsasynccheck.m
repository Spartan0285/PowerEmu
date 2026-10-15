/* Bounded queue, replacement, staleness and blocked-worker fixture. */
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <string.h>
#include "../src/PEMinWindowsAsyncState.h"

static void fail(int *n, BOOL condition) { if (!condition) (*n)++; }

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    PEMinWindowsState state;
    PEMinWindowsJob active, pending, next;
    int failures = 0;
    int first[] = {188, 222, 333};
    int replacement[] = {188, 444};
    PEMinWindowsStateInit(&state);
    memset(&active,0,sizeof(active)); memset(&pending,0,sizeof(pending)); memset(&next,0,sizeof(next));
    PEMinWindowsStateSetContext(&state, YES, YES, 5, 9);
    fail(&failures, PEMinWindowsStateEnqueue(&state, first, 3, 5, 9, NULL));
    fail(&failures, PEMinWindowsStateTake(&state, &active));
    /* Model an AX IPC that has not returned: active remains occupied while
     * the sole pending snapshot can be replaced without growing a queue. */
    fail(&failures, PEMinWindowsStateEnqueue(&state, first, 3, 5, 9, NULL) == NO);
    fail(&failures, PEMinWindowsStateEnqueue(&state, replacement, 2, 5, 9, &pending));
    int obsolete[] = {188, 555, 666};
    fail(&failures, PEMinWindowsStateEnqueue(&state, obsolete, 3, 5, 9, &pending));
    BOOL replaced = state.active && state.hasPending && state.pendingJob.count == 3 &&
        state.pendingJob.pids[1] == 555 && state.droppedPending == 1 &&
        !PEMinWindowsStateReady(&state);
    BOOL activeStayedBounded = state.active && state.hasPending && !PEMinWindowsStateReady(&state);
    fail(&failures, replaced);
    BOOL activeCancelledBetweenProcesses = !PEMinWindowsStateCanContinue(&state, active);
    fail(&failures, activeCancelledBetweenProcesses);
    PEMinWindowsStateFinish(&state, active);
    BOOL pendingWakes = PEMinWindowsStateReady(&state) && PEMinWindowsStateTake(&state, &next) &&
        next.sequence == pending.sequence && next.pids[1] == 555;
    fail(&failures, pendingWakes);
    printf("REPLACE activeBlocked=%d onePending=%d oldStopsBeforeNextPID=%d latestTaken=%d result=%s\n",
        activeStayedBounded, replaced, activeCancelledBetweenProcesses, pendingWakes,
        (replaced && activeCancelledBetweenProcesses && pendingWakes) ? "PASS" : "FAIL");

    BOOL publish = PEMinWindowsStateCanPublish(&state, next, YES, YES, 5, 9);
    BOOL badSession = !PEMinWindowsStateCanPublish(&state, next, YES, YES, 6, 9);
    BOOL badEpoch = !PEMinWindowsStateCanPublish(&state, next, YES, YES, 5, 10);
    BOOL disconnected = !PEMinWindowsStateCanPublish(&state, next, NO, YES, 5, 9);
    BOOL harmonyOff = !PEMinWindowsStateCanPublish(&state, next, YES, NO, 5, 9);
    fail(&failures, publish && badSession && badEpoch && disconnected && harmonyOff);
    PEMinWindowsStateSetContext(&state, YES, YES, 5, 10); /* new Harmony epoch */
    BOOL transitionDrops = !PEMinWindowsStateCanPublish(&state, next, YES, YES, 5, 10) &&
        state.generation != next.generation;
    fail(&failures, transitionDrops);
    PEMinWindowsStateFinish(&state, next);
    unsigned beforeInvalidate=state.generation;
    PEMinWindowsStateInvalidate(&state);
    BOOL repeatedHarmonyOnInvalidates = state.generation != beforeInvalidate && !state.hasPending;
    fail(&failures, repeatedHarmonyOnInvalidates);
    BOOL capAccepted = NO;
    int cap[PE_MIN_WINDOWS_PID_MAX];
    unsigned i;
    for (i = 0; i < PE_MIN_WINDOWS_PID_MAX; i++) cap[i] = (int)i + 1;
    capAccepted = PEMinWindowsStateEnqueue(&state, cap, PE_MIN_WINDOWS_PID_MAX, 5, 10, &pending);
    BOOL capOK = capAccepted && pending.count == PE_MIN_WINDOWS_PID_MAX &&
        pending.pids[0] == 1 && pending.pids[PE_MIN_WINDOWS_PID_MAX - 1] == PE_MIN_WINDOWS_PID_MAX;
    BOOL overCapRejected = !PEMinWindowsStateEnqueue(&state, cap, PE_MIN_WINDOWS_PID_MAX + 1, 5, 10, NULL);
    fail(&failures, capOK && overCapRejected);
    printf("FRESH publish=%d wrongSession=%d wrongEpoch=%d disconnect=%d harmonyOff=%d transitionInvalidates=%d cap256=%d overCapRejected=%d result=%s\n",
        publish, badSession, badEpoch, disconnected, harmonyOff, transitionDrops, capOK,
        overCapRejected, (publish && badSession && badEpoch && disconnected && harmonyOff &&
        transitionDrops && capOK && overCapRejected) ? "PASS" : "FAIL");
    printf("FINAL %s failures=%d\n", failures ? "FAIL" : "PASS", failures);
    [pool drain];
    return failures ? 1 : 0;
}
