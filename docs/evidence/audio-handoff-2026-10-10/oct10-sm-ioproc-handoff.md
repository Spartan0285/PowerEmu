# Existing SoundManager IOProc observer — ready for fresh owned setup

This is a diagnostic candidate, not a playback fix. It observes the already registered SoundManager output client without adding a HAL client, changing periods, clocks, buffers, or audio bytes. All files are temporary; production source, QA app/backend, and clone configuration remain unchanged. No Tiger/game VM was launched for this candidate.

## Verified readiness

- Source: `/tmp/pe9800/oct10-sm-ioproc-plugin.c`
- Signed plugin: `/tmp/pe9800/oct10-sm-ioproc-plugin.dylib`
- Source SHA256: `af79b75672f6dc2fe4744ca6dad7fe27a311b397a964bc527e7058db0691ace2`
- Plugin SHA256: `8edd085c3a5aedc1f7c5374b3b1fccbad29fbf1f50cfb351ff66d8c5929bbe68`
- Same Developer ID signature and bundled GLib/Intl dependency paths; strict signature verification passed.
- Sixteen deterministic ASan/UBSan fixtures pass: `/tmp/pe9800/oct10-sm-ioproc.fixtures.json`.
- Actual signed backend machine-none/7400/no-disk PPC fixture passes 354 paired snapshots, including actual branch/link LR, timestamp/ABL memory visibility, bounded capture and stopped flush: `/tmp/pe9800/oct10-sm-ioproc-visibility.actual-proof.json`.
- Independent validation passes all 354 records; independent validator now has 21 fixture gates: `/tmp/pe9800/oct10-sm-ioproc-visibility.independent-validation.json` and `/tmp/pe9800/oct10-validate-sm-ioproc.py`.
- Actual default-OFF plugin load passes, with no hooks/capture outputs: `/tmp/pe9800/oct10-sm-ioproc-disabled-load.json`.
- Aggregate receipt: `/tmp/pe9800/oct10-sm-ioproc-readiness.json`.

These checks prove observer mechanics on real PPC execution, not Tiger timing accuracy or an audio improvement. The backend hash stayed `aa09bf9c99bc93543626c00e72e29bd4160196fe83b54e464643d73e508a54b4`.

## Smallest next setup

Use only the independent cloned Tiger disk/owned overlay and inventory before launch. Stage a separate diagnostic app/config with this plugin plus the accepted narrow Miles companion and existing raw/host captures. Keep the normal production app/config restored outside the owned test. No extra HAL helper, IOProc, hog lease, or period change.

1. Precreate an owner-only 0600 regular control file of exactly 368 bytes, ready word zero. Stage exactly two SoundManager sites, source hash comment and fresh anticipated module addresses. The plugin requires hints at install; if fresh mapping differs, reject and restage instead of reusing old addresses.
2. During loading obtain fresh actual Warcraft PID, maps, pinned full SoundManager/CoreAudio code, current Miles code/TVector/contract, coherent stack/object graph, registered existing IOProc record/HW/device/bridge and record+a0 ABL. Require a single matching Warcraft process before and after. The code context gate alone cannot distinguish another Warcraft instance at identical virtual addresses.
3. After CUA verifies READY, pause the owned VM; reread fresh identity/code/object receipts. Verify actual current caller path, exact ABL mapping span, Stack ranges, Tiger timestamp ABI and timebase. Publish immutable values/nonce/ranges once and ready word last. Resume. The window starts relative to the plugin's first observed publication, normally delay 3 seconds and at most 60 seconds. Respect the strict owned-VM stop deadline; do not publish if insufficient margin remains.
4. Play the explicitly indexed source fixture. Stop the exact owned emulator, require successful stopped flush, restore exact app/config and validate all outputs. Reject missing full reference coverage; timestamps alone do not qualify source quality. Retain recorder-off controls before any playback promotion.

Plugin arguments: `-plugin /tmp/pe9800/oct10-sm-ioproc-plugin.dylib,enabled=1,sites=/ABS/SITES,out=/ABS/PREFIX,control=/ABS/CONTROL`.

Site file: hash comment `# verified-source-sha256=64HEX`, followed by `ENTRYPC ENTRYWORD 0` and `EXITPC EXITWORD 1`. Entry is fresh SM base+0x5794, word 0x7c6802a6; exit base+0x57e4, word 0x4e800020. Whole current code verification is mandatory; single opcodes are not process identity.

## Proven ABI and caller-path gates

