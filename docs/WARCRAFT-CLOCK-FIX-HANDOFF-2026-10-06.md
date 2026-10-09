# Warcraft clock-service stalls — October 6, 2026

## Finding

Native four-CPU Warcraft playback has occasional long stalls associated with the guest clock service reconnecting every 30 seconds. The app routes each clock connection through libslirp `guestfwd ... cmd:/usr/bin/nc`, which starts a relay process in QEMU. Three forced clock checks each reproduced a long pacing delay: 171, 83 and 80 ms, with discarded timing budgets 7,819 / 1,451 / 1,303 frames. The main-loop trace observed long shared-lock waits in matching probe windows. This identifies a reproducible trigger, not the complete cause of every audio defect.

A direct clock socket prototype removed those large delays: the same probes measured 10–14 ms, zero discarded budget. But two of eight simultaneous clients failed. That prototype has been removed from production source. It remains only in a temporary test app for diagnostic evidence; do not ship it or enable it by default.

## Implemented production change

`guest/src/PEClock.c` now retains the daemon's own TCP connection between checks. Existing separate-client relay behavior is preserved. Failed, timed-out, incomplete, malformed or nonfinite replies close the connection; the next check opens a fresh stream. The daemon avoids SIGPIPE on a disconnected stream. Only complete valid responses may reach the existing time-correction code. The `-n` one-shot interface still closes its own connection afterward. No guest protocol version change or audio default change.

This removes recurring relay creation by the regular daemon after its first connection. Other services and explicit one-shot clock probes can still start relay processes; do not claim all spawn-related delays or all audio gaps are fixed.

## Validation

Production-code socket fixture: `guest/tests/clock-connection.c`. It includes the actual source with a renamed main and local test endpoint; never changes system time. Verifies reuse of one connection across measurements, fragmented replies, peer EOF, malformed and incomplete replies, nonfinite data, a read timeout and reconnect/recovery.

Passed with native clang + ASan/UBSan, on the PowerBook G4 running Leopard using gcc-4.0 and the 10.4u SDK, and as a PowerPC executable inside the Tiger test VM. The user installed the updated daemon and reports roughly 70% subjective improvement (fewer pops/slowdowns), with defects still audible. Live map capture confirms remaining gaps; do not claim the speaker output is fixed.

A separate PowerPC probe exercised the actual normal app relay from Tiger without clock correction: three five-sample measurements over the same connection, with 30-second idle intervals. All passed; quickest round trips were 0.294 / 0.171 / 0.169 ms. This validates live protocol reuse for 60 seconds while the old protected daemon is still installed; it does not validate Warcraft audio or replacement-daemon lifecycle. Probe source and output are saved in the evidence directory.

Native test command from repository:

```sh
clang -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -g guest/tests/clock-connection.c -o /tmp/clock-connection-test
/tmp/clock-connection-test
```

PPC build/test staging on the physical G4 is `/tmp/pe-clock-reuse-oct06`; only that new temporary directory was used. Existing remote build trees untouched. Source-based tools and packages built under its `tools` subdirectory.

## Artifacts

Test disc: `/Users/adam/Developer/PowerEmu/build/PowerEmu Tools Clock Test.iso`. Contains installer and uninstaller packages plus a test readme. Mounted read-only and verified packaged clock binary SHA256:

`0aa629798dada85e81f933433018d23ee96d96a66af60ad4fe03973ae9482e0b`

Host temporary package tree: `/tmp/pe9800/clock-reuse-tools-built`. The existing protocol/tool version is retained; this is a test rebuild, not a release. Public bundle and repository `guest/build` untouched.

Evidence: `docs/evidence/r350-performance-2026-10-06/verified-smp`, including probe logs/JSONs, tone analyses, map screenshots and Tiger/Leopard fixture results. Full WAVs remain `/tmp/pe9800`.

## Other experiments and limitations

Native default 10 ms host feed: 33.23 FPS; approximate first 45 intervals 15,313 padded host frames; max active-tone pacer ~91 ms. Changing host feed to 1 ms produced 31.46 FPS, ~30,049 padded frames, max pacing ~282 ms and worse tone gaps. Rejected as an improvement; default stays 10 ms.

