# Radeon 9800 performance and audio continuation

Latest clock-service finding, implemented fix and pending live validation: [October 6 clock fix handoff](WARCRAFT-CLOCK-FIX-HANDOFF-2026-10-06.md).

Updated 6 October 2026. Experimental work; no commit or release performed.

## Correction after the user’s app test — 6 October 2026

The user reports severe Warcraft pops, distortion and slowdowns on the latest 9800 app. **Audio is not fixed, and synthetic tone results do not validate Warcraft music.** Do not present the latest build as an audio success.

A concrete harness mismatch was found: `/tmp/pe9800/fw/openbios-ppc` SHA-256 is `ef674543f363cf36c06ccf4580682d9f3fce98274ef72e575b314176ec469705`, while the signed app firmware is `78f0c13288f19cb1438548e206edaa8371691f25d37f7c111f63d17935211aed`. The standalone launcher also omits VMRunner’s secondary CPU GPIO/reset/timebase startup properties. `-smp 4` requested four virtual CPUs, but actual guest online CPU count was not verified. **Earlier measurements must be labeled standalone requested-four-CPU results, not a validated matched four-active-CPU app comparison.** Native pixel/callback tests remain valid; FPS and tone results describe those standalone runs only.

The user’s latest Tiger log records the full app launch including secondary-CPU properties, bundled firmware, 1680×1050, four requested CPUs, 256 MB VRAM and CoreAudio. No guest process was running at inspection time; PowerEmu UI remained open. No user process was interrupted or disk modified by inspection.

Next priority: reproduce with the exact app firmware and boot-command on a disposable overlay, verify online CPUs and running threads inside Tiger, then capture **Warcraft music** plus aligned guest DMA/mixer/host output timing. Compare both cards under that configuration. Trace shared timebase/interrupt/SMP audio behavior as a hypothesis, not an established cause. Do not reduce CPUs as a claimed fix, and do not infer physical speaker quality from the pre-CoreAudio tone recording. Keep the app test path and standalone control demonstrably equivalent before claiming audio improvement.

## Current state

The signed `build/PowerEmu 9800 Test.app` contains the PM4 row-fill optimization, preceding shader/submission improvements, the CoreAudio partial-period playback fix and opt-in diagnostics. Packaging and deep/strict signature verification pass. Public 9200-only app unchanged; both cards remain selectable in this experimental app. Shut the guest down before changing cards.

Latest standalone Warcraft scene (app/SMP equivalence unverified): **9200 34.11 FPS; 9800 34.79 FPS**. Both pass loaded-map movement and clean quit with the original crash report unchanged. All owned QEMU test guests are stopped. Original user disks unchanged.

Audio remains incomplete: host playback now emits valid partial data and zero-pads only missing tails; total missing playback time has not measurably improved. Settled pre-host tone captures remain 1.4–4.4% low windows on 9200 and 0–1.2% on 9800. An initial 9200 transient is preserved as unresolved. No evidence that guest DMA budget is being lost. Need aligned clock/waveform tracing next.

Chess gray background, selection lighting, e2–e4 and computer response pass in the row-fill build. Thin desktop/Finder marks persist. The earlier intermittent Miles crash remains unrooted. No release-readiness or corruption-free claim.

## Sources and implemented changes

QEMU: `/Users/adam/Developer/poweremu-qemu`, branch `release-0.3.3-rc`, dirty shared checkout. App: `/Users/adam/Developer/PowerEmu`. Preserve all unrelated edits.

- Cache validated shader variants and sampler state; constants/addresses/textures remain fresh.
- Stage immutable vertices/constants in the shared command-buffer arena.
- Reuse compatible R350 render passes and avoid empty texture uploads. End passes on attachment changes, CPU access, depth export, flush and backend transitions.
- Shared `gpu_submit_buffer_for()` owns encoder handoffs between R200/R300.
- Order eligible local texture reads on the GPU while preserving CPU waits and the compositor's original `window_bypass` ordering.
- Track read-before-overwrite hazards with a bounded **1024-entry** table. The earlier 64-entry version regressed severely and must not ship.
- Normalize fog uniform values in shader/validation cache keys; retain per-draw finite-value checks. Host constants 32/33 carry fog without changing the 32 guest constants.
- Route PM4 `CNTL_PAINT_MULTI` through existing `fill_rect_fast()` for eligible 32-bit surfaces. Preserve access synchronization, clipping, endian handling, dirty/depth notification and MC-aware/non-32-bit fallback.
- CoreAudio consumes valid partial periods and zero-pads the missing tail instead of withholding the whole period. Additional opt-in counters distinguish guest DMA pacing, priming and host callback shortages. No guest pacing change, sample-format workaround, muting, CPU reduction or game binary patch.

