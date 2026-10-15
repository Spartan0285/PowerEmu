/* Small deterministic test for PEHarmonyStallTrace. */
#define PE_HARMONY_STALL_TRACE_MAX 4
#define PE_HARMONY_STALL_TRACE_INTERVAL_USEC 5000
#define PE_HARMONY_STALL_TRACE_THRESHOLD_MS 10
#include "../src/PEHarmonyStallTrace.h"

static PEHarmonyStallTrace trace;

static void hold(PEHarmonyStallLane lane, PEHarmonyStallStage stage, int id,
                 unsigned usec)
{
    PEHarmonyStallEnter(&trace, lane, stage, id);
    usleep(usec);
    PEHarmonyStallLeave(&trace, lane);
    usleep(PE_HARMONY_STALL_TRACE_INTERVAL_USEC * 3);
}

int main(void)
{
    int started;
    unsetenv("PE_HARMONY_STALL_TRACE");
    started = PEHarmonyStallTraceStartFromEnvironment(&trace);
    if (started != 0 || trace.workerStarted || trace.eventCount != 0) return 1;
    PEHarmonyStallEnter(&trace, PE_HARMONY_STALL_MAIN, PE_HARMONY_STALL_MAIN_REPORT_CGS, 10);
    usleep(50000);
    PEHarmonyStallLeave(&trace, PE_HARMONY_STALL_MAIN);
    if (trace.eventCount != 0) return 2;

    setenv("PE_HARMONY_STALL_TRACE", "1", 1);
    started = PEHarmonyStallTraceStartFromEnvironment(&trace);
    if (started != 1 || !trace.workerStarted) return 3;
    /* Long hold proves one stall row, no repeated periodic rows, and one
     * recovery row when the main-thread checkpoint leaves. */
    hold(PE_HARMONY_STALL_MAIN, PE_HARMONY_STALL_MENU_BAR_AX, 101, 70000);
    if (trace.eventCount != 2 || trace.events[0].kind != PE_HARMONY_STALL_EVENT_STALL ||
        trace.events[1].kind != PE_HARMONY_STALL_EVENT_RECOVER || trace.events[0].operationID != 101 ||
        trace.events[1].operationID != 101) return 4;
    /* The test build lowers the ring capacity to four. Two more distinct
     * stalls must fill it exactly and mark overflow without growing storage. */
    hold(PE_HARMONY_STALL_CAPTURE, PE_HARMONY_STALL_CAPTURE_COPY, 202, 70000);
    hold(PE_HARMONY_STALL_CAPTURE, PE_HARMONY_STALL_CAPTURE_FLUSH, 203, 70000);
    PEHarmonyStallTraceStop(&trace);
    if (trace.eventCount != PE_HARMONY_STALL_TRACE_MAX || !trace.capped || trace.workerStarted) return 5;
    PEHarmonyStallTraceDump(&trace, stdout);
    printf("fixture=PASS disabled=PASS single-stall-recovery=PASS bounded-cap=PASS\n");
    return 0;
}