Direct socket prototype: 29.18 FPS, repeat 28.26; ~11,323 padded frames; max frozen tone pacing 16 ms, zero lost budget; tone low windows 0–2%. Remaining gaps persist and speed did not improve. These are diagnostic results, not results for the new persistent daemon.

One failed fast-feed setup was excluded and renamed `native9800-fastfeed-invalid-*`: Tiger clears guest /tmp helpers on reboot. Always restore click/tone helpers and verify executable presence and actual loaded-map screenshot before measuring. Later corrected run is the valid fast-feed comparison.

QEMU log caveat: `log none` does not close the app's trace destination. Freeze measurement logs by changing logfile after stopping capture. Never count inactive tails as active tone. HMP WAV capture precedes CoreAudio and cannot certify physical speaker quality. Python and QEMU clock origins were not calibrated for direct absolute timestamp matching; use distinct probe log windows.

Keep GPU state/submission under BQL. Unlocking it previously caused SMP corruption. No such concurrency change made here. Intermittent Miles crash and desktop marks remain separate unresolved issues.

## Current live setup and next steps

All prototype guests stopped. Restarted the signed ordinary test app against the isolated library with the normal relay path (no POWEREMU_CLOCK_SOCKET). The completed 9800 run used app session 39531; the successful 9200 comparison used session 99084 (session 35754 was a black-screen firmware mismatch and is excluded). Library `/tmp/pe9800/native-audio-support`, Tiger Audio Test.poweremu, four CPUs, original Tiger disk as read-only QCOW2 backing, cloned tools disk. Original user VM untouched. Diagnostic helper `/tmp/pe9800/audio-timing-app/Contents/Helpers/PowerEmu VM.app`, SSH2319/HMP4963; QMP is app-owned. The user completed the test installation. Installed daemon SHA256 matches the packaged hash above, exactly one clock daemon was running after reboot (PID 32), and Tiger reports four active CPUs. Normal relay PID 56426 remained open for over 15 minutes across clock checks. The 9800 game exited cleanly; the original Miles crash report remained 66,446 bytes dated October 5, 21:54:43. The test configuration was switched to 9200 for the next comparison; original user VM configuration is untouched.

1. Installation/hash/reboot/single-daemon checks completed. Continue with the installed test tools; do not repeat the administrator prompt unnecessarily.
2. Test through the normal relay path, not the removed direct-socket prototype. Observe the retained clock relay across multiple 30-second intervals and confirm clock checks remain accurate.
3. Measure actual Warcraft soundtrack and controlled tone in the same loaded map with four active CPUs; compare pacing, host shortages and frame rate. Include movement and clean quit, original Miles crash-report comparison and speaker listening.
4. Repeat on the 9200 and one/two CPUs. Separate residual guest-generated gaps from host callback shortages. Do not change the host feed interval based on the rejected test.
5. Only after live validation, update the bundled tools disc and experimental app for the user. No commit or release authorization implied. Stop only owned guests and restore ordinary UI unless leaving an explicitly requested installer/test ready.

## October 6 afternoon live results

9800 normal relay, four active CPUs, installed persistent daemon, native CoreAudio default 10 ms, same 1680×1050 Chapter One opening. Seamless input was enabled only in the isolated VM to permit CUA navigation. Button clicks required a brief held drag; absolute guest pointer scaling is about 1.178 around screen center (already documented in VMDisplay.swift). UI interactions exclusively through CUA.

- Soundtrack: 14.70 FPS over 30 seconds. First 45 audio intervals: 3,905 callbacks, 100 partial callbacks, 22,287 padded frames, max pacer 112.285 ms, discarded timing budget 7,589; max shared-lock wait 103.424 ms. Recent log tail looked clear but full capture is not clear.
- Unselected-unit tone: 20.13 FPS during a separate sample; low 10 ms tone windows 2.8–8% in interior seconds 5–45. First 45 log intervals: 3,903 callbacks, 117 partials, 13,149 padded frames; max pacer 59.324 ms, discarded timing budget 411.
- Selected-unit repeat: F1 visibly selected Thrall, matching previous baseline view. Separate FPS sample 18.26; tone low windows 5.6–10%. This does not prove a regression caused by the clock change: CPU execution rate and host state differ, and no immediate old-daemon A/B was performed.
- An initial tone capture lasted only 32.84 seconds; renamed `*-tone-truncated.*` and excluded. Valid subsequent captures are 63.48 and 68.01 seconds including tails; analyze only interior tone seconds 5–45.
- A 5-second host stack sample and guest process snapshot were taken after captures, not during them. Source retained in evidence. No new production audio/default change in this testing round.