A disjoint GPU-copy experiment passed native tests but executed zero copies in Warcraft menu/loading. It was completely removed from production/test source; do not enable `PPCGPU_GPU_BLIT` or claim a shipped Metal-copy improvement.

## Matched results

Static Chapter One opening after Esc/F1; 1680×1050, four requested CPUs (online count unverified), 2 GB RAM, 256 MB VRAM, CoreAudio; about 30 seconds per interval. Standalone emulator FPS does not guarantee displayed app FPS.

| Build/card | Presented FPS | Controlled tone low-amplitude 10 ms windows |
| --- | ---: | --- |
| Original 9800 | 13.90 | Frequent interruptions |
| Shader/resource cache 9800 | 19.80 | Improved |
| Render-pass reuse 9800 | 25.76 | Improved |
| GPU-only texture ordering 9800 | 33.73 | Rare stalls remain |
| 64-entry read guard 9800 | 21.33 | Regression; discarded |
| Final compositor/cache 9800 | 33.96 | 0–1.8% |
| Final compositor/cache 9200 valid retry | 31.80 | 2.2–5.4% |
| Oct 4 build-smp 9200 reference | 34.75 | 4.0–9.4% |
| Row fill 9200 | 33.74 | 2.0–5.2% |
| Row fill 9800 | 33.49 | 0–2.0% |

Row fill shows a modest first matched 9200 speed gain and maintains 9800 speed; it has not demonstrated an audio fix. The older reference differs in multiple source changes, so FPS differences cannot be attributed to one change. Its red unit/control surfaces match the latest 9200 screenshot and predate this batch.

Tone: precomputed 45-second 1 kHz stereo Sound Manager playback; inspect interior seconds 5–45 only. Idle amplitude ~1379; active row-fill medians ~1370–1380. Captures include inactive tails. HMP WAV capture precedes CoreAudio playback and cannot prove the speakers are clean. Do not infer quality from raw music RMS. Builds/native tests/profiling did not overlap valid rate/tone intervals.

## Validation and open issues

Native GPU checks passed for shader translation, byte order, fog, depth/stencil, immutable constants, framebuffer-fetch blending, encoder ownership and both alias dependency directions. Final QEMU builds; bootless PM4 tests pass clipped 32-bit fill/padding and 16-bit fallback on both cards. R350 CP reset tests pass; R200 only runs relevant fill tests because CP-disable semantics differ. Repository diff checks pass.

Latest Warcraft tests on both cards survive map load/movement/clean quit, with unchanged original crash reports. An intermittent earlier Miles audio crash at `0x0105118c` occurred on both cards and remains unrooted; surviving bounded tests does not prove a fix. Failed desktop/idle measurements were excluded.

Thin desktop/Finder marks persist on both cards, including after Chess movement. Investigate cursor save-under, pitch/target bounds and aliased 2D copies. Do not claim corruption-free rendering. The per-frame unsupported texture-unit rejection existed in preceding fast builds and did not newly rise in row fill; do not claim full R350 ISA support.

## Next steps

1. Use opt-in audio counters with controlled tone under Warcraft load to distinguish guest DMA silence, lost pacing budget, ring underflow and host callback starvation.
2. Keep matched card/configuration and verify the game is alive before/after measurements. Announce card switches and tone playback; the user hears tests.
3. Change audio behavior only after identifying a mechanism. Preserve guest hardware clock, full-duplex timing and audio lifecycle.
4. Retest any behavior fix on both cards and repack/sign the experimental app. No parallel profiling/builds during measurements.
5. Trace the desktop marks separately, with saved screenshots as reproduction evidence.

## Test harness and evidence

`/tmp/pe9800/app-qmp-game-control.sh` uses disposable overlays and supports `PE_QEMU` for the older reference. Unique tags; `PE_HOLD=1`; QMP 4955/HMP 4953/SSH 2309 for current tests. Helpers: `qmp-hmp.py`, `qmp-perf-rate.py`, `guest-ssh.py`, `analyze-tone.py`; guest `/tmp/pe-guest-click` and `/tmp/pe-audio-tone`. Stop only owned guest processes through QMP.

