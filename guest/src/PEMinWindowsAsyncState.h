/* Bounded value-only state for the optional asynchronous MINWINDOWS scan. */
#ifndef PE_MIN_WINDOWS_ASYNC_STATE_H
#define PE_MIN_WINDOWS_ASYNC_STATE_H

#include <string.h>

#define PE_MIN_WINDOWS_PID_MAX 256

typedef struct {
    unsigned generation;
    unsigned sequence;
    unsigned session;
    unsigned epoch;
    unsigned count;
    int pids[PE_MIN_WINDOWS_PID_MAX];
} PEMinWindowsJob;

typedef struct {
    unsigned generation;
    unsigned nextSequence;
    unsigned latestSequence;
    unsigned droppedPending;
    BOOL connected;
    BOOL harmonyActive;
    unsigned session;
    unsigned epoch;
    BOOL active;
    BOOL hasPending;
    PEMinWindowsJob activeJob;
    PEMinWindowsJob pendingJob;
} PEMinWindowsState;

static void PEMinWindowsStateInit(PEMinWindowsState *state)
{
    memset(state, 0, sizeof(*state));
    state->nextSequence = 1;
}

static BOOL PEMinWindowsJobSameSnapshot(const PEMinWindowsJob *a,
                                        const PEMinWindowsJob *b)
{
    return a->session == b->session && a->epoch == b->epoch &&
        a->count == b->count &&
        !memcmp(a->pids, b->pids, sizeof(int) * a->count);
}

/* Called by main at connect/disconnect and every Harmony transition, including
 * repeated HARMONY-on reconciliation. A running AX IPC cannot be cancelled;
 * generation invalidation prevents its result or remaining process scans. */
static void PEMinWindowsStateSetContext(PEMinWindowsState *state, BOOL connected,
                                        BOOL harmonyActive, unsigned session,
                                        unsigned epoch)
{
    if (state->connected != connected || state->harmonyActive != harmonyActive ||
        state->session != session || state->epoch != epoch) {
        state->generation++;
        if (state->hasPending && state->droppedPending != 0xffffffffU) state->droppedPending++;
        state->hasPending = NO;
        state->latestSequence = 0;
    }
    state->connected = connected;
    state->harmonyActive = harmonyActive;
    state->session = session;
    state->epoch = epoch;
}

static void PEMinWindowsStateInvalidate(PEMinWindowsState *state)
{
    state->generation++;
    state->latestSequence = 0;
    if (state->hasPending) state->droppedPending++;
    state->hasPending = NO;
}

static BOOL PEMinWindowsStateReady(const PEMinWindowsState *state)
{
    return state->hasPending && !state->active;
}

/* One active scan plus one replaceable snapshot; repeated identical snapshots
 * do not invalidate useful in-flight work. The caller owns synchronization. */
static BOOL PEMinWindowsStateEnqueue(PEMinWindowsState *state, const int *pids,
                                     unsigned count, unsigned session,
                                     unsigned epoch, PEMinWindowsJob *out)
{
    PEMinWindowsJob job;
    unsigned i, kept = 0;
    if (!state->connected || !state->harmonyActive || !pids || count > PE_MIN_WINDOWS_PID_MAX ||
        session != state->session || epoch != state->epoch) return NO;
    memset(&job, 0, sizeof(job));
    job.generation = state->generation;
    job.session = session;
    job.epoch = epoch;
    for (i = 0; i < count; i++) if (pids[i] > 0) job.pids[kept++] = pids[i];
    job.count = kept;
    if (state->active && !state->hasPending && state->activeJob.generation == job.generation &&
        PEMinWindowsJobSameSnapshot(&state->activeJob, &job)) return NO;
    if (state->hasPending && PEMinWindowsJobSameSnapshot(&state->pendingJob, &job)) return NO;

    job.sequence = state->nextSequence++;
    if (!state->nextSequence) state->nextSequence = 1;
    state->latestSequence = job.sequence;
    if (state->hasPending) state->droppedPending++;
    state->pendingJob = job;
    state->hasPending = YES;
    if (out) *out = job;
    return YES;
}

static BOOL PEMinWindowsStateTake(PEMinWindowsState *state, PEMinWindowsJob *out)
{
    if (!PEMinWindowsStateReady(state)) return NO;
    state->activeJob = state->pendingJob;
    state->hasPending = NO;
    state->active = YES;
    if (out) *out = state->activeJob;
    return YES;
}

/* OwnsActive is separate from CanContinue: a replaced/invalidated job must
 * stop between process IPCs, but still must finish its active slot on return. */
static BOOL PEMinWindowsStateOwnsActive(const PEMinWindowsState *state,
                                        PEMinWindowsJob job)
{
    return state->active && state->activeJob.generation == job.generation &&
        state->activeJob.sequence == job.sequence;
}

static BOOL PEMinWindowsStateCanContinue(const PEMinWindowsState *state,
                                         PEMinWindowsJob job)
{
    return PEMinWindowsStateOwnsActive(state, job) &&
        state->latestSequence == job.sequence && state->connected && state->harmonyActive &&
        state->session == job.session && state->epoch == job.epoch;
}

static BOOL PEMinWindowsStateCanPublish(const PEMinWindowsState *state,
                                        PEMinWindowsJob job, BOOL connected,
                                        BOOL harmonyActive, unsigned session,
                                        unsigned epoch)
{
    return PEMinWindowsStateCanContinue(state, job) && connected && harmonyActive &&
        session == job.session && epoch == job.epoch;
}

static void PEMinWindowsStateFinish(PEMinWindowsState *state, PEMinWindowsJob job)
{
    if (PEMinWindowsStateOwnsActive(state, job)) state->active = NO;
}

#endif