Next: complete 9200 same-settings control, then repeat one/two CPU tests if needed. Investigate remaining shared-lock/poll stalls and guest-generated DMA silence independently from host shortages. Clock connection reuse is proven operational; complete audio quality is not.

## Matched combined-firmware controls (continued October 6)

The old R350-only firmware (SHA256 78f0c13288f19cb1438548e206edaa8371691f25d37f7c111f63d17935211aed) does not make a display node for PCI 5960. Selecting 9200 in that test build produced a black screen, no IOFramebuffer or display, despite the ATI driver loading. This was not an audio failure. Replaced firmware only in the temporary diagnostic helper with existing combined SMP firmware SHA256 ef674543f363cf36c06ccf4580682d9f3fce98274ef72e575b314176ec469705. The combined firmware boots both 5960/9200 and 4e48/9800 at 1680×1050, 256 MB VRAM and **four actual active CPUs**; verified with system_profiler/sysctl. 9800 reports Core Image and Quartz Extreme support; 9200 Quartz Extreme. Old helper firmware backup: /tmp/pe9800/openbios-native9800-before-common.elf. After ad-hoc signing the diagnostic helper, updated its capability record with actual backend SHA256 db1b454278531ae1627bf447f8ad7708b5782d91049df422758cc73ec5f6a29c and combined firmware hash. Public app/helper unchanged.

Matched Chapter One opening, Thrall selected with F1, same normal clock relay/default 10 ms host feed:

| Card | Music FPS | Tone FPS | Low tone windows, interior 5–45 s |
| --- | ---: | ---: | --- |
| 9200 | 16.73 | 15.72 | 9.6%, 3.2%, then 0–1.2% |
| 9800 | 16.73 | 15.71 | 19%, 6.6%, 15%, 12%, 13.2%, 10.2%, 13.8%, 7.4% |

First 45 log intervals: 9200 music 21,027 padded frames/max pacer 113.488 ms/shared lock 17.287 ms; tone 18,217 padded/max pacer 73.381 ms/lock 26.461 ms. 9800 music 12,413 padded/max pacer 21.952 ms/lock 20.291 ms; tone 13,275 padded/max pacer 61.426 ms/lock 47.071 ms. All four captures have zero discarded TX timing budget. The 9800 tone log reports 671,488 DMA-silent frames in these first 45 intervals; soundtrack 1,058,306. These counters classify left-channel guest DMA amplitudes between -200 and 200; they include quiet audio and zero crossings, and do not count exact-zero or erroneous-silence frames. Do not equate padded frames, DMA silence and discarded timing budget.

Conclusion: host starvation alone does not explain the difference. The 9800 has worse pre-CoreAudio tone gaps despite fewer host padded frames and nearly identical FPS. Investigate guest buffer production/driver scheduling, interrupt delivery and SMP dependencies. This does not prove a specific driver bug or that the persistent clock change caused it. Current frame rates are lower than prior-day baselines on both cards; do not claim a performance improvement. Tone WAVs contain tails; compare only documented interior seconds. 9200 capture 62.35 s, 9800 92.37 s total including tails.

Both games quit normally using CUA; original Miles crash report remains 66,446 bytes dated October 5 21:54, no new crash. One protected clock daemon remained running, PID 32 on 9200, 35 on 9800. Four-CPU app sessions 99084 and 62076 stopped. Next owned session 89380 is **9800 / one CPU**, same isolated library/combined firmware. Need verify actual CPU count, restore /tmp tone helper (cleared on guest reboot), navigate via CUA and repeat tone plus FPS. Then compare two CPUs as warranted and restore isolated configuration to four CPUs before finishing. Packaging fix: scripts/build-r350-app.sh now defaults to the combined SMP firmware, preserving the explicit POWEREMU_OPENBIOS override. bash -n passed; BUILDING-OPENBIOS.md documents all four device IDs and the validated firmware hash. The public app has not been rebuilt in this round; temporary diagnostic helper was validated with both cards. No audio default changed.

