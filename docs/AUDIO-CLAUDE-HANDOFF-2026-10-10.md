# PowerEmu audio — Claude Code handoff

Prepared October 10, 2026 (America/New_York). Some evidence labels use October 11 UTC.

## Outcome and immediate objective

**No verified playback improvement beyond the user-confirmed Freeze Test 3 baseline (~95% improved).** Warcraft III still intermittently crackles, loses/delays sound, and briefly stalls when new sounds start. Chess announcements also previously exposed onset problems. Do not tell the user audio is fixed or that a new improved test build exists.

Continue from the now verified **existing CoreAudio → SoundManager output client**, measure its actual timestamps/service alongside Miles callbacks and device DMA, then implement the smallest justified repair. Do not restart broad audio-buffer, GPU, CPU-count, or sample-format experiments.

The latest deliverable is a **tested, signed diagnostic observer**, not a playback fix. It observes the existing SoundManager client without adding an audio client. It has not yet run against actual Warcraft.

## Workspace and ownership

- App: `/Users/adam/Developer/PowerEmu`; current HEAD `5e09249` (clock, CPU reporting and experimental graphics integration).
- QEMU: `/Users/adam/Developer/poweremu-qemu`; current HEAD `2d76be72d8d` (DMA pacing and avoidance of guest relay process stalls).
- Preserve GPU/SMP/Final Cut/rendering work and existing committed audio fixes. Warcraft and Chess rendering were user-confirmed good; Final Cut launches and playback was seen.
- Working trees contain **uncommitted diagnostics and experimental repairs**. Do not reset, blindly commit, or promote them. Status snapshots and binary patches are archived below; untracked source is still in the working trees.
- No QEMU/QA process was running at handoff. The isolated QA environment was restored and strict signature verification passed after the last test.
- **The recurring audio automation was deleted for this handoff**, preventing Codex from launching competing tests while Claude takes over.
- No new commit, push, or release was performed for this handoff. Obtain user authorization before any future commit/release outside the existing scope.

## Read these first

1. This file.
2. `/Users/adam/Developer/PowerEmu/docs/evidence/audio-handoff-2026-10-10/oct10-sm-ioproc-handoff.md` — exact observer ABI, readiness, staging and acceptance.
3. Same archive: `oct10-existing-ioproc-timestamp-independent-review.md` and `oct10-sm-ioproc-second-opinion.md` — independently checked actual Tiger code/ABI.
4. `/Users/adam/Developer/PowerEmu/docs/AUDIO-PACING-FIX-2026-10-08.md` — detailed reverse-chronological evidence. Read newest sections first; older NEXT paragraphs are superseded.

## Verified findings

### Host output is not where the missing source is created

Fully retained loaded controls showed damaged known source **already in guest DMA bytes**, despite regular host callbacks and full host supply. Raw DMA and host output agree sample-for-sample after the expected gain (~0.690206629). All relevant capture drops were zero and stopped flush succeeded. Increasing generic host buffering or adaptive resampling is not justified by this evidence.

Actual Miles `SS_fill` produced intact native PCM. Later queue snapshots showed intact source at the `bufferCmd` entry boundary, while a qualified corresponding host/DMA reference was damaged. This localizes the observed fault **after intact buffers are offered to SoundManager and before device DMA consumption**. It does not identify the exact faulty instruction, establish every utterance loss count, or prove a particular clock bug.

- Produced boundary: `oct10-produced-first`, owned5959.
- Queued boundary: `oct10-queued-first`, owned166. Native reference6 had clean queued source but qualified damaged host output.
- Corrected admission: `oct10-admission-split-pcm`, owned78144. Accepted queue index2 is source-exact; surviving anchors have variable source→DMA position but fixed DMA→host offset/gain. Full host source identity is unqualified, so do not assign exact loss totals.
- Admission commands returned status0. **Success is not proof of timely presentation.**

### Service deficit is plausible; slow fill is not established

Observed queued duration can fall behind consumed duration: 78144 offered ~53.87 seconds versus ~59.96 consumed; median Miles callback interval48.521ms versus a46.44ms buffer. Buffer-specific audit of another retained run found all eight fills completed at least37.392ms before the next callback. Blanket claims of slow `SS_fill`, host underruns, or late IRQ admission are unsupported.

PIC IACK proves interrupt admission, not actual guest driver `takeTimeStamp` execution. Fresh FRAME_CNT reads matched actual transfers, rejecting the lazy-register-read hypothesis; they do not prove all clock domains advance consistently.

### Added audio clients materially change the experiment

Persistent exclusive/hog known-source controls were clean; matched shared controls damaged source. Hog suppresses game audio and cannot ship. Adding a silent/native reference IOProc changes the client count/scheduling, so it is not an innocent measurement tool. The next test must observe the **existing** client, not add another HAL client.

### Existing output client is now proven

Retained run `oct10-sm-scoped-retained`, owned58714/current guest Warcraft279, has full stable before/after object/code/query evidence and independently accepted structural ownership:

