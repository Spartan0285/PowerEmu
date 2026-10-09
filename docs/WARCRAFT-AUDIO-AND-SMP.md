# Warcraft III audio and the CPU count — 6 October 2026

Latest clock-service fix, command-reader optimization, live captures and packaged test-build status: [October 6 clock fix handoff](WARCRAFT-CLOCK-FIX-HANDOFF-2026-10-06.md).

## Investigation update — verified controls

Latest native matched tests now include both cards at four CPUs and repeated 9800 one/two-CPU captures. Two CPUs remained variable; one CPU was more consistent with lower FPS. A two-CPU load crashed in Miles, but the retry loaded and quit cleanly. No complete audio fix is established. See the final two-CPU section and concrete continuation in the [clock-fix handoff](WARCRAFT-CLOCK-FIX-HANDOFF-2026-10-06.md).

The CPU-count observation is useful and reproduced in controlled tone captures, but the explanation below remains a hypothesis. Newly verified 1- and 4-active-CPU guests use the app's actual firmware and CPU startup properties. One CPU has zero low tone windows in interior seconds 5–45; four CPUs has 0–2.4%. Both have **zero catchup-discarded** throughout their tone logs. Polling overshoot is generally sub-ms; shared emulation/graphics lock waits reach ~13–14 ms. Do not infer whole-host saturation from a process using 400% CPU.

`catchup-discarded` measures dropped pacing budget, not a directly observed count of destroyed PCM samples. Burst delivery may matter independently of that cap. The existing macOS nanosecond polling fix is already in this build. Host callback shortages remain with both CPU counts, so pre-host audio gaps and CoreAudio starvation must be measured separately.

Those CPU controls use a standalone display capture frontend. A subsequent native app four-CPU test reached 33.23 FPS and exposed 77–91 ms active-tone pacing stalls, including an 89ms shared-lock wait; these crossed the 50 ms cap. This confirms that lost pacing budget can occur in the native path, while the responsible lock holder and complete audible cause remain unrooted. One CPU remains the best observed workaround. Full findings and continuation status: [October 6 performance handoff](RADEON-9800-PERFORMANCE-HANDOFF-2026-10-06.md). Preserve the original hypothesis below as context, not a confirmed diagnosis.

A user observation, the mechanism behind it, and the September history that
explains both. Written for whoever continues the CoreAudio work.

## The observation

> Tested audio on the latest build with **1 CPU** and it was significantly
> better, like 95% perfect — some minor pops and distortion, but similar to the
> original working 9200 audio. The audio issues are definitely related to the
> number of CPUs.

That is the most useful audio datapoint we have, and it is not in any of the
existing checkpoints.

## Why it is true — the pacer assumes a punctual timer

`hw/audio/screamer.c` paces DMA from a **1 ms `QEMU_CLOCK_VIRTUAL` timer** and
converts *elapsed* time into frames on each callback:

```c
#define SCREAMER_PACE_NS (1 * SCALE_MS)

static void screamer_pace_cb(void *opaque)
{
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    s->pace_frac += (now - s->pace_last) * (int64_t)s->rate;
    s->pace_last = now;
    int64_t due = s->pace_frac / NANOSECONDS_PER_SECOND;
    ...
    if (due > (int64_t)s->rate / 20) {
        sdbg.pace_discarded += due - (int64_t)s->rate / 20;
    }
    due = MIN(due, (int64_t)s->rate / 20);   /* at most 50 ms after a stall */
```

The design is correct **only while that timer is roughly punctual.** When it is
late, two separate things go wrong:

1. **Frames move in a burst instead of at a steady rate.** This is precisely
   the failure the pacer was written to cure (see the history below). The guest
   clocks its audio off playback progress, so a bursty feed makes its clock
   drift — gaps, and writes over audio that has not played yet. Pops.
2. **Backlog beyond 50 ms is discarded outright.** `sdbg.pace_discarded` is
   not a warning counter, it is *thrown-away audio*.

With one vCPU the host keeps up and the timer fires on time. With four vCPUs
under MTTCG the host is saturated — QEMU was measured at **~400% CPU** during
Warcraft's load — and timer delivery jitters badly.

### The smoking gun is already in the existing measurements