## One-CPU confirmation (October 6)

Same normal relay, combined firmware, installed clock daemon and default 10 ms host feed. Actual hw.ncpu=1 verified. CUA loaded Chapter One and selected Thrall with F1. Two separate 45-second tones:

- First: 11.89 FPS. Interior 5–10 s includes tone startup (median amplitude 29.7); use 10–45 s for sustained comparison: low windows 0.8%, 1.2%, 0.6%, 0.6%, 0.2%, 3.6%, 3.4%. First 45 audio intervals: 3,900 callbacks, 117 partial callbacks, 13,561 padded frames, max pacer 20.836 ms, max lock wait 18.171 ms, zero discarded TX timing budget, 332,266 DMA-low frames.
- Repeat: 11.92 FPS. Interior 5–45 s low windows 2.2%, 3.4%, 3.6%, 0.4%, 0.4%, 1%, 3.2%, 0.4%, median amplitude 1,356–1,371. First 45 intervals: 3,895 callbacks, 120 partials, 13,861 padded frames, max pacer 21.214 ms, max lock wait 20.373 ms, zero discarded TX timing budget, 343,963 DMA-low frames.

Compared with four CPUs, one CPU improves pre-CoreAudio tone continuity despite reducing FPS. This makes SMP scheduling/audio production or interrupt timing a stronger candidate; it is not proof of a root cause. Note that the current dma-silent counter classifies left-channel values between -200 and 200 as low, rather than testing exact zero, so it includes quiet samples and tone zero crossings. These counters must not be presented as a count of erroneous silence.

Game quit normally, no new Warcraft crash. Owned one-CPU app session 89380 and PID 57679 stopped. Two-CPU session 98014 started; hw.ncpu=2 and protected clock PID32 verified. Tone helper restored to /tmp after reboot. Continue CUA navigation/measurement, then restore isolated config cpuCount=4 on exit.


## Two-CPU repeat and completed test round (October 6)

Actual `hw.ncpu=2`, normal relay, combined firmware, protected clock daemon PID32 and default 10 ms host feed. First Chapter One load crashed in Warcraft's audio mixer: report dated October 6 16:40:24.800, PID255, Thread7 EXC_BAD_ACCESS/KERN_INVALID_ADDRESS at 0x17918e42, unknown PEF frame followed by Miles `SS_merge`, `SS_stream_to_buffer`, `SS_fill`, `MacSS_GlobalCallback` and SoundManager. No graphics driver on the crashing stack. Saved full report `native9800-common-smp2-crash.txt`; this is a separate stability issue, not an audio-dropout measurement. One failure and one successful load are insufficient to call it a two-CPU-specific crash.

Retry PID275 loaded Chapter One successfully through CUA; Thrall visibly selected with F1. Two independent 45-second guest tones:

| Run | FPS | Low tone windows, sustained capture-relative 10–45 s | Padded host frames | Max pacer | Max shared-lock wait |
| --- | ---: | --- | ---: | ---: | ---: |
| First | 12.15 | 5.8%, 2.6%, 6.8%, 10.6%, 14.6%, 4.4%, 4.6% | 13,465 | 42.448 ms | 25.718 ms |
| Repeat | 12.48 | 5.4%, 1.8%, 3%, 2.8%, 1.8%, 3.6%, 3.8% | 13,331 | 26.263 ms | 22.713 ms |

Counts are first 45 log intervals. Zero discarded TX timing budget in both. Callback totals 3,901/3,902 and partial callbacks 105/111; DMA-low samples 617,221/536,258 (see counter definition above). Initial 5–10 s tone startup is visible (median amplitudes 508.9/272.9), so exclude it from sustained comparisons. Full WAV durations 64.56/68.02 s include inactive tails. Pre-CoreAudio WAV analysis cannot certify physical speaker quality or quantify a percentage of complete Warcraft audio correctness.

Two CPUs have variable continuity and provide little FPS improvement over one CPU in this round. One CPU remains the more consistent observed workaround, with a performance tradeoff. Four-CPU 9800 gaps were worse than the matched 9200 despite fewer padded host frames; neither a larger host buffer nor a faster host-feed timer is an established complete fix.

