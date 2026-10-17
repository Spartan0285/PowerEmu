#include <assert.h>
#include <stdio.h>
typedef int BOOL;
#define YES 1
#define NO 0
#include "../../guest/src/PEFocusAsyncState.h"
int main(void) {
    PEFocusAsyncState s; PEFocusAsyncJob old, fresh;
    PEFocusStateInit(&s);
    assert(!PEFocusStateEnqueue(&s, 42, 1, NO));
    PEFocusStateSession(&s, YES); PEFocusStateHarmony(&s, YES);
    assert(PEFocusStateEnqueue(&s, 42, 1, NO)); PEFocusStateTake(&s, &old);
    assert(PEFocusStateCurrent(&s, old));
    /* Teardown nested loop: retry rejected while the old timer still exists. */
    PEFocusStateHarmony(&s, NO);
    assert(!PEFocusStateCurrent(&s, old));
    assert(!PEFocusStateEnqueue(&s, 42, 1, NO));
    PEFocusStateHarmony(&s, YES);
    assert(PEFocusStateEnqueue(&s, 42, 1, NO)); PEFocusStateTake(&s, &fresh);
    assert(!PEFocusStateCurrent(&s, old)); assert(PEFocusStateCurrent(&s, fresh));
    old = fresh;
    PEFocusStateSession(&s, NO); assert(!PEFocusStateCurrent(&s, old));
    PEFocusStateSession(&s, YES);
    assert(PEFocusStateEnqueue(&s, 42, 1, NO)); PEFocusStateTake(&s, &fresh);
    assert(!PEFocusStateCurrent(&s, old)); assert(PEFocusStateCurrent(&s, fresh));
    PEFocusStateEnqueue(&s, 43, 2, NO);
    assert(!PEFocusStateCurrent(&s, fresh));
    puts("PASS: inactive, teardown, reentry/sequence reuse, reconnect and replacement gates");
    return 0;
}
