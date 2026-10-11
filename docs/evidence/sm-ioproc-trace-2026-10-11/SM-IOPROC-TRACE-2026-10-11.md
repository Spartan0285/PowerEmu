# The SoundManager IOProc trace — result, 11 October 2026

The trace in `docs/AUDIO-CLAUDE-HANDOFF-2026-10-10.md` step 3 has now run
against real Warcraft III audio. Evidence:
`docs/evidence/sm-ioproc-trace-2026-10-11/`.

**This is a measurement, not a fix.** No audio code changed. Nothing here says
playback is repaired.

## What was captured

One owned window (480 s guard), VM staged with the SM IOProc observer plugin,
Warcraft III launched through the NoCD applet on the guest Desktop, driven by
Adam into **Exodus of the Horde, Chapter One** — the Prologue cinematic with
the thunder and voiceovers he described. Config as he runs it: Radeon 9800,
4 CPUs, unmodified.

- publication: `published: true`, control sha256 `e9f50379…`, nonce non-zero,
  published while the owned VM was paused, VM resumed.
- observer: **3,520 records**, `latched: true`, 1.1 MB. Every error counter
  zero — config, guard, word, read, bounds, torn reads, context skips, object
  errors, drops, pair errors, unmatched exits, unfinished.
- `oct10-validate-sm-ioproc.py` → **`valid: true`, `failures: []`**,
  `fixture_mode: false`, 3,520 records.

Buffer is 512 frames (4,096 bytes, 2 ch float32). Window 52.0 s of IOProc
activity. Median call interval **13.744 ms**; p90 18.7; p99 28.7; max **341.6 ms**.
Median service time entry→exit **0.141 ms**, p99 7.35 ms, max 72.5 ms.

## The answer to the question the handoff posed

The handoff asked the trace to distinguish:

> "IOProc service skips while device time advances" **vs** "clean admitted
> buffers disappear inside a regularly-serviced SoundManager path".

**It is the first.** Both behaviours appear, but they are different sizes and
only one loses audio.

### A. Service skips while the device clock runs on — this is the popping

517 events where the device's `sample_time` advanced by more than one buffer
between consecutive IOProc calls. Summed:

> **295,088 frames — 6.69 seconds, 12.9 % of a 52-second window — that the
> device played and the IOProc never wrote.**

Six of those events lost more than 100 ms each; the worst gap was 341.6 ms, in
which the device advanced 15,063 frames while the IOProc was not called once.
That is roughly 25 consecutive missed buffers.

### B. Clock stalls — real, but they do not lose audio

5 events over 60 ms (831 ms total) where the IOProc was late **and** the device
clock did not advance: `sample_time` moved by one buffer or less across a
118–234 ms wall gap. Nothing is skipped here; the whole audio clock pauses and
resumes. This is time-stretching, not a pop, and it is a much smaller effect.

### C. Mechanism: slow service calls cause the skips

84 calls took longer than 5 ms entry→exit (against a 0.141 ms median).
**66 of those 84 immediately precede a device-advanced gap.** So the chain is:
a service call runs long → the next deadline is missed → the device advances
past buffers nobody filled → pop.

This matches what Adam reports by ear after Codex's fixes: audio is much
better, and the residual popping lands on **loud onsets** — thunder, "Next
Objective", voiceover entries. Loud onsets are exactly when the mixer has the
most work to do in one callback, which is when a service call runs long.

### D. One anomaly worth a look

`sample_time` moved **backwards** once, by 168 frames. Once in 3,520 calls, so
it is not the main story, but a device timestamp going backwards should not
happen at all.

Long-run accounting is close to correct: 2,246,021 device frames in 52.04 s =
43,156 Hz effective against a 44,100 Hz nominal rate, i.e. 97.9 % of real time.
The deficit is not a steady drift — it is concentrated in the 517 skip events.

## What this says about the repair

The fault is **not** in SoundManager buffer admission. Buffers that reach the
IOProc are fine: zero drops, zero pair errors, zero unmatched exits, zero torn
reads across 3,520 calls. The loss is that the IOProc is **not called in time**,
and the device consumes unfilled buffers while it waits.

So the repair belongs on the path that gets the IOProc serviced on schedule —
callback scheduling and pacing under load — and not in the admission or
buffer-copy path. The 66-of-84 correlation says the specific thing to attack is
the long tail of service durations: a callback that takes 72 ms in a 13.7 ms
cadence cannot be absorbed.

I am deliberately not proposing the code change here. The measurement is what
was missing; the choice of fix should be made against it.

## Reproducing

`docs/evidence/sm-ioproc-trace-2026-10-11/oct11-trace-drive.py` runs the whole
window: stages the observer, boots, stages the three guest helpers the
collector verifies (it never uploads them, and a fresh boot has an empty
`/tmp`), launches through the NoCD applet, waits for navigation, then runs
prepare and finalize back to back and holds for the recording window.

Navigation into the campaign still needs a human: QEMU-injected clicks move
Warcraft's cursor to the right pixel but the game does not register them as
presses, though Carbon dialogs do obey them.

## Which build this measures — SETTLED

The emulator bundled in the app that was traced was built **10 Oct 15:24**.
`hw/audio/screamer.c` was last modified 10 Oct 08:40 and `audio/coreaudio.m`
9 Oct 22:02, and the committed audio fix `2d76be72d8d audio: preserve DMA
pacing and avoid guest relay process stalls` landed 9 Oct 19:35 — all before
that build.

**So the trace measured a binary that already contained the DMA pacing fix and
the diagnostic scaffolding.** 12.9 % is the figure *after* the pacing work that
Adam confirmed by ear as "much better", not before it. The scaffolding is
default-off and was off for this run, so it is present but not active.

The original uncertainty is retained below for the record.

## Which build this measures — the original open question

At the time of the trace the `poweremu-qemu` working tree had **546 lines of
uncommitted audio changes**: `hw/audio/screamer.c` (+329), `audio/coreaudio.m`
(+115), `hw/intc/openpic.c` (+93), plus `system/cpus.c` and `system/main.c`.
The last committed audio change is `2d76be72d8d audio: preserve DMA pacing and
avoid guest relay process stalls`.

I did not write any of that and I cannot tell from the artifacts whether the
binary that was traced was compiled with those working-tree changes or without
them. **Before these numbers are used to justify a repair, that should be
pinned down** — rebuild from a known tree and re-run the trace if there is any
doubt. The harness makes a repeat run cheap now.

Recording the uncertainty rather than assuming the favourable case: if the
trace measured a tree that already contains an in-progress fix, then 12.9 %
is the figure *after* that fix, not before it.
