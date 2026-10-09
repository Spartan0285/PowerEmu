# Audio continuity: October 7, 2026

> Live status and next steps are superseded by [October 8 findings](AUDIO-PACING-FIX-2026-10-08.md), including the confirmed pacing/recovery fixes, callback lifecycle/period fixes, actual PCM evidence, and the later host callback suppression.

## User observations and direction

User confirms Final Cut video playback, and Chess / Warcraft render properly after fragment fixes. Audio remains poppy in Warcraft and at Chess speech onset. Graphics regression is not currently observed. Final Cut's purple strip appears only at the last frame according to the user and may be an end-of-media indication; do not mask it or classify it as confirmed corruption.

Research about dynamic rate control is relevant to slow clock drift, but does not establish the cause of these pops. Source: https://archive.ares-emu.net/near.sh/articles/audio/dynamic-rate-control.html . Apple already provides the native HAL IOProc used here: https://developer.apple.com/documentation/coreaudio/audiodeviceioproc?language=objc . Changing to AudioQueue/AudioUnit or minimizing period size is not the first step. Existing 1 ms feed experiment was worse than default 10 ms. Keep guest DMA/sample count on virtual hardware time; do not make host callback execute guest code or own BQL.

## Concrete experiment implemented

Repository `/Users/adam/Developer/poweremu-qemu`, `audio/coreaudio.m`:

- Opt-in `POWEREMU_COREAUDIO_SPSC=1`, unset/0 keeps existing mutex path. No production audio default changed.
- Single producer under BQL; device callback is sole consumer. Separate monotonic byte cursors, release publication after PCM copy / consumption, acquire observation before accessing PCM / free space.
- CoreAudio output no longer acquires a mutex, logs, allocates, accesses guest memory, or enters BQL in the experimental path. Input remains unchanged.
- Existing generic buffer storage / size retained. No change to guest clock, DMA descriptors, mixing, 40 ms Screamer prime, hardware period, or host feed interval.
- Actual callback `mDataByteSize` determines frame count rather than cached period. Empty / partial tails zero-filled, valid frames consumed in order. Disabled storage and obsolete-device callbacks cannot consume queued data.
- Output ring resets only in initialization after old device stop/destruction; device changes and stop/restart need live validation.
- Main-thread debug snapshots use atomic counters and report queued/capacity frames. `SCREAMER_DEBUG=1` enables diagnostics. Queue snapshots are once per second, not per-callback occupancy history.

## Verified and NOT verified

Backend build passed. Fixture `tests/poweremu/coreaudio-output-test.py` extracts production producer/callback functions. Existing legacy full/partial/empty/wrapped stereo tests pass, including the saved baseline source `/tmp/pe-fcp/coreaudio-before-spsc.m`. New concurrent test passes 200,000 ordered stereo frames with mismatched producer/consumer chunks, variable callback sizes, ring wrap, guard bytes, empty tails, retained data, obsolete devices, and disabled buffers. Both ASan/UBSan and ThreadSanitizer pass. Callback lock stub asserts if the SPSC path tries to acquire it.

No live speaker A/B has been completed. Do not claim reduced popping, drift repair, or fixed Warcraft Miles crashes. Current running FCP app still contains the earlier backend and uses legacy output; this source build does not replace a running emulator. New app not packaged or launched in this round. Preserve all pre-existing audio/SMP/GPU edits; no commit made.

## Next, in order

1. Package a separate signed candidate. Launch it with `POWEREMU_COREAUDIO_SPSC=1` and `SCREAMER_DEBUG=1`; VMRunner inherits host app environment into QEMU. Restart the VM between mode changes. Unset SPSC for same-binary baseline. Never use two writable emulators on the same disk. Do not alter shipping defaults before validation.
2. Match four active CPUs, card, resolution and scene. Record host speaker output as well as pre-CoreAudio WAV, along with timer/BQL/GPU/exact-zero counters. Pre-host WAV cannot validate this backend change. Include short repeated Chess speech, Warcraft soundtrack, movement, and clean quit. Use output loopback only if already available/authorized; do not invent an audible improvement from buffer counters.
3. Exercise host output-device changes, pause/resume, guest audio idle-to-speech and two VMs; verify no deadlock, stale samples or new errors. CoreAudio lifecycle retains existing stop/destroy assumptions, which need actual device tests.
4. Separate gradual occupancy slope (clock drift) from sharp depletion (late guest production/BQL dispatch). Earlier evidence includes exact stereo-zero frames already in guest DMA and worst BQL waits overlapping GPU ring processing. A host FIFO cannot repair that data.
5. If slow drift remains, implement bounded, slowly slewed adaptive resampling on host float PCM, driven by occupancy. Maintain stereo phase/history across callbacks and resets. Test known +/- clock mismatch, latency bound, pitch error, and no periodic sample drops; keep emulated clock/frame count unchanged. No adaptive resampler implemented yet.
6. If onset pops persist without shortages, inspect the actual first/last samples for discontinuities or codec gating. Add a short ramp only after determining the faulty transition; do not mute the start of legitimate speech to hide it.
7. Continue shortening GPU BQL batches without relaxing serialization, and correlate descriptor IRQ / frame count / guest audio producer timing on SMP. Prior unlocked GPU experiment corrupted surfaces; do not restore it.

## Commands

```sh
cd /Users/adam/Developer/poweremu-qemu
python3 tests/poweremu/coreaudio-output-test.py
python3 tests/poweremu/coreaudio-output-test.py --sanitizer thread
ninja -C build-r350 qemu-system-ppc64
```

Previous controls and rejected experiments: `WARCRAFT-CLOCK-FIX-HANDOFF-2026-10-06.md`, `WARCRAFT-AUDIO-AND-SMP.md` in this docs directory.
