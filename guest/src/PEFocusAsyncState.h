/* Small value-only state shared by the optional async focus path and its
 * bounded fixture. Callers serialize access with their own lock/condition. */
#ifndef PE_FOCUS_ASYNC_STATE_H
#define PE_FOCUS_ASYNC_STATE_H
#include <string.h>

typedef struct {
    int wid;
    int sequence;
    unsigned session;
    unsigned epoch;
    BOOL bringAppForward;
} PEFocusAsyncJob;

typedef struct {
    unsigned session;
    unsigned epoch;
    int latestSequence;
    BOOL connected;
    BOOL harmonyActive;
    BOOL hasPending;
    PEFocusAsyncJob pending;
} PEFocusAsyncState;

typedef struct {
    int pid;
    unsigned session;
    unsigned epoch;
    unsigned generation;
} PEMenuAsyncJob;

typedef struct {
    unsigned generation;
    BOOL hasLatest;
    BOOL outstanding;
    BOOL hasPending;
    PEMenuAsyncJob latest;
    PEMenuAsyncJob pending;
} PEMenuAsyncState;

static void PEMenuStateInit(PEMenuAsyncState *state)
{
    memset(state, 0, sizeof(*state));
}

static BOOL PEMenuStateRequest(PEMenuAsyncState *state, int pid, unsigned session, unsigned epoch,
                               PEMenuAsyncJob *jobOut)
{
    if (pid <= 0) return NO;
    if (state->outstanding && state->hasLatest && state->latest.pid == pid &&
        state->latest.session == session && state->latest.epoch == epoch) return NO;
    state->generation++;
    state->latest.pid = pid;
    state->latest.session = session;
    state->latest.epoch = epoch;
    state->latest.generation = state->generation;
    state->pending = state->latest;
    state->hasLatest = YES;
    state->outstanding = YES;
    state->hasPending = YES;
    if (jobOut) *jobOut = state->pending;
    return YES;
}

static BOOL PEMenuStateTake(PEMenuAsyncState *state, PEMenuAsyncJob *job)
{
    if (!state->hasPending) return NO;
    *job = state->pending;
    state->hasPending = NO;
    return YES;
}

static BOOL PEMenuStateCurrent(const PEMenuAsyncState *state, PEMenuAsyncJob job)
{
    return state->hasLatest && state->generation == job.generation &&
        state->latest.pid == job.pid && state->latest.session == job.session &&
        state->latest.epoch == job.epoch;
}

static void PEMenuStateFinish(PEMenuAsyncState *state, PEMenuAsyncJob job)
{
    if (PEMenuStateCurrent(state, job)) state->outstanding = NO;
}

static void PEMenuStateInvalidate(PEMenuAsyncState *state)
{
    state->generation++;
    state->hasLatest = NO;
    state->outstanding = NO;
    state->hasPending = NO;
}

static void PEFocusStateInit(PEFocusAsyncState *state)
{
    memset(state, 0, sizeof(*state));
    state->latestSequence = -1;
}

static void PEFocusStateSession(PEFocusAsyncState *state, BOOL connected)
{
    state->session++;
    state->connected = connected;
    state->latestSequence = -1;
    state->hasPending = NO;
}

static void PEFocusStateHarmony(PEFocusAsyncState *state, BOOL active)
{
    state->epoch++;
    state->harmonyActive = active;
    state->latestSequence = -1;
    state->hasPending = NO;
}

static BOOL PEFocusStateEnqueue(PEFocusAsyncState *state, int wid, int sequence, BOOL bringAppForward)
{
    if (!state->connected || !state->harmonyActive || wid <= 0) return NO;
    state->latestSequence = sequence;
    state->pending.wid = wid;
    state->pending.sequence = sequence;
    state->pending.session = state->session;
    state->pending.epoch = state->epoch;
    state->pending.bringAppForward = bringAppForward;
    state->hasPending = YES; /* replacing pending work is intentional */
    return YES;
}

static BOOL PEFocusStateTake(PEFocusAsyncState *state, PEFocusAsyncJob *job)
{
    if (!state->hasPending) return NO;
    *job = state->pending;
    state->hasPending = NO;
    return YES;
}

static BOOL PEFocusStateCurrent(const PEFocusAsyncState *state, PEFocusAsyncJob job)
{
    return state->connected && state->harmonyActive &&
        job.session == state->session && job.epoch == state->epoch &&
        job.sequence == state->latestSequence;
}

static BOOL PEFocusCanAcknowledge(BOOL targetFound, BOOL minimized, BOOL frontMatches,
                                 BOOL focusedMatches, BOOL sheetBlocks, BOOL geometryCurrent)
{
    return targetFound && !minimized && frontMatches && focusedMatches &&
        !sheetBlocks && geometryCurrent;
}

static BOOL PEFocusFinalAckAllowed(BOOL priorChecks, int targetPID, int frontPID,
                                   BOOL geometryCurrent, BOOL ownerCurrent, BOOL requestCurrent)
{
    return priorChecks && targetPID>0 && targetPID==frontPID && geometryCurrent &&
        ownerCurrent && requestCurrent;
}

#endif
