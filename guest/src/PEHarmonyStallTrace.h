/*
 * Opt-in, bounded Harmony stall checkpoints.
 *
 * Define one PEHarmonyStallTrace object in the owning translation unit and
 * call StartFromEnvironment once before Harmony work. Enter/Leave are safe to
 * call at hot-path boundaries: when disabled they perform one volatile read
 * and return; when enabled they use only per-lane 32-bit atomics and
 * mach_absolute_time. They allocate no memory, acquire no locks, and do no I/O.
 *
 * A dedicated low-rate watchdog records at most PE_HARMONY_STALL_TRACE_MAX
 * events in memory and emits the same bounded events to stderr. It reports one
 * STALL and at most one RECOVER per observed operation. If the main thread is
 * blocked, the watchdog still runs independently. Stop requires checkpoint
 * callers to have quiesced; Dump is intended after Stop.
 */
#ifndef PE_HARMONY_STALL_TRACE_H
#define PE_HARMONY_STALL_TRACE_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <libkern/OSAtomic.h>

#ifndef PE_HARMONY_STALL_TRACE_MAX
#define PE_HARMONY_STALL_TRACE_MAX 64
#endif
#ifndef PE_HARMONY_STALL_TRACE_INTERVAL_USEC
#define PE_HARMONY_STALL_TRACE_INTERVAL_USEC 250000
#endif
#ifndef PE_HARMONY_STALL_TRACE_THRESHOLD_MS
#define PE_HARMONY_STALL_TRACE_THRESHOLD_MS 500
#endif

typedef enum {
    PE_HARMONY_STALL_MAIN = 0,
    PE_HARMONY_STALL_CAPTURE = 1,
    PE_HARMONY_STALL_LANE_COUNT = 2
} PEHarmonyStallLane;

typedef enum {
    PE_HARMONY_STALL_NONE = 0,
    PE_HARMONY_STALL_MAIN_REPORT_CGS,
    PE_HARMONY_STALL_REPORT_FOCUSED_CGS,
    PE_HARMONY_STALL_MENU_BAR_AX,
    PE_HARMONY_STALL_MINWINDOWS_AX,
    PE_HARMONY_STALL_FOCUS_LOOKUP_AX,
    PE_HARMONY_STALL_FOCUS_RAISE_AX,
    PE_HARMONY_STALL_FOCUS_CONFIRM_AX,
    PE_HARMONY_STALL_CAPTURE_BOUNDS,
    PE_HARMONY_STALL_CAPTURE_COPY,
    PE_HARMONY_STALL_CAPTURE_FLUSH,
    PE_HARMONY_STALL_CAPTURE_SEND
} PEHarmonyStallStage;

typedef enum {
    PE_HARMONY_STALL_EVENT_STALL = 1,
    PE_HARMONY_STALL_EVENT_RECOVER = 2
} PEHarmonyStallEventKind;

typedef struct {
    volatile int32_t version;
    volatile int32_t stage;
    volatile int32_t operationID;
    volatile uint32_t startHi;
    volatile uint32_t startLo;
} PEHarmonyStallLaneState;

typedef struct {
    int32_t kind;
    int32_t lane;
    int32_t stage;
    int32_t operationID;
    double startMS;
    double eventMS;
    double durationMS;
} PEHarmonyStallEvent;

typedef struct {
    PEHarmonyStallLaneState lanes[PE_HARMONY_STALL_LANE_COUNT];
    PEHarmonyStallEvent events[PE_HARMONY_STALL_TRACE_MAX];
    volatile int32_t enabled;
    volatile int32_t stopRequested;
    int32_t workerStarted;
    int32_t eventCount;       /* watchdog-owned; read after Stop */
    int32_t capped;           /* watchdog-owned; read after Stop */
    pthread_t worker;
    mach_timebase_info_data_t timebase;
} PEHarmonyStallTrace;