Evidence: `docs/evidence/r350-performance-2026-10-06/`. Full recordings/logs stay in `/tmp/pe9800`. Earlier chronology: `docs/RADEON-9800-MODEL-HANDOFF-2026-10-05.md`.

## Constraints

R350 GPU state/submission remains serialized under BQL. Unlocking previously caused SMP corruption; the R200 async snapshot/worker route is unsafe for R350. Preserve bounds, depth/stencil, texture validation and CPU/GPU barriers. No original VM disk writes, global process kills, public bundle replacement or release authorization implied by testing.

## Audio continuation: partial CoreAudio periods

The new 9200 controlled tone has 2.4–5.2% low interior windows. First 45 diagnostic intervals report no TX budget loss, empty descriptor ticks or priming waits, but CoreAudio has 25 short callbacks out of 3898, short by 2930 frames total. The original callback withholds the entire 512-frame period for even a tiny deficit and does not explicitly initialize that output. This is a separate host playback issue; it cannot explain every pre-CoreAudio capture gap.

Source now consumes valid pending PCM in order and explicitly zero-pads only the missing tail. Native `tests/poweremu/coreaudio-output-test.py` extracts the actual callback/ring helper and tests full/partial/empty/wrapped stereo, retained tail, exact byte order, bounds and counters with ASan/UBSan. It passes; the restored pre-fix callback fails the partial output test. QEMU rebuild passes. Live 9200 test `codex-wc9200-audiopartial-oct06` is starting; signed app still contains row-fill build without this audio behavior change. Follow through on live tests and repackage.

Latest 9200 partial-period check: 34.11 FPS, movement/clean quit, original crash report unchanged. First tone has a large initial interruption (5–10 s median 572, 25.8% low); retain it as an unresolved transient, not a clean success. Settled retry has medians 1342–1375 and 1.4–4.4% low windows, comparable to prior range. Its first 45 CoreAudio intervals have 3900 callbacks, 126 partial periods and 12,597 padded frames; the baseline withheld 25 whole 512-frame periods (~12,800 frames). **Total missing host playback time has not measurably improved.** The change bounds each shortage to its actual tail and explicitly initializes output; do not claim it fixes audio or clock drift. DMA counters still show no discarded pacing budget, descriptor starvation, priming wait or ring underrun.

Experimental app has now been repackaged with the partial-period fix and opt-in diagnostics; deep/strict signature passes and the bundled emulator contains the new CoreAudio counters. Public app unchanged. Fresh 9800 overlay `codex-wc9800-audiopartial-oct06`, launcher session 69361, is booting on QMP4955/SSH2309/HMP4953. Finish live check before reporting this batch complete. Next audio investigation needs aligned virtual/wall-clock/frame endpoints, guest DMA waveform versus post-mix capture, and game audio lifecycle/SMP crash tracing; existing per-second counters are not exactly aligned and cannot establish clock drift.

## Final 9800 audio-batch check

34.79 FPS (1044 frames, 582,641 draws / 30.005 s). Controlled tone medians 1377–1380; 0–1.2% low interior windows. First 45 approximate host intervals: 3899 callbacks, 148 partial periods, 10,487 padded frames; guest counters zero pacing-budget loss, empty descriptors, priming waits and ring underruns. Movement and clean quit pass; crash report remains 66,446 bytes / Oct 5 21:54. Test guest stopped. Signed app already contains this exact source; no functional changes after packaging.

Both-card results, counter JSONs, native callback-test details and representative PNGs are saved in the evidence directory. Temporary full WAVs/logs remain `/tmp/pe9800`; inactive tails are excluded from tone comparisons. Latest source diff checks pass. No commit/release performed.

## Exact-firmware SMP comparison in progress

New temporary launcher `/tmp/pe9800/app-audio-smp-control.sh` uses the signed app's bundled firmware and loader plus boot-command generated from the actual app log and VMRunner CPU GPIO definitions. Corrected 1/2/4 variants are `/tmp/pe9800/app-audio-smp-boot-N.txt`. It preserves app CPU type, RAM, VRAM, resolution, AGP and R350 flags; standalone display capture/network services remain isolated from the user's app. Original disk used only as disposable QCOW2 backing.

