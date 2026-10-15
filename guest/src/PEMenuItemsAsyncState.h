/* Bounded, value-only queue for optional asynchronous MENUITEMS reads. */
#ifndef PE_MENU_ITEMS_ASYNC_STATE_H
#define PE_MENU_ITEMS_ASYNC_STATE_H
#include <string.h>

#define PE_MENU_ITEMS_PENDING_MAX 16
#define PE_MENU_ITEMS_PATH_MAX 127

typedef struct {
    int pid;
    unsigned session;
    unsigned epoch;
    unsigned invalidation;
    unsigned token;
    char path[PE_MENU_ITEMS_PATH_MAX + 1];
} PEMenuItemsJob;

typedef struct {
    unsigned invalidation;
    unsigned nextToken;
    unsigned count;
    int foregroundPID;
    unsigned foregroundSession;
    unsigned foregroundEpoch;
    BOOL active;
    PEMenuItemsJob activeJob;
    PEMenuItemsJob pending[PE_MENU_ITEMS_PENDING_MAX];
} PEMenuItemsState;

static BOOL PEMenuItemsStateReady(const PEMenuItemsState *state)
{
    return state->count>0 && !state->active;
}

static void PEMenuItemsStateInit(PEMenuItemsState *state)
{
    memset(state, 0, sizeof(*state));
    state->nextToken = 1;
}

static BOOL PEMenuItemsPathValid(const char *path)
{
    unsigned i, n;
    if (!path) return NO;
    n = (unsigned)strlen(path);
    if (!n || n > PE_MENU_ITEMS_PATH_MAX) return NO;
    for (i=0; i<n; i++) if ((path[i]<'0' || path[i]>'9') && path[i]!='.') return NO;
    return YES;
}

static BOOL PEMenuItemsSameKey(PEMenuItemsJob a, int pid, unsigned session,
                              unsigned epoch, const char *path)
{
    return a.pid==pid && a.session==session && a.epoch==epoch && !strcmp(a.path,path);
}

/* Keep one active operation and at most sixteen distinct pending operations.
 * When full, evict the oldest pending request; opening that menu again can
 * request it anew. The currently executing AX call is never cancelled. */
static BOOL PEMenuItemsStateEnqueue(PEMenuItemsState *state, int pid, const char *path,
                                    unsigned session, unsigned epoch, PEMenuItemsJob *out)
{
    unsigned i;
    PEMenuItemsJob job;
    if (pid<=0 || !PEMenuItemsPathValid(path)) return NO;
    if (state->active && PEMenuItemsSameKey(state->activeJob,pid,session,epoch,path)) return NO;
    for (i=0;i<state->count;i++)
        if (PEMenuItemsSameKey(state->pending[i],pid,session,epoch,path)) return NO;
    if (state->count==PE_MENU_ITEMS_PENDING_MAX) {
        memmove(&state->pending[0],&state->pending[1],sizeof(state->pending[0])*(PE_MENU_ITEMS_PENDING_MAX-1));
        state->count--;
    }
    memset(&job,0,sizeof(job)); job.pid=pid; job.session=session; job.epoch=epoch;
    job.invalidation=state->invalidation; job.token=state->nextToken++;
    strncpy(job.path,path,PE_MENU_ITEMS_PATH_MAX); job.path[PE_MENU_ITEMS_PATH_MAX]=0;
    state->pending[state->count++]=job;
    if (out) *out=job;
    return YES;
}

static BOOL PEMenuItemsStateTake(PEMenuItemsState *state, PEMenuItemsJob *out)
{
    while (state->count && (state->pending[0].pid!=state->foregroundPID ||
           state->pending[0].session!=state->foregroundSession ||
           state->pending[0].epoch!=state->foregroundEpoch)) {
        state->count--;
        if (state->count) memmove(&state->pending[0],&state->pending[1],sizeof(state->pending[0])*state->count);
    }
    if (!state->count || state->active) return NO;
    state->activeJob=state->pending[0]; state->active=YES;
    state->count--;
    if (state->count) memmove(&state->pending[0],&state->pending[1],sizeof(state->pending[0])*state->count);
    if (out) *out=state->activeJob;
    return YES;
}

/* Called by main after its Process Manager front-process snapshot. This
 * removes obsolete queued requests before the serialized AX worker can start
 * them; an already executing Accessibility IPC remains non-cancellable. */
static unsigned PEMenuItemsStateSetForeground(PEMenuItemsState *state, int pid,
                                               unsigned session, unsigned epoch)
{
    unsigned i, kept=0, before=state->count;
    state->foregroundPID=pid; state->foregroundSession=session; state->foregroundEpoch=epoch;
    for (i=0;i<state->count;i++) {
        PEMenuItemsJob job=state->pending[i];
        if (job.pid==pid && job.session==session && job.epoch==epoch)
            state->pending[kept++]=job;
    }
    state->count=kept;
    return before-kept;
}

static BOOL PEMenuItemsStateCurrent(const PEMenuItemsState *state, PEMenuItemsJob job)
{
    return state->active && state->invalidation==job.invalidation &&
        state->activeJob.token==job.token && state->activeJob.pid==job.pid &&
        state->activeJob.session==job.session && state->activeJob.epoch==job.epoch &&
        !strcmp(state->activeJob.path,job.path);
}

static BOOL PEMenuItemsStateCanPublish(const PEMenuItemsState *state, PEMenuItemsJob job,
                                      BOOL connected, BOOL harmonyActive,
                                      unsigned session, unsigned epoch, int frontPID)
{
    return PEMenuItemsStateCurrent(state,job) && connected && harmonyActive &&
        session==job.session && epoch==job.epoch && frontPID==job.pid;
}

static void PEMenuItemsStateFinish(PEMenuItemsState *state, PEMenuItemsJob job)
{
    if (PEMenuItemsStateCurrent(state,job)) state->active=NO;
}

static void PEMenuItemsStateInvalidate(PEMenuItemsState *state)
{
    state->invalidation++; state->count=0; state->active=NO;
    state->foregroundPID=0; state->foregroundSession=0; state->foregroundEpoch=0;
}

#endif