static inline const char *PEHarmonyStallStageName(int stage)
{
    switch (stage) {
        case PE_HARMONY_STALL_MAIN_REPORT_CGS: return "main-report-cgs";
        case PE_HARMONY_STALL_REPORT_FOCUSED_CGS: return "report-focused-cgs";
        case PE_HARMONY_STALL_MENU_BAR_AX: return "menu-bar-ax";
        case PE_HARMONY_STALL_MINWINDOWS_AX: return "minwindows-ax";
        case PE_HARMONY_STALL_FOCUS_LOOKUP_AX: return "focus-lookup-ax";
        case PE_HARMONY_STALL_FOCUS_RAISE_AX: return "focus-raise-ax";
        case PE_HARMONY_STALL_FOCUS_CONFIRM_AX: return "focus-confirm-ax";
        case PE_HARMONY_STALL_CAPTURE_BOUNDS: return "capture-bounds";
        case PE_HARMONY_STALL_CAPTURE_COPY: return "capture-copy";
        case PE_HARMONY_STALL_CAPTURE_FLUSH: return "capture-flush";
        case PE_HARMONY_STALL_CAPTURE_SEND: return "capture-send";
        default: return "none";
    }
}

static inline uint64_t PEHarmonyStallTicks(const PEHarmonyStallLaneState *lane)
{
    uint32_t hi = lane->startHi;
    uint32_t lo = lane->startLo;
    return ((uint64_t)hi << 32) | (uint64_t)lo;
}

/* One writer per lane. The odd/even version brackets a stable 64-bit timestamp
 * for the watchdog without requiring a 64-bit atomic on 32-bit PowerPC. */
static inline void PEHarmonyStallSet(PEHarmonyStallTrace *trace,
                                    PEHarmonyStallLane lane, int stage, int id)
{
    PEHarmonyStallLaneState *s;
    uint64_t ticks;
    if (!trace || !trace->enabled || lane < 0 || lane >= PE_HARMONY_STALL_LANE_COUNT) return;
    s = &trace->lanes[lane];
    ticks = mach_absolute_time();
    OSAtomicIncrement32Barrier((int32_t *)&s->version); /* odd: update in progress */
    s->stage = stage;
    s->operationID = id;
    s->startHi = (uint32_t)(ticks >> 32);
    s->startLo = (uint32_t)ticks;
    OSAtomicIncrement32Barrier((int32_t *)&s->version); /* even: stable snapshot */
}

static inline void PEHarmonyStallEnter(PEHarmonyStallTrace *trace,
                                      PEHarmonyStallLane lane,
                                      PEHarmonyStallStage stage, int operationID)
{
    PEHarmonyStallSet(trace, lane, (int)stage, operationID);
}

static inline void PEHarmonyStallLeave(PEHarmonyStallTrace *trace,
                                      PEHarmonyStallLane lane)
{
    PEHarmonyStallSet(trace, lane, PE_HARMONY_STALL_NONE, 0);
}

typedef struct {
    int32_t valid, stage, operationID;
    uint64_t startTicks;
} PEHarmonyStallSnapshot;

static inline int PEHarmonyStallReadLane(const PEHarmonyStallLaneState *lane,
                                         PEHarmonyStallSnapshot *out)
{
    int32_t a = OSAtomicAdd32Barrier(0, (int32_t *)&lane->version);
    if (a & 1) return 0;
    out->stage = lane->stage;
    out->operationID = lane->operationID;
    out->startTicks = PEHarmonyStallTicks(lane);
    OSMemoryBarrier();
    if (a != OSAtomicAdd32Barrier(0, (int32_t *)&lane->version)) return 0;
    out->valid = 1;
    return 1;
}

static inline double PEHarmonyStallMS(PEHarmonyStallTrace *trace, uint64_t ticks)
{
    return (double)ticks * (double)trace->timebase.numer /
        (double)trace->timebase.denom / 1000000.0;
}

static inline void PEHarmonyStallAppend(PEHarmonyStallTrace *trace,
                                        PEHarmonyStallEventKind kind, int lane,
                                        int stage, int operationID,
                                        uint64_t start, uint64_t event)
{
    PEHarmonyStallEvent *row;
    double startMS, eventMS, durationMS;
    if (trace->eventCount >= PE_HARMONY_STALL_TRACE_MAX) {
        trace->capped = 1;
        return;
    }
    startMS = PEHarmonyStallMS(trace, start);
    eventMS = PEHarmonyStallMS(trace, event);
    durationMS = PEHarmonyStallMS(trace, event - start);
    row = &trace->events[trace->eventCount++];
    row->kind = (int32_t)kind;
    row->lane = lane;
    row->stage = stage;
    row->operationID = operationID;
    row->startMS = startMS;
    row->eventMS = eventMS;
    row->durationMS = durationMS;
    fprintf(stderr, "PESTALL event=%s lane=%s stage=%s id=%d start_ms=%.3f event_ms=%.3f duration_ms=%.3f\n",
        kind == PE_HARMONY_STALL_EVENT_STALL ? "stall" : "recover",
        lane == PE_HARMONY_STALL_MAIN ? "main" : "capture",
        PEHarmonyStallStageName(stage), operationID, startMS, eventMS, durationMS);
    fflush(stderr);
}