Fresh 9800 four-CPU guest `codex-wc9800-smp4-exact-oct06` (launcher 90324; QMP4955/HMP4953/SSH2309) is confirmed by Tiger `hw.activecpu: 4` and `hostinfo: Processors active 0 1 2 3`. New opt-in `POWEREMU_AUDIO_TIMING` records main-loop poll lateness and time waiting for BQL separately. QEMU rebuild passes; no behavior change or app repackaging yet. Existing nanosecond kqueue timer implementation is present. Emulation threads already use USER_INTERACTIVE QoS; main-loop priority and lock contention are hypotheses to measure. Initial setup shows lock waits several ms and ~1.5s aggregate per 5s versus sub-ms polling overshoot, but loaded-scene control data still needed. Actual Warcraft soundtrack capture now running through map entry; finish separate steady scene/tone/1/2CPU controls before conclusions.

## Verified active-CPU controls (6 October, continuation)

The four-CPU guest was verified online (hw.activecpu=4); the one-CPU guest likewise reports 1. Same bundled app firmware, explicit GPIO CPU startup, 9800/256 MB, RAM/resolution and flags. Still a standalone capture frontend: do not equate these with the full native app services/display path.

| Active CPUs | Static loaded-map FPS | Tone low 10 ms windows, interior 5–45 s |
|---|---:|---:|
| 1 | 31.02 | 0% in all eight 5 s windows |
| 4 | 34.10 | 0–2.4% |

Both full tone logs have zero catchup-discarded counts. Main-loop shared-lock waits reach ~13–14 ms; typical polling overshoot is sub-ms. One CPU is cleaner but does not eliminate long lock waits. These results support the user's CPU-count observation; they do NOT establish that the 50 ms cap destroyed PCM, or that the host as a whole was saturated. The counter discards timing budget, not a directly counted PCM buffer. Soundtrack WAVs also captured through map entry, but music silence/RMS alone cannot diagnose gaps. Original Miles crash report unchanged after one-/four-CPU tests. One-CPU tone WAV has a long inactive tail; exclude it.

Two-CPU exact-firmware control now running, confirmed hw.activecpu=2 and hostinfo processors 0 1. A disposable native test library has been prepared at /tmp/pe9800/native-audio-support, containing Tiger Audio Test.poweremu with original disk as QCOW2 backing and cloned tools disk. It has NOT been launched yet. Must stop owned standalone guest and gracefully quit existing PowerEmu UI before native launch to avoid global service socket collisions. Opt-in main-loop diagnostics have been built into QEMU, not yet repackaged into the signed test app.

Current data: /tmp/pe9800/wc9800-smp{1,4}-{cpus.txt,rate.json,music.wav,tone.wav,tone.log,tone-analysis.json,summary.json}. Temporary launcher app-audio-smp-control.sh and app-audio-smp-boot-{1,2,4}.txt. Next: finish two-CPU music/FPS/tone, then compare native four-/one-CPU audio and lock timing. Avoid GPU/BQL unlocking (known corruption); do not blindly cherry-pick the alternate frame-clock architecture from 428ca1a7e65. No audio fix claimed.

### Two-CPU control completed; native app now testing

First two-CPU attempt excluded (wrong older backing disk); retained INVALID note. Corrected tag codex-wc9800-smp2-matched-oct06 uses original Tiger backing and matching tools clone. Confirmed hw.activecpu=2. Same loaded map: 30.42 FPS; tone low interior windows 0–0.2%, timer max 22,348 us, lock max 18,071 us, zero discarded budget. Game alive; original crash report remains 66,446 bytes / Oct 5 21:54. Test stopped. Evidence copied into evidence/r350-performance-2026-10-06/verified-smp. Approx first 45 host intervals in 1-/4-CPU tone logs: respectively 11,299 and 11,239 padded host frames, so the host shortages have not explained the difference in pre-host capture quality.