The 6 October checkpoint records *"timer max usually 24 ms"* and *"full file
max 166 ms"*. Those are readings of `sdbg.pace_max_ns`. **The target is 1 ms.**
A 24 ms maximum is a 24x overshoot; 166 ms is 166x, and well past the 50 ms
point where audio starts being discarded.

The numbers to prove it were already being collected; what was missing was the
1 ms baseline to compare them against.

## How to quantify it

`SCREAMER_DEBUG=1` prints per second:

```
screamer: pulled N written N underruns N dma-silent-runs N (N frames) queued N
screamer: timer-max-us N catchup-discarded N ring-overflow N frames
```

`timer-max-us` against a 1000 us target, and `catchup-discarded` as the count
of frames destroyed. Run the same scene at **1, 2 and 4 CPUs** and compare. If
the hypothesis holds, `timer-max-us` and `catchup-discarded` both climb with
CPU count, and they track the audible quality.

This turns an ear test into three numbers.

## Two cautions

- **The predictor is host load, not CPU count as such.** Four CPUs on an idle
  host may be fine; one CPU during a heavy battle may still pop. Test against
  load, and do not "fix" this by capping CPUs without measuring.
- **This does not explain the Miles/SoundManager crash.** That is a guest-side
  crash on thread 7 inside `SS_merge` -> `SS_stream_to_buffer`, seen on both
  cards. Treat it as a separate problem; a pacing fault would not take an
  invalid address in the guest's mixer.

## September history — this problem was solved once already

The Warcraft III audio work lives in the **`QEMU-Project`** sessions, not the
PB-Firmware ones. The large one is `95480f2f-31f7-4a5b-b5b2-fceac18512f3`
(18-28 September, 257 MB, ~1,866 Warcraft and ~3,582 audio references).

The fix is `562df896c97`:

> **hw/audio/screamer: pace DMA in real time; report position from DMA progress**
>
> A 1 ms virtual-clock timer pulls TX DMA into a ring at the sample rate,
> `FRAME_CNT_REG` (polled by Apple02Audio) advances with DMA, and a 40 ms
> jitter buffer fronts the audio backend. Fixes crackling and dropouts under
> load.

The diagnosis recorded at the time, which is the part that transfers:

> **What caused the distortion:** the emulated sound chip moved audio along in
> bursts timed by your Mac's audio buffers, instead of at the steady rate real
> hardware plays at. Tiger's audio system times itself off that playback, so
> its clock drifted: it left gaps and occasionally wrote over audio before it
> was played.
>
> **The fix:** the emulated chip now plays at exactly 44.1 kHz, with a 40 ms
> safety buffer in front of your speakers.
>
> **How I tested it:** I recorded the guest's output while it played a 1 kHz
> tone. Before, there were 10-20 dropouts every 4 seconds; now there are none,
> in four runs in a row.

**The principle: the guest must drive the clock, not the host.** The current
CoreAudio work (consuming valid partial data, padding the missing tail) is
operating at the other end of the same pipe. If the pacer upstream is bursting
and discarding, no amount of care in the backend callback will recover it.

The 1 kHz tone recording with dropout counting is the same method the current
work uses ("settled tone windows", "% low 10 ms windows") — so the measurement
track is right; it is the upstream cause that is new.

### Related commits worth reading

| Commit | Why |
|---|---|
| `562df896c97` | the pacer itself — start here |
| `3a5e5e469e3` | don't stall TX DMA with no host voice |
| `bc617b03c25` | voices of several instances share one device |
| `57502abdd7c` | coreaudio: trace output starvation at the device callback |
| `d36be40d7f5` / `0e6a5d9305c` | "stop taking part in mixing while there is nothing to play", **and its revert** — a tried-and-rejected approach, which is useful signal |
| `428ca1a7e65` | complete descriptors at their own time, behind the clock |
| `f663ad59c09` | advance by what the backend accepted, not what we offered |
| `fe4779b1130` | `util/qemu-timer`: wake `qemu_poll_ns` on time on macOS — directly about timer punctuality |

That last one is worth special attention given the diagnosis above: macOS was
rounding sub-millisecond waits up, measured at ~514 us late before the fix and
~14 us after. A pacer on a 1 ms period is exactly the client that suffers from
that, and it is worth confirming the fix is present and effective in the
configuration being tested.