typedef struct {
    int32_t valid, stage, operationID, reported;
    uint64_t startTicks;
} PEHarmonyStallObserved;

static inline void *PEHarmonyStallWatch(void *arg)
{
    PEHarmonyStallTrace *trace = (PEHarmonyStallTrace *)arg;
    PEHarmonyStallObserved old[PE_HARMONY_STALL_LANE_COUNT];
    memset(old, 0, sizeof(old));
    for (;;) {
        int i;
        usleep(PE_HARMONY_STALL_TRACE_INTERVAL_USEC);
        if (trace->stopRequested) break;
        uint64_t now = mach_absolute_time();
        for (i = 0; i < PE_HARMONY_STALL_LANE_COUNT; i++) {
            PEHarmonyStallSnapshot cur;
            PEHarmonyStallObserved *prev = &old[i];
            if (!PEHarmonyStallReadLane(&trace->lanes[i], &cur)) continue;
            if (prev->valid && (cur.stage != prev->stage || cur.operationID != prev->operationID ||
                                cur.startTicks != prev->startTicks)) {
                if (prev->reported) PEHarmonyStallAppend(trace, PE_HARMONY_STALL_EVENT_RECOVER,
                    i, prev->stage, prev->operationID, prev->startTicks, cur.startTicks);
                prev->valid = 0;
            }
            if (cur.stage == PE_HARMONY_STALL_NONE) {
                if (prev->valid && prev->reported) PEHarmonyStallAppend(trace,
                    PE_HARMONY_STALL_EVENT_RECOVER, i, prev->stage, prev->operationID,
                    prev->startTicks, cur.startTicks);
                prev->valid = 0;
                continue;
            }
            if (!prev->valid) {
                prev->valid = 1; prev->stage = cur.stage;
                prev->operationID = cur.operationID; prev->startTicks = cur.startTicks;
                prev->reported = 0;
            }
            if (!prev->reported && PEHarmonyStallMS(trace, now - prev->startTicks) >=
                (double)PE_HARMONY_STALL_TRACE_THRESHOLD_MS) {
                PEHarmonyStallAppend(trace, PE_HARMONY_STALL_EVENT_STALL, i,
                    prev->stage, prev->operationID, prev->startTicks, now);
                prev->reported = 1;
            }
        }
    }
    return NULL;
}

static inline int PEHarmonyStallTraceStartFromEnvironment(PEHarmonyStallTrace *trace)
{
    const char *setting = getenv("PE_HARMONY_STALL_TRACE");
    memset(trace, 0, sizeof(*trace));
    if (!setting || strcmp(setting, "1") != 0) return 0;
    if (mach_timebase_info(&trace->timebase) != KERN_SUCCESS || !trace->timebase.denom) return -1;
    trace->enabled = 1;
    if (pthread_create(&trace->worker, NULL, PEHarmonyStallWatch, trace) != 0) {
        trace->enabled = 0;
        return -1;
    }
    trace->workerStarted = 1;
    return 1;
}

static inline void PEHarmonyStallTraceStop(PEHarmonyStallTrace *trace)
{
    if (!trace || !trace->workerStarted) return;
    trace->enabled = 0;
    trace->stopRequested = 1;
    pthread_join(trace->worker, NULL);
    trace->workerStarted = 0;
}

static inline void PEHarmonyStallTraceDump(PEHarmonyStallTrace *trace, FILE *out)
{
    int i;
    if (!trace || !out) return;
    for (i = 0; i < trace->eventCount; i++) {
        PEHarmonyStallEvent *e = &trace->events[i];
        fprintf(out, "%s lane=%s stage=%s id=%d start_ms=%.3f event_ms=%.3f duration_ms=%.3f\n",
            e->kind == PE_HARMONY_STALL_EVENT_STALL ? "stall" : "recover",
            e->lane == PE_HARMONY_STALL_MAIN ? "main" : "capture",
            PEHarmonyStallStageName(e->stage), e->operationID, e->startMS, e->eventMS, e->durationMS);
    }
    fprintf(out, "events=%d max=%d capped=%d enabled=%d\n", trace->eventCount,
        PE_HARMONY_STALL_TRACE_MAX, trace->capped, trace->enabled);
}

#endif