Native test launched through signed app with isolated POWEREMU_EXPERIMENT_SUPPORT=/tmp/pe9800/native-audio-support and POWEREMU_HELPER=/tmp/pe9800/audio-timing-app/Contents/Helpers/PowerEmu VM.app. Temporary helper contains diagnostic binary, ad-hoc signed, matching freshly calculated SMP manifest in sibling Contents/Resources; public/signed main bundle untouched. Four CPUs confirmed active. App was gracefully quit before isolated launch to avoid service socket conflicts. Original user VM not started. Native test QMP socket is app-owned; use HMP telnet 4963 (/tmp/pe9800/native-hmp.py) and guest SSH2319, not concurrent QMP. Helpers native-wc-launch.py and native-perf-rate.py. Native app launcher session34720; game-launch session2513. Finish native loaded-map/music/FPS/tone before drawing conclusions. Restore ordinary UI after stopping test and quitting isolated app. No audio behavior fix in this continuation.

## Native app result and concrete next implementation

Native four-CPU 9800 control is complete: **33.23 FPS**, same loaded 1680×1050 map. Tone interior low windows **0–2.2%**; not a speaker-quality guarantee. Approx first 45 host intervals:3895 callbacks, 185 partials, 15,313 padded frames. Unlike standalone controls, native active-tone intervals contain ~77 ms and91 ms pacer stalls, approximately2,999 dropped timing-budget frames. Main-loop diagnostics show one stall comprised ~36 ms polling overshoot plus~40 ms lock wait, and another~89 ms lock wait. This establishes that the proposed cap mechanism can occur through the native app path; it does not establish that all distortion is caused by the cap, or why the lock holder was delayed.

Important logging limit: `log none` does not close the app's trace destination, so the diagnostic tone log kept growing after the 49.40 s WAV ended. A later~80 ms stall belongs to inactive tail. Evaluate aligned active recording intervals, not full log aggregates. Full tone log frozen by switching logfile before cleanup; native summary explicitly marks this limit. Native soundtrack captured through map entry too. No build/profile overlapped measurements.

Game clean quit; original Miles crash report unchanged. All owned test guests and idle launcher wrappers stopped. Isolated app quit; ordinary signed test app UI restored, original Tiger remains stopped with 1 CPU. Public bundle and original VM disks untouched. No new audio behavior fix shipped. Source addition this continuation is only opt-in `POWEREMU_AUDIO_TIMING` main-loop diagnostics; built successfully and diff check passes.

### Next coding steps, in order

1. Reproduce the native 4 CPU stalls in a separately instrumented run. Record monotonic timestamps on pacer and host-stat intervals, and identify BQL holder/hold duration at long waits. Instrument specific GPU synchronization/PM4 operations and device callbacks with opt-in elapsed times; keep logging off the real-time audio callback. Do not profile while collecting the comparison FPS/tone.
2. A/B main-loop macOS QoS against current vCPU USER_INTERACTIVE QoS, behind an explicit experimental flag. Check for host scheduling pauses as well as long device calls. Retain serialized GPU state/BQL ownership; previous unlocking caused SMP surface corruption. A lower-frequency thread waiting behind a GPU operation requires a bounded operation or correctly scheduled servicing, not unsafe device concurrency.
3. Separately A/B the existing configurable host feed interval: isolated config audio=`coreaudio,timer-period=1000` versus current 10,000 us on the same 4 CPU native setup. Measure host callback shortages, pre-host tone continuity, actual Warcraft soundtrack, loaded-map FPS and CPU cost. **Not tested yet; do not make it a default on speculation.** Longer buffers alone do not repair guest-generated gaps.
4. If pacing remains tied to delayed descriptor delivery, port only the relevant independently clocked frame-counter/descriptor-completion principles from 428ca1a7e65. Preserve one synchronized input/output hardware clock, reset/rate-change behavior, guest IRQ semantics and accepted-write accounting. Avoid a blind cherry-pick: alternate branch has a larger dependent architecture. Do not take BQL or touch guest memory from a host audio callback.
5. Validate each behavior change with 1/2/4 active CPUs, same native firmware/disks/resolution/game scene, then both 9200 and 9800. Include map movement, soundtrack and interaction, controlled tone, clean quit, crash-report comparison and speaker listening. Tone capture alone cannot certify audio fixed; include smaller pops/phase discontinuities rather than only near-silent10 ms windows. Repackage/sign only after a demonstrated improvement.

Evidence: docs/evidence/r350-performance-2026-10-06/verified-smp (CPU verifications, JSONs, native tone log, map screenshots). Full WAVs temporary in /tmp/pe9800. **For current user testing,1 CPU remains the best observed workaround, not the completed SMP fix.**