A separate five-second host sample **after** the repeat (not during the captured tone) showed 1,293 of 3,847 main-loop-thread samples in `main_loop_wait` waiting for BQL; CPU threads also ran GPU MMIO/PM4 work and waited for BQL. This is evidence of contention in that sampling window, not proof that a specific lock holder caused each audio gap. The sample includes per-draw full-shader NSString formatting in `r300_metal_draw`; it is a possible performance optimization, not a demonstrated audio fix. Do not release GPU access from BQL: the earlier attempt corrupted rendering. Repeat FPS interval reported ~0.098 seconds of R350 draw time per wall second, so draw duration alone is not an established explanation for the full slowdown.

Warcraft exited normally using CUA. The crash report remained 99,687 bytes dated 16:40, so no new crash occurred during retry measurements/quit. Owned app session98014 (appPID57902/backend57907) stopped after normal game exit. No captures or test tones remain active. Restored **only the isolated test configuration** `cpuCount=4`; original user VM/disks unchanged. No production audio defaults changed and no claim of a complete audio fix. Public test app/tools disc still require deliberate packaging validation; the temporary helper contains the validated combined firmware.

### Concrete continuation

1. Keep the persistent clock fix and default 10 ms host feed as the current baseline. Preserve rejected fast-feed/unlocked-GPU experiments as evidence; do not restore them.
2. Instrument the GPU MMIO/PM4 BQL hold duration and the audio timer's actual dispatch delay with a common monotonic host timestamp. Correlate descriptor-completion IRQs, guest DMA addresses/frame counts and host callback shortages during the same capture. Existing post-capture samples cannot provide that correlation.
3. Measure **exact stereo-zero runs** separately from the existing left-channel low-amplitude counter, and correlate sustained tone gaps with those runs. Quiet music samples must not be labeled corruption. Avoid per-frame logging, which would perturb timing.
4. Repeat matched four-CPU 9200/9800 captures immediately before and after any change, same selected hero/map, firmware and host state. Test actual soundtrack, movement and a clean quit, plus a steady tone. Compare sustained 10–45 s for startup-sensitive captures, not complete WAV tails.
5. Reduce long lock holds while preserving GPU/VRAM serialization. Any bounded command-processing/deferred-work experiment must maintain MMIO ordering, fence completion, VRAM visibility and guest buffer lifetime. Restore the baseline if surfaces corrupt or the guest becomes less stable. Do not infer correctness from faster FPS alone.
6. Keep Miles crash investigation separate: collect multiple load/reload outcomes across both cards/CPU counts before assigning causation. Audio smoothness does not establish crash safety.
7. Rebuild the experimental app with combined firmware and explicitly verify both selectable cards and active CPU counts. Update bundled test tools only from the validated persistent-clock package. No release or commit was performed.


## Correlated timing diagnostics (October 6 evening, in progress)

Added opt-in aggregated ring-processing timestamps to GPU CP_RB_WPTR, main-loop BQL acquisition timestamps, host audio pacer dispatch gaps and exact stereo-zero DMA runs. Uses common QEMU_CLOCK_REALTIME clock. No GPU serialization, audio feed interval or emulation scheduling changed. Exact-zero runs are separate from historical left-channel low-amplitude classification. Ring instrumentation covers process_ring_buffer, not every possible BQL holder. Only the worst interval is retained per reporting period, so missing overlap cannot disprove contention.

First diagnostic helper `/tmp/pe9800/correlated-timing-app/Contents/Helpers/PowerEmu VM.app`, backendSHA256 568973a444b0bbb72a1d36f6de5cab3868c3a79223a8f7c0aa64d85ab566ab43, combined firmware unchanged. First map load crashed: October 6 21:05:27.698, PID256, Thread7, KERN_PROTECTION_FAILURE at 0x900; same unknown PEF/Miles SS_merge/SS_stream_to_buffer/SS_fill audio callback stack. Full cumulative crash report saved. Four CPUs, unlike the prior two-CPU load failure, so do not assign this to two CPUs alone. Retry PID268 succeeded and quit normally; cumulative crash report remained 132,730 bytes.

