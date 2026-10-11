# Existing Miles callback service observer

Diagnostic only. Does not change guest code, register an audio client, alter clocks, or repair playback.

Files: `oct10-miles-callback-plugin.c`, compiled `.dylib`, sanitizer fixture `oct10-miles-callback-plugin-test.py`, analyzer `oct10-miles-callback-analyze.py` in this directory.

## Hard gate before live use

A current copied guest PEF is now verified: `oct10-guest-Miles-Carbon-Library.pef`, 496660 bytes, SHA256 `7a9dbeefbef77537097e8cec822014fe6bb40073b5d11de256cdd3cc426f3e41`. Owned setup 58317 / guest Warcraft PID256 produced retained mapping `oct10-miles-callback-setup.58317.guest256.vmmap.txt`: exact Miles file mapped at 00570000–005ea000. This setup was unscored and is stopped. There is **no runtime-verified site manifest yet**; file mapping alone does not prove executable relocation.

`oct10-miles-pef-sites.py` identifies four functions using their unique embedded named PowerPC traceback tables, their traceback-to-entry offset, and disassembly. It does not infer identity from old crash PCs. Code section is uncompressed at file offset0x4600, length459660. All four functions have exactly one indirect return (`blr`) and entry `mflr r0` before stack modification. Return follows SP/LR restoration. Full offline disassembly is `oct10-miles-pef-sites.disassembly.txt`.

| Function ID | Function | File entry | File return | Predicted entry at current file mapping | Predicted return |
|---|---|---|---|---|---|
| 0 | MacSS_GlobalCallback | 0x200e0 | 0x202e4 | 0x005900e0 | 0x005902e4 |
| 1 | SS_fill | 0x20340 | 0x20488 | 0x00590340 | 0x00590488 |
| 2 | SS_stream_to_buffer | 0x20740 | 0x209f4 | 0x00590740 | 0x005909f4 |
| 3 | SS_merge | 0x20a30 | 0x20ed0 | 0x00590a30 | 0x00590ed0 |

These remain **predictions requiring live byte equality plus actual execution evidence**. A file-mapped PEF container can match all bytes without being the executable code; byte equality alone never qualifies a manifest. The bounded read-only PPC helper `oct10-miles-read-memory` is compiled warning-free with the Tiger10.4 SDK via strict trusted ibookip. It uses task_for_pid and vm_read_overwrite without suspending, modifying, elevating privileges, or adding an audio client. It caps reads at64KiB. Permission failures are a rejected gate, not authorization to escalate.

The callback disassembly manipulates double-buffer counters and commands0x51/0x0d before SS_fill. Its identity is the Miles Sound Manager service callback, **not a demonstrated CoreAudio HAL IOProc**. Measure its service cadence without claiming its entry establishes HAL deadlines. Other library functions/CFM stubs or CoreAudio service boundaries require their own independent verification.

Manifest format:

```
# verified-source-sha256=<64 hexadecimal digits of trusted copied PEF>
<virtual-PC-hex> <instruction-word-hex> <function-ID-decimal> <phase>
```

Phase 0 is entry, phase 1 is return. Each PC is unique, four-byte aligned, below 2^32. At most 32 sites/16 CPUs. The SHA256 header records externally verified provenance; **the plugin does not hash a source file or prove its relocation map**. Every translated site also requires exact four-byte runtime instruction equality; mismatch rejects that site and invalidates the run. Do not fabricate a manifest from historical addresses alone.

## Invocation once verified

Add to a separately staged internal owned test backend:

```
-plugin /tmp/pe9800/oct10-miles-callback-plugin.dylib,enabled=1,sites=/absolute/verified-sites.txt,out=/tmp/pe9800/LABEL.miles-callback,arm-after-sec=240,window-sec=120,toc=3a2000
```

Omitting enabled=1 registers no callbacks and allocates no recording buffers. Preserve existing binary/settings, clone-only disk and strict stop guard. No compile/sign/profiling during scored playback.

Requires actual PPC register descriptors r1, lr, r3-r6, msr and r2. Enabled mode requires explicit finite arm delay(0..600sec), window(1..120sec), and nonzero aligned verified Miles TOC. Records user mode only. A missing register or unsupported width invalidates the run; buffer never dereferenced through recorded arguments. Register read buffers reserve 64 bytes before execution; per-CPU event buffers are preallocated/page-touched before execution, 262,144 x64 bytes (16MiB per configured maximum CPU). No callback locks, allocation, guest writes or file access. Clock is CLOCK_MONOTONIC, matching existing markers. Plugin translation processing checks only the configured few PCs; no per-instruction execution hook elsewhere.