## Host-feed interval experiment started

Native isolated Tiger test restarted with audio=`coreaudio,timer-period=1000`, four CPUs, same diagnostic helper, original Tiger backing untouched. Launch log confirms1,000us parameter and guest confirms4activeCPUs. Prior10,000us native baseline evidence frozen. Guest SSH2319/HMP4963. App session44301, game launch28136. No code audio behavior change yet. Finish same map/music/FPS/tone, then separately profile loaded scene (do not overlap profiling with measurements). Compare active intervals only and keep own temporary clone; restore normal UI after testing. New outputs use native9800-fastfeed prefix to preserve baseline.

### Fast-feed result: rejected as an improvement

Initial native fast-feed run excluded because Tiger cleared guest /tmp helpers on reboot; game never reached map and no tone played. Renamed native9800-fastfeed-invalid-* with explicit NOTE. Helpers restored; corrected same-map run succeeds (screenshot manually inspected). Four CPUs;1,000us audio feed:31.46 FPS versus native10,000us33.23. Tone low windows0–5.8%; approx first45 host intervals3912 callbacks/239 partials/30049 padded frames. Max pacer282ms; lost timing budget16168 frames. No evidence of an improvement; do not change default audio interval. Log frozen immediately after capture by switching logfile; no inactive tail aggregation intended.

New lead: guest PEClock connects every30s and VMRunner routes each clock connection through libslirp guestfwd cmd:/usr/bin/nc. Bundled libslirp imports g_spawn_async_with_fds; clock-driven process creation may explain native-only periodic stalls. Hypothesis only until forced-clock probes. Three manual /Library/PowerEmu/PowerEmuClock -n calls now run in separate logs native9800-clock-probe-N.log; host monotonic endpoints saved native9800-clock-probes.json. No probe/profile overlapped valid FPS/tone. Game alive, isolated clone only; ordinary UI not yet restored. Native app session44301 remains running.

### Forced clock requests reproduce long stalls

Three isolated /Library/PowerEmu/PowerEmuClock -n requests under the loaded native4CPU scene each reproduced a long pacing delay:170,928us,82,921us,79,568us with discarded timing budgets7,819/1,451/1,303. Two matching main-loop intervals show~170ms/~80ms lock waits. Probe logs and host endpoints preserved in verified-smp evidence. This strongly implicates relay spawning in the guestfwd clock path; no profiler used. Native ClockServer is accessed through cmd:/usr/bin/nc, reconnecting every30s.

VMRunner now has an **opt-in** POWEREMU_CLOCK_SOCKET=1 path: `-chardev socket,id=peclock,path=<clockPath>,reconnect-ms=1000` and clock guestfwd to chardev:peclock. Default relay path retained until validating serial requests, overlapping clients, disconnect/reconnect and playback. No GPU concurrency or audio default changes. Separate signed app built /tmp/pe9800/PowerEmu Clock Socket Test.app; deep/strict signature passes; firmware SHA matches previous app78f0c... exactly. Original signed/public bundles untouched.

Isolated test restarted with original10,000us audio feed and socket flag. App session9071, SSH2319/HMP4963, native-audio-support clone. Must restore helper binaries into guest /tmp after each reboot; first failed fast-feed run demonstrates Tiger clears them. Next confirm four active CPUs/clock replies, copy helpers, launch Warcraft, measure same scene/tone, then forced clock probes and overlapping clients/reconnect. Stop test and restore normal UI afterward. No final fix claim yet.

### Direct clock socket preliminary result

Same loaded map screenshot/guest verified with restored helpers. Native4CPU direct clock socket and original10,000us feed:29.18 FPS (one run; below33.23 baseline, unresolved variability/regression). Tone low windows0–2.0%; approximate first45 host intervals3899 callbacks/175 partials/11323 padded frames. Entire frozen~49.53s tone log max pacer16,014us, zero discarded timing budget. Thus recurring >50ms clock stalls are absent in this bounded run, while smaller pre-host gaps/host shortages persist. No claim of fully fixed audio or speed gain. Forced serial clock probes now repeating under direct path, then overlap/reconnect tests required before defaulting it. App session9071, HMP4963/SSH2319 remains live. All new outputs native9800-clock-socket-*.