Thrall-selected tone: 19.31 FPS; 75.60 s WAV including tail. Low tone windows 5–45 s: 1%, 3.4%, 4.4%, 2.4%, 4.2%, 2.2%, 2.2%, 2.4%. No production change explains the difference versus earlier runs, so do not claim a fix. Diagnostic audio reports 11–45: 116,803 exact-zero guest DMA frames, 250 runs reaching 64 frames, longest 1,986 frames (~45 ms at 44.1 kHz), max host pacer step16.065 ms. Ring reports in approximate same sustained window: ~14.09 seconds processing across35 reports, longest13.899 ms. Exact-zero data is present before CoreAudio; this does not prove all zeros are erroneous or identify their producer.

**First capture lock diagnostics INVALID:** callsite passed elapsed duration as the new absolute acquired timestamp, producing unsigned underflow in aggregates. Do not use lock-max/total/overlap from this log. Saved analysis explicitly marks invalidity and removes those derived values. Corrected callsite and reset diagnostic zero-run/host-step history on idle pacer stop. No audio behavior changed. Rebuilt and repackaged new helper `/tmp/pe9800/correlated-timing-v2-app/Contents/Helpers/PowerEmu VM.app`, backendSHA25674702d01a5afa269f77bef06c1fa414bb3572de1001c02d8541301ff44ede382, combined firmware ef674543f363cf36c06ccf4580682d9f3fce98274ef72e575b314176ec469705. CoreAudio output fixture and diff check pass. First owned session2538/app61021/backend61027 stopped. Corrected session11664 running isolated9800/fourCPUs; need complete capture and matched9200 control. Public build/tools unchanged.


## Corrected timing capture completed; compact pipeline cache experiment started

The corrected diagnostic helper (SHA `74702d01a5afa269f77bef06c1fa414bb3572de1001c02d8541301ff44ede382`) completed a native 9800 / actual four-CPU run. All seven worst main-loop BQL waits in the selected sustained window overlapped the reported worst GPU ring interval; the longest wait was 18.191 ms, with 18.157 ms overlap against an 18.163 ms GPU batch. GPU processing totaled 16.548 seconds across 35 reports, and lock waiting 15.743 seconds across seven roughly five-second reports. Report selection is approximate, not exact WAV alignment; only worst intervals are retained. This establishes graphics-caused main-loop blocking for those samples, not that every audio gap has that cause.

The pre-CoreAudio WAV still has tone gaps: successive five-second windows from 5–45 seconds were 0.2%, 0.8%, 0.2%, 4.8%, 2.4%, 2.2%, 0.4%, 0.2% low 10 ms tone windows. Median tone amplitude stays ~1367–1379. There were 60,824 exact stereo-zero DMA frames, 155 runs at least 64 frames, longest 1949 frames, across reports 11–45. Maximum host audio step was 20.886 ms. Presented frame rate was 26.169 FPS. These are diagnostic-only runs with substantial run-to-run variation; do not call the higher FPS or lower gap fraction a fix.

First map load crashed again: October 6 21:19:48.119 -0400, PID 253, thread 7, EXC_BAD_ACCESS / KERN_INVALID_ADDRESS 0x1790bdc2, unknown PEF 0x0105118c followed by the same Miles SS_merge/SS_stream_to_buffer/SS_fill/MacSS_GlobalCallback/SoundManager stack. Launching the desktop no-CD app again loaded the map successfully (PID 287). Normal in-game quit succeeded and cumulative crash log stayed 165,911 bytes. Owned test app PID 62002 / backend 62006 stopped. Full WAV remains `/tmp/pe9800/native9800-correlated-v2-tone.wav`; logs, metrics and crash report copied to `evidence/r350-performance-2026-10-06/correlated-timing/`.

A small production optimization now replaces `NSString stringWithFormat` containing the complete MSL program on every R300 draw with an immutable exact shader/state key. All eight prior state fields and exact shader text equality are preserved; no hashes alone decide equality, and cache eviction/Metal compilation/render synchronization stay as before. Standalone lookup benchmark: 200,000 hits with 12 KB shader, old full-source key 0.360146 seconds, compact key 0.015290 seconds. Exact-source equality and every state-field distinction verified. This is a lookup microbenchmark, not a Warcraft/audio result. Existing full Metal rendering fixture passed and backend built (only existing fastMathEnabled deprecation warning).

