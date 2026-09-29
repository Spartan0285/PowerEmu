#ifndef PE_FULLSCREEN_STATE_H
#define PE_FULLSCREEN_STATE_H
/* Called only on the guest main thread. No window-size heuristics: ordinary
 * maximized windows and Harmony's hidden desktop must not trigger an exit. */
typedef struct {
    double since;
    int observing;
    int reported;
} PEFullscreenState;

static int PEFullscreenUpdate(PEFullscreenState *state, int captured, double now)
{
    if (!captured) {
        state->observing = state->reported = 0;
        return 0;
    }
    if (!state->observing) {
        state->observing = 1;
        state->since = now;
    }
    if (!state->reported && now - state->since >= 0.15) {
        state->reported = 1;
        return 1;
    }
    return 0;
}
#endif
