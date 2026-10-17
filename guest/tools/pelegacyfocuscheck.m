/* No GUI or socket operations: exercise production stale-retry early exits. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
#include <assert.h>
@interface PELegacyFocusFixture : PEAgent {
    unsigned leaseChecks;
}
- (void)checkRecovery;
@end
@implementation PELegacyFocusFixture
/* Isolate unrelated menu/minimized-window workers; production harmony:NO
 * must invalidate its lease BEFORE these callbacks and its early return. */
- (void)invalidateAsyncMinWindows {}
- (void)refreshAsyncMinWindowsContext {}
- (BOOL)isAsyncFocusJobCurrent:(PEFocusAsyncJob)job {
    leaseChecks++;
    BOOL current = [super isAsyncFocusJobCurrent:job];
    assert(!current); /* Every request in this fixture must stop before CGS/AX. */
    return current;
}
- (void)checkRecovery {
    focusCondition = [[NSConditionLock alloc] initWithCondition:0];
    PEFocusStateInit(&focusState);
    PEFocusStateSession(&focusState, YES); PEFocusStateHarmony(&focusState, YES);
    PEFocusAsyncJob job;
    PEFocusStateEnqueue(&focusState, 42, 7, NO); PEFocusStateTake(&focusState, &job);
    focusRequestSequence = 7;
    NSArray *request = [NSArray arrayWithObjects:@"42", @"7", @"1",
        [NSData dataWithBytes:&job length:sizeof(job)], nil];
    [self harmony:NO]; /* Production exit, with no window timer. */
    assert(!focusState.harmonyActive);
    [self confirmFocus:request]; assert(leaseChecks == 1);
    PEFocusStateHarmony(&focusState, YES);
    PEFocusStateEnqueue(&focusState, 42, 7, NO); /* Reused sequence after reentry. */
    [self confirmFocus:request]; assert(leaseChecks == 2);
    PEFocusStateSession(&focusState, NO); PEFocusStateSession(&focusState, YES);
    PEFocusStateEnqueue(&focusState, 42, 7, NO);
    [self confirmFocus:request]; assert(leaseChecks == 3);
    [self confirmFocus:[NSArray array]]; assert(leaseChecks == 3);
    /* Dispatch an old delayed request through an actual nested run loop. */
    [self performSelector:@selector(confirmFocus:) withObject:request afterDelay:0];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.1];
    while (leaseChecks == 3 && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    assert(leaseChecks == 4);
    [focusCondition release]; focusCondition = nil;
}
@end
int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    alarm(5);
    /* Deliberately bypass PEAgent init (pasteboard/diagnostic setup). */
    PELegacyFocusFixture *fixture = [PELegacyFocusFixture alloc];
    [fixture checkRecovery];
    puts("PASS production Harmony exit, stale confirmFocus, reused sequence, reconnect, malformed request, nested run-loop retry; no AX/CGS reached");
    [pool drain]; return 0;
}