Isolated helper `/tmp/pe9800/pipeline-key-app/Contents/Helpers/PowerEmu VM.app`, backend SHA `e7a8a0da4f4f4894647f722b8e531b82d4e16540d4acaa71f557089cf98fb419`, common firmware SHA `ef674543f363cf36c06ccf4580682d9f3fce98274ef72e575b314176ec469705`, launched as owned session 7608. Live validation pending. Public app and tools unchanged. Next: verify actual four CPUs/clock helper, load matching chapter/Thrall scene, capture tone+FPS+correlated timing with the compact key, check for visual corruption and new crashes; compare without claiming a universal audio fix. Then test a matched 9200 control and investigate guest mixer/SMP scheduling, including repeated first-load failures.


## Compact pipeline key live validation completed

Owned session7608 (app63058/backend63062), 9800, actual four CPUs, combined firmware and protected clock. Chapter One loaded on the first attempt this boot; Thrall selected with F1, terrain/unit/UI rendering visually intact. Normal game quit verified; Warcraft crash log remained165,911 bytes throughout, so no new crash in this round. One successful load does not establish that earlier Miles crashes are fixed. Capture and tone helpers finished; owned backend/app stopped. Isolated config remains four CPUs. Public build/tools unchanged.

Two captures with compact pipeline key:

- First:20.682 FPS. WAV74.718s includes tail. Tone startup is delayed:5–15s median amplitude~24, so exclude these windows from a sustained-tone claim. Sustained15–45s low10ms windows:5.6%,4.2%,3.2%,5%,1.6%,4.8%; amplitude~1369–1375. Timing reports11–45 include startup:194,493 exact stereo-zero frames,406 runs reaching64frames,maximum2363frames,host step20.132ms,ring max19.766ms,lock max19.144ms;GPU total14.389s across35reports. Do not compare these startup-containing zero totals as steady-state audio improvement.
- Repeat:21.829 FPS. WAV64.103s includes tail;5–45s low tone windows:0.2%,1.4%,3.8%,1.4%,1.4%,2%,0.6%,1.6%;amplitude~1371–1379. Reports11–45:60,621 exact-zero frames,149runs,max1293frames(~29ms);host step15.294ms,GPU max12.816ms,GPU total14.535s across35reports;lock max12.620ms. Five of eight worst BQL waits overlap retained worst GPU intervals. Missing overlap is inconclusive because only worst per-report intervals are logged.

The optimization passes build, existing Metal fixtures, exact key benchmark and live visual correctness. These measurements do **not** demonstrate an overall FPS/audio improvement relative to corrected diagnostic-only26.169 FPS run. Run variation remains substantial; keep the optimization as reduced lookup overhead, not an audio fix. No emulation synchronization or audio defaults changed.

Evidence `native9800-pipeline-key-*` metrics/logs/checks copied into `evidence/r350-performance-2026-10-06/correlated-timing/`; WAVs stay in `/tmp/pe9800/`. Next: matched9200 corrected-timing control, bounded GPU batch work preserving ordered MMIO/fence/VRAM lifetime, and guest DMA descriptor/IRQ-to-mixer timing on SMP. Never restore unlocked GPU experiment that corrupted surfaces. Repeated map-load/reload stability remains a separate required check.


## Page-sized command RAM reads — first live validation

Changed `ppc_mac_gpu_read_ib_via_gart` and the ring reader to share a bounded command-word helper. Previously every DWORD repeated GART/PTE lookup and address-space translation; the observed workload reads billions of command DWORDs. RAM now reads up to a page at once, bounded by physical/GPU page, RAM region, AIC aperture and ring wrap. AIC retains precedence over AGP. Translation is local to each read, never cached across submissions. MMIO/device memory keeps four-byte transactions; endian conversion, execution order, BQL ownership and graphics fences stay unchanged. `POWEREMU_GPU_WORD_READS=1` restores word-sized reading for a same-binary control.

Backend build and extracted actual-helper ASan/UBSan tests passed, in bulk and word modes: noncontiguous physical pages, BE DWORD values, device transaction widths, translation failure and an unaligned higher-priority AIC aperture. Evidence includes temporary harness source/log. This harness tests helper boundaries using mock translations; it is not proof of the entire emulated address space.