At PRE entry +0x5794 capture r3 deviceID, r4 NOW timestamp pointer, r5 input ABL, r6 input timestamp, r7 output ABL, r8 output timestamp, r9 HW refCon. At +0x579c r4 is overwritten; do not hook there and label it NOW. True return +0x57e4 follows restored original SP/LR. Pair original entry SP/LR across CPUs; no framework r2/TOC gate. Only `org.gnu.gdb.power.core` register descriptors are accepted, avoiding the earlier duplicate LR descriptor bug.

Pinned actual CoreAudio WorkLoop/PerformIO passes NOW and output timestamps from stack allocations. Pinned current CallIOProcs path supplies HP_Call output ABL argument zero; HP_Call therefore selects record+a0 before dispatching r7. This is a verified caller-specific contract, not a generic IOProc assumption. Keep same-run whole caller bytes/return verification. Static review: `/tmp/pe9800/oct10-sm-ioproc-second-opinion.md`.

Fresh retained graph proof, for context only, is `/tmp/pe9800/oct10-sm-scoped-retained.reanalysis.json`. Do not reuse its pointers. It proves one registered record and stable typed object/bridge ownership; it does not independently prove a SoundManager channel-to-Miles handle link or quality improvement.

## Control ABI

Host little endian `<26IQ64I>`, exactly 368 bytes:

- uint32 fields 0..25: ready, version=1, entry, exit, entry_word, exit_word, device_id, hw, record, device, bridge, abl, abl_lo, abl_hi, stack_count, guest timebase numer, denom, delay_sec, window_sec, core_return, reserved=0, context_address, context_words[4].
- offset104 uint64 nonce, nonzero.
- offset112 thirty-two uint32 Stack low/high pairs; unused pairs zero. Each exact current Stack extent is page aligned, nonoverlapping, at most64MiB. No min/max envelope across holes.
- ready is `0x534d5031`, written last while owned VM paused. Plugin accepts an initial zero page, latches once with acquire semantics and rejects changed publication fields. Window1..60sec; delay0..10sec.
- Context is 16 freshly verified actual Miles callback code bytes in this process; words are PPC big endian instruction words represented as host uint32.
- ABL range is its exact current mapped data extent, not a broad PEF allowlist. Published current record/bridge/HW/device/ABL must come from fresh typed graph proof. Plugin rereads record+0/+4/+8 and record+a0 on each entry.

Publish receipt must retain actual evidence behind `fresh_ownership_verified`, `fresh_context_verified`, `fresh_sites_verified`, `guest_timestamp_abi_verified`, `published_while_owned_vm_paused`, plus control SHA256, nonce, owned emulator PID and current guest PID. Include before/after single-Warcraft inventory and caller-path evidence.

## Capture and strict acceptance

Preallocated capacity8192 records (320 bytes each). At actual512/44100 periods a60-second epoch fits; if fresh actual cadence is smaller, shorten the window instead of changing audio configuration. No guest register or memory reads before publication/delay or after the window. No per-event disk IO or allocations. Nonblocking guard/64 pending calls reject contention/reentrancy rather than waiting.

Record header `<6Q8I>` (80 bytes): entry hostCLOCK_MONOTONIC ns, snapshot read-end ns, pre-return ns, SP, LR, serial; deviceID, HW, NOW pointer, OUT pointer, ABL pointer, entryCPU, exitCPU, buffer count. Then NOW64, OUT64, ABL100, zero padding12. ABL reads only count and up to8 scalar AudioBuffers; data pointers are retained but never followed. Header snapshots are reread identical. First failure retains actual register/pointer tuple.

Stopped outputs are PREFIX.records, PREFIX.config, PREFIX.json, PREFIX.flush.json. Require nonempty exact sizes/counts, latched expected publication/config SHA, complete unique entry/return pairs, all CPU register errors zero, and zero config/guard/word/read/bounds/torn/context/object/drop/pair/unmatched/unfinished counters. Require all_outputs_ok and independent validator acceptance. Invalid capture is unscored.

Tiger AudioTimeStamp is64 bytes: sampleTime BE double+0, hostTime BE uint64+8, rateScalar BE double+16, flags BE uint32+56. NOW hostTimeValid and OUT sampleTimeValid+hostTimeValid are mandatory; valid sample/rate values must be finite. Guest hostTime is guest mach ticks, not host monotonic. Convert with actual numer/denom; do not subtract across domains without a bracketed clock mapping. ABL byte counts do not prove frame counts without same-run negotiated format.

## Falsifiable interpretation

Align the existing IOProc snapshot/return intervals, valid guest sample/host timestamp steps, accepted Miles callback/queue timestamps, raw DMA and known source windows. This can distinguish whether existing guest HAL service itself advances with gaps/stale timestamps or whether clean admitted Miles buffers lose content inside a regularly serviced SoundManager path. Positive timestamp lead is not proof of downstream copying. No clock offset, global buffering, resampling or playback patch is justified by the observer alone.