Owned graceful stop/quit flushes `.events` and `.json`. Kill-9/missing flush, any drops/register failures/word mismatches, unmatched callbacks, missing time coverage or absent function identity reject the relevant measurement. Events are grouped by CPU on disk; analyzer sorts by time and pairs function-ID + stack pointer + LR, permitting vCPU migration. That pair alone does not identify a process; mapping/context verification remains essential.

## Falsifiable question

Does the existing Miles callback arrive/service/fill late during the same fixed-source intervals where audio becomes zero and phase advances in 512-frame steps? Compare clean and damaged trials within the same minimal map; then reproduce with plugin absent to check instrumentation perturbation.

A 512-frame interval at 44.1 kHz is 11.61 ms, but this is a comparison scale, **not proof of the callback's negotiated quantum or actual deadline**. Inspect measured entry cadence and SS_fill intervals, and any verified CoreAudio service boundary. Normal callback cadence/short duration with damaged audio rejects callback starvation as a sufficient explanation and moves investigation to downstream fill/clip/source-cursor handling. A late callback preceding the phase step supports producer service starvation; it still does not authorize a clock or resampler patch.

## Signed QA loader audit (completed)

The signed QA backend exports every required plugin API. The initial plugin was rejected by hardened-runtime Team-ID checking. Signing the tmp plugin with the existing matching Developer ID exposed a second dependency failure: Homebrew GLib/gettext libraries have a different Team ID. Corrected **only the tmp plugin** install names to the QA backend's already bundled signed `@executable_path/../Frameworks/libglib-2.0.0.dylib` and `libintl.8.dylib`, then re-signed the plugin with the same existing identity. Backend/app entitlements and files were untouched.

Final disabled `-machine none -nodefaults -display none -S -monitor none -serial none -qmp stdio` probe loaded successfully, exited0 through QMP quit, empty stderr, strict plugin signature verification passed, and process inventory was clear. No disks or guest CPUs ran, no live PCs were instrumented. Evidence: `oct10-miles-plugin-loader-check.json` (initial failure), `oct10-miles-plugin-loader-signed-check.json` (dependency failure), `oct10-miles-plugin-loader-bundled-check.json` (success), reproducible `oct10-miles-plugin-loader-check.py`.

The disabled installer returns before registering callbacks or allocating capture buffers. This validates loader/default-off behavior; it does not measure enabled instrumentation overhead or prove guest register support at runtime.

Recompiling the dylib will replace its install-name edits and signature. Reapply those two bundled-library load paths and matching Developer ID signing before using it with the hardened QA backend. Do not disable library validation or change backend signing to accommodate the observer.

## Exact safe setup procedure for the next owned isolated VM

Do this only before a scored window, in a fresh inventoried owned clone VM. The prior setup is stopped.

1. Use the strict owned guest SSH helper to inventory `ps -ax -o pid,command` (Tiger-compatible), select the actual numeric Warcraft PID, and retain `vmmap PID`. Verify the exact Miles path and current base; never use a historical PID.
2. Copy the compiled read-only helper into that owned guest through the existing trusted transfer mechanism. The parent controls guest operations; this agent has not installed or executed it in a guest.
3. If current mapping base is0x00570000, run `/tmp/oct10-miles-read-memory VERIFIED_PID 5900e0 df4` using strict owned SSH, capturing binary stdout to a host tmp file. If base differs, read base+0x200e0, same0xdf4 length. Do not put diagnostics on stdout, and check command success/length. Exact expected region hash is `c88ce23da31ba8e3a9501fdf9c25ff3d8c605de2181b3bfa06c3e5599ca2a076`.
4. Copy `oct10-miles-thread-state` into the owned guest and run `/tmp/oct10-miles-thread-state VERIFIED_PID 574600 5e498c` for the current base (adjust both by the base delta if needed). This is a finite20sec unscored setup sampler: task_threads/thread_get_state without suspension, at most65536 in-memory records, reads the actual instruction word at each PC inside Miles. Require errors/drops0 and actual PCs in range with exact trusted PEF code-word equality. LR-only records are insufficient. Its scheduling cost makes it unsuitable during scored playback. Capture stdout JSON.
5. Run `python3 /tmp/pe9800/oct10-miles-pef-sites.py --base CURRENT_HEX_MAPPING_BASE --live /tmp/pe9800/LABEL.live.bin --execution-json /tmp/pe9800/LABEL.thread-state.json --pid VERIFIED_PID --out /tmp/pe9800/LABEL.miles-sites`. It requires the trusted PEF hash, names, traceback structure, unique verified epilogues, and **entire3572-byte live region equality** plus independent actual-PC/current-PID/live-word evidence before writing `.manifest.txt`. It removes a stale manifest before validating. Missing permission, byte differences, incorrect length or relocated code require rejection and further read-only mapping, not guessed instrumentation. The checked region also contains intervening metadata/stubs, strengthening relocation identification. No final manifest exists yet.
6. Save the fresh mapping/PID/live bytes/JSON/manifest with the label. Stage the plugin only for a subsequent setup using current verified sites; repeat mapping/equality if restarting changes addresses. Retain plugin-off controls. Require zero drops, register failures, runtime opcode mismatches and complete entry/return pairing in stopped-flush metadata.

