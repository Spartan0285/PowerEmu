#include <assert.h>
#include <stdio.h>
#include "../src/PEFullscreenState.h"
int main(void) {
    PEFullscreenState state = {0};
    int i;
    for (i = 0; i < 1000; ++i) assert(!PEFullscreenUpdate(&state, 0, i));
    assert(!PEFullscreenUpdate(&state, 1, 1000));
    assert(!PEFullscreenUpdate(&state, 1, 1000.10));
    assert(!PEFullscreenUpdate(&state, 0, 1000.11));
    assert(!PEFullscreenUpdate(&state, 1, 1000.12));
    assert(!PEFullscreenUpdate(&state, 1, 1000.20));
    assert(PEFullscreenUpdate(&state, 1, 1000.30));
    for (i = 0; i < 1000; ++i) assert(!PEFullscreenUpdate(&state, 1, 1001+i));
    assert(!PEFullscreenUpdate(&state, 0, 2001));
    assert(!PEFullscreenUpdate(&state, 1, 2002));
    assert(PEFullscreenUpdate(&state, 1, 2002.20));
    puts("PASS: normal desktop, transient capture, debounce, one report per capture, release/re-entry");
    return 0;
}