Owned app64194/backend64199, actual four CPUs, 9800, combined firmware, protected clock PID32 and normal relay/default10ms feed. Helper backend SHA f5d8f79f778d6dbc653060714238002855f7e2c6d202a046959d822f9ad5cf28. First Chapter One load succeeded, PID280, Thrall selected with F1; no visible rendering corruption. Normal quit succeeded; crash log remained165,911bytes. Owned backend/app stopped after capture.

- First:28.850FPS, sustained15–45s low tone windows0.6%,1.4%,1.2%,0.6%,0%,0.6%. Exclude5–10s startup median41. Reports11–45:35,772exact-zero frames,69runs,max2245frames;GPU total9.908s/35reports,ring max12.374ms,lock total9.140s,lock max12.348ms,host step24.106ms.
- Repeat:27.411FPS, low5–45s0.4%,2.4%,0.4%,0.4%,0.4%,0.2%,0.8%,1.4%. **App packaging ran during this capture**, so do not use its maxima as a clean comparison. GPU total9.573s;host step40.998ms,lock max30.710ms.
- Clean repeat after build finished:27.020FPS, low5–45s0.2%,0.6%,0.4%,0.6%,0.8%,0.4%,0.4%,0.2%. Reports11–45:18,437exact-zero frames,40runs,max1322frames(~30ms);GPU total9.740s/35reports,ring max11.876ms,lock total9.039s,lock max12.218ms,host step21.168ms. All seven retained worst lock waits overlap retained worst GPU intervals.

Results are promising against preceding compact-key20.682/21.829FPS and GPU total~14.5s, but same-binary word-mode control is pending. Do not claim complete audio repair: short zero runs and earlier Miles mixer crashes remain. WAVs in /tmp; logs/JSON/checks copied into evidence. A separately signed candidate was built at `build/PowerEmu 9800 Performance Test.app` with combined firmware; packaged backend SHA a54ec8ee41fe4d10f286a3b6c029b1478982621cc05c599c746b89971415cc63 (signature differs from temporary helper), capability manifest hashes match. Packaged live tests pending.


## Packaged performance candidate and testing interruption

The signed candidate is `build/PowerEmu 9800 Performance Test.app`. `codesign --verify --deep --strict` passed. Backend/firmware hashes independently match its SMP capability manifest: backend a54ec8ee41fe4d10f286a3b6c029b1478982621cc05c599c746b89971415cc63; combined firmware ef674543f363cf36c06ccf4580682d9f3fce98274ef72e575b314176ec469705. The packaged backend was launched without POWEREMU_HELPER, verified in the live process command, and the 9800 guest reports four active CPUs with PowerEmuClock PID32. The installed guest clock tools remain the validated tools2.23; this does not establish the bundled installer ISO as the clock-test ISO. Existing test ISO is `build/PowerEmu Tools Clock Test.iso`.

Same-binary word-mode control was started (app65207/backend65216, game258, four CPUs) but the Mac locked during chapter navigation. CUA explicitly reported it could not unlock the Mac; user was asked to unlock. No comparable gameplay/tone capture was completed, so do not invent a matched old-path result. Owned control was stopped through HMP, without claiming normal in-game quit. This interruption does not invalidate the earlier completed bulk captures; it limits attribution of the speed gain.

What to expect when testing: smoother 9800 gameplay and fewer audio interruptions are plausible from the completed 27–29FPS captures versus preceding21–22FPS compact-key runs. Variation is substantial (an earlier baseline reached26FPS), and audio is not completely fixed. Use the same Chapter One scene/resolution/CPU count and listen during movement and soundtrack transitions. Do not promise a universal percentage gain, perfect audio or fixed Miles crashes. No GPU serialization was relaxed.

Packaged 9200 boot check also passed: live process uses bundled `ppc-mac-radeon` backend, guest reports hw.ncpu=4 and protected PowerEmuClock PID35. This is a boot/SMP smoke check, not a fresh 9200 gameplay/audio comparison. Owned packaged9800 (app65516/backend65521) and packaged9200 (app65562/backend65566) were stopped. No test tones/captures remain. Restored only isolated config to9800/four CPUs; original VM disks untouched. Same-binary control and final interactive packaged game check remain pending Mac unlock. Completed bulk live tests support handing over this candidate for user evaluation; no complete audio or load-crash fix claim.