No compilation, signing, mapping helper execution, debugger or profiling setup during scored playback. Header/source contract reference is the locally available Universal Interfaces `PEFBinaryFormat.h`; function identities come from this exact copied PEF, not public reverse-engineering guesses.

## Optional relocated callback-TVector corroboration

Actual-PC sampling can reveal Miles r2 TOC. For setup91672, reported r2 is commonly0x3a2000. Independent unpacked section1 data has a unique private callback transition vector at+0x1324 containing unrelocated code offset0x1bae0 and TOC offset0x8000. Therefore candidate live data base is r2−0x8000 (0x39a000), and read-only8-byte read at data base+0x1324 (0x39b324) should contain BE `(0x005900e0,0x003a2000)`. Exported AIL_sample_status vector at data base+0x1804 (0x39b804) should contain `(0x00593b40,0x003a2000)`. These are predictions until actual bytes are read. Never use a TOC from an LR-only sample or another library to infer Miles data base. Runtime actual-PC/word gate already independently checks active Miles code; live relocated vector adds direct callback-target corroboration.

## Finite armed candidate after rejected first trace

First full-boot observer run was rejected: three opcode collisions and all four CPU record buffers overflowed. No timing inference is valid. Candidate now arms only within `[installCLOCK_MONOTONIC+240sec, +360sec)` for the example invocation. It returns before any register reads outside the window, retains finite262144events/CPU, and checks user mode plus exact verified Miles r2 TOC before recording either phase. Fresh runtime mapping/callback-vector/TOC verification is required before arming; PID alone is not available in TCG register context. TOC is an instance identity filter, not a universal process identifier.

Both matching and mismatching translated sites receive callbacks, including cached boot TBs. Wrong **translation** words over all time are separate `translated_word_mismatches_all_time` diagnostics. A wrong instruction actually executed inside the armed interval in user mode with matching verified TOC increments `word_mismatches` and rejects the run. Other TOCs increment identity skips; closed intervals increment window skips. No hotpath disk IO, polling thread, allocation or locks. Metadata records exact armed bounds, requiredTOC, capacity, CPU armed matches/window/identity/privilege skips.

Use first only `oct10-miles-boundary-only.manifest.txt` (callback+fill IDs0/1), derived from the previously runtime-qualified manifest. The invalid run's stream/merge sites accounted for~81.5%of retained events; removing them reduces expensive register-sync hooks rather than merely enlarging RAM. Reverify fresh code/vector/TOC before using this same address manifest. READY must be visible by230sec or abort unscored; start fixed trials after arm_start+3sec and finish all trials before arm_end. Verify their monotonic markers entirely lie inside the armed window. Capacity, zero-drop/support/word gates and sourcePCM coverage remain mandatory. Time comparisons need RAW DMA alignment, not hostFIFO presentation alone. Retain plugin-off controls for instrumentation cost.

Old tmp unarmed source/dylib saved as `oct10-miles-callback-plugin-unarmed.c/.dylib`; production backend/app untouched. Updated candidate sanitizer fixtures cover mandatory args, disabled default, closed-window zero reads, TOC filtering on both phases, boot collision suppression, armed collision rejection, overflow and stopped flush. It is signed with the existing matching Developer ID and uses the backend's signed bundled GLib/gettext paths. No enabled live validation has occurred for this candidate yet.