- One IOProc record at index0; deviceID258.
- Record → device/HWstate/generated bridge agree with the coherent saved stack.
- Device list contains exactly one0xa4-byte record; HWstate deviceID and bridge agree.
- Bridge targets freshly mapped SoundManagerComponents +0x5794.
- All five object payloads and pinned code bodies were byte-identical before/after.

**Historical pointer values are not a configuration. Re-discover them in every new guest process.** This proves registered-client ownership, not the remaining HWstate→CarbonSound/Miles channel relation, timestamp correctness, or clean delivery.

Earlier acquisition failures were diagnostic bugs: vmmap coalesced data as PEF before capture, then labeled unchanged kernel regions MALLOC_TINY afterward. The scoped verifier now accepts either the existing ordinary-RAM endpoint or exact scoped writable PEF DATA, with unchanged kernel/span/typed graph checks. It does not globally permit PEF memory or assert executable/anonymous backing. Raw query/payload evidence is saved **before** validation. Do not repeat the old rejected collectors.

### Clock calibration does not explain the dominant deficit

TCG PPC TB and Screamer both derive from QEMU virtual time; nominal TB is25MHz. Reported CPU GHz is firmware metadata; PowerEmuClock adjusts calendar time. Actual Tiger mach timebase was1,000,000,000/24,949,183. That conversion difference (~0.204%) is far smaller than the measured ~10.157% queue-service deficit. Actual guest mach↔host slope/steps remain unmeasured. No global clock offset/slowdown patch is justified yet.

## Exact next steps

### 1. Inspect and use the ready existing-client observer

Source: `/tmp/pe9800/oct10-sm-ioproc-plugin.c`; signed dylib same basename. Durable copies are in the archive.

- Plugin SHA256: `8edd085c3a5aedc1f7c5374b3b1fccbad29fbf1f50cfb351ff66d8c5929bbe68`.
- Default OFF; 16 ASan/UBSan gates pass.
- Actual signed no-disk PPC fixture:354 complete paired timestamp/ABL/BL-LR snapshots, errors/drops/unfinished0, stopped flush successful.
- Independent validator accepts354 records;21 fixture gates pass.
- Disabled signed-load test passes. These prove mechanics, **not guest sound quality**.

Use `oct10-sm-ioproc-handoff.md` for the exact368-byte one-shot control and320-byte record layouts. Do not hand-invent an ABI or skip current process gates.

At **PRE entry SM+0x5794**, outgoing registered ABI is r3=deviceID, r4=NOW timestamp, r7=outputABL, r8=output timestamp, r9=HWstate. SM+0x579c overwrites r4. True return is SM+0x57e4 after original SP/LR restoration; pair across CPUs using original SP/LR/current client. Framework r2 is scratch, **not a TOC filter**. Core GPRs must come from `org.gnu.gdb.power.core`; an earlier duplicate SPR descriptor returned LR0 and invalidated traces.

The actual verified Core caller supplies outputABL0, selecting record+0xa0 fallback. Verify the same current caller path, not a generic assumption. Return r3 is unconditionally zero and does not prove mixing success. Timestamp64 flags and actual guest timebase matter; byte counts are not audio-frame counts without current format. A16-byte Miles code context identifies a process class, not a unique PID: inventory exactly one matching current Warcraft task before/after.

### 2. Run ONE fully covered current-client trace

- Use the independent clone below, one owned VM, strict stop deadline, and no builds/profiling/heavy analysis during references.
- Stage the SM observer plus the accepted corrected Miles companion and bounded raw/host capture. No added HAL IOProc, hog lease, period change, or sound synthesis helper.
- Prepare current code/process/format/object proofs during menu/loading. After CUA verifies fixture READY, pause only the owned VM, revalidate, publish immutable control once with ready last, resume.
- Start the short explicitly indexed known-source fixture only after the publication-relative arm delay. Fit selected references wholly inside the ≤60-second observer window and stop deadline; shorten the fixture/window if needed rather than losing coverage.
- Stop the exact owned emulator; restore exact app/config; then analyze. Require all relevant drops/read/pair/unfinished/config/object errors0, valid publication/current identity, nonempty known-source coverage, and successful stopped flush.

Temporary publication/setup integration for the new SM observer still needs completion. Reuse the existing Miles split prepare/finalize approach; do not repeat the failed strategy of doing all discovery after READY or using a fixed absolute390-second arm.

### 3. Use the trace to decide the repair

Compare existing SM entry/return intervals and valid NOW/output sample/host timestamp steps against nested Miles callbacks/queue events, device DMA, and actual known-source windows.

- If existing IOProc service/timestamps skip while device time advances, identify the scheduling/deadline contract and its concrete emulator cause.
- If existing IOProc service is regular but intact admitted buffers disappear before DMA, inspect SoundManager conversion/mix/clip/erase admission at that proven boundary.
- Positive timestamp lead alone does not prove downstream copying.
- Do not subtract guest mach ticks from host monotonic directly. Map domains with bounded request/reply brackets or analyze each domain separately.
- Test a repair using repeated/reverse-order and observer-OFF controls, then actual Warcraft thunder/movie/gameplay with normal sound settings. Promote a signed user build only after a demonstrated audible/source-measured improvement.

## Do not repeat or promote

- `POWEREMU_SCREAMER_SLICE_PACING`256-frame cap worsened controls: leave OFF; do not blindly tighten128.
- `POWEREMU_SCREAMER_LIFECYCLE_FIX` is a default-OFF concrete lifecycle experiment, fixture-tested but not an actual Warcraft improvement: leave OFF.
- Larger2048/4096 guest periods did not establish consistent improvement; a93ms period is not a proven repair.
- Hog/exclusive audio removes game sound: not shippable.
- Aggregate zeros in mixed music, weak whole-source matches, counter-only health, empty recordings, or forced-stall recovery do not establish sound quality.
- Natural silence is not loss; qualify voiced source and timeline locally. Calibration helper scheduling changes need controls.
- No synchronous per-event file logs, unbounded probes, repeated incomplete GUI series, or historical process pointers.

## Safe execution details

- QA app: `/Users/adam/Developer/PowerEmu/build/PowerEmu Depth Wait QA.app`.
- Independent base: `/tmp/pe9800/oct08-autonomous-base/tiger.qcow2`.
- Owned overlay: `/tmp/pe9800/oct08-autonomous-support/Virtual Machines/Tiger Audio Test.poweremu/Disks/tiger-fresh.qcow2`.
- Never open the user's original Tiger disk writable while another overlay depends on it. New tests use the independent cloned base, not the changing original.
- Inventory before launch. Strict owned480-second guard, always below520 seconds; bounded host capture capacity600 seconds. No extension to salvage an incomplete test.
- Trusted command transport: `python3 /tmp/pe9800/guest-ssh.py 2319 COMMAND`. It validates owned process and existing exact trusted guest RSA key. Keep strict checking; do not expose/copy credentials or substitute an untrusted host key.
- Guest launch: `open "$HOME/Desktop/Warcraft III ROC [NoCD].app"` through that transport; distinguish wrapper PID from actual `/Applications/Warcraft III Folder/Warcraft III`.
- Supported Tiger identity command: `ps -p PID -o pid,command`; require header and matching body. `pid=,command=` unexpectedly returned only PID.
- Use `clock_gettime_ns(CLOCK_MONOTONIC)` for host guards/markers. Python `monotonic_ns` uses a different clock on this Mac.
- CUA for actual gameplay; if locked, CLI only without bypass. Guest bulk paste/type was unreliable; use trusted SSH for commands.
- Clone music/ambient/environmental are OFF for isolated references; effects/responses ON. Restore the three targeted values from a fresh resource fork before normal full-sound quality tests; do not overwrite a stale whole fork.
- Any briefly suspended thread in an unscored ownership setup must be resumed exactly once by its owner. Malformed cleanup/failed resume/hang requires exact owned backend stop before killing SSH. No suspension during scored sound windows.

## Durable evidence and temporary tooling

Archive: `/Users/adam/Developer/PowerEmu/docs/evidence/audio-handoff-2026-10-10/`.

Contains191 selected artifacts (~7MB), including observer sources/signed binary/readiness/validators, actual ownership payloads/receipts, copied Tiger frameworks, clock/static reviews, setup helpers and source manifests. `archive-manifest.json` records hashes. Current app/QEMU working-tree patches and status snapshots are also saved. No credentials were copied.

Most scripts hardcode `/tmp/pe9800`; durable copies are backups, not a relocated runnable package. Inspect paths and verify hashes before restoring missing temporary files. Larger raw/host recordings, disk images and numerous historical logs remain in `/tmp/pe9800` and are not duplicated in this small archive. Keep them until relevant conclusions are reproduced.

Key execution tools: `oct10-coreaudio-scoped-data-collect.py`, `oct10-coreaudio-scoped-data-verify.py`, `oct10-validate-sm-ioproc.py`, `oct10-setup-admission-retry.py`, `oct10-produced-owned.py`, `oct08-stop-depthwait-owned.py`, and `oct11-stage-ownership.py`. The last stages/registers/restores observer-free QA; it is not the finished SM-plugin staging integration.

## User-facing acceptance

The user should notice fewer sound-onset interruptions without added game latency or freezes, while Warcraft/Chess/Final Cut rendering remains intact. Validate Warcraft first against FreezeTest3; then Chess announcements, iTunes continuous playback and Final Cut audio. Backend changes may benefit those apps, but they have not all been qualified.

Report the honest distinction between diagnostic progress and playback improvement. Until a repair wins matched real-source controls and observer-OFF gameplay, preserve the current user build and do not ask the user to test another supposedly improved build.
