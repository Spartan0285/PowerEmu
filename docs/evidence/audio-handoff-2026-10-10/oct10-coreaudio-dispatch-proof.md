# Actual Tiger CoreAudio dispatch provenance — stopped guest 293

This is static and sampled-code proof, not a live receiver/registered-client proof or a playback fix. All work used stopped, hash-pinned copies; no guest access or emulator launch.

## Pinned evidence

- CoreAudio SHA256 `238414b621f28a11d719ef77a2b140d6249821fd73001f95e073143db15c68ba`.
- SoundManagerComponents SHA256 `bbc7308fc42d9105cc811d1ef67252a4680605a6c43d887056bd91dd817a22cf`.
- CarbonSound SHA256 `d29c4475d7b0d0dcc496c0d448e8a81960da89bccc0d4f50ea3adf42a302390e`.
- Copy receipts: `oct10-coreaudio-discovery.copies.json`; process/mapping receipt: `oct10-coreaudio-discovery.current293.txt`; independently matched sampled words: `oct10-CoreAudio-live-word-review.json`.
- Guest293 has 24 in-range CoreAudio sampled words matching the exact file, zero mismatches. One sample is inside HP_IOProc::Call at PC `0x9146b7f0`, opcode `0x80be00a0`, SP `0xf0386a10`. Its omitted r30 would have identified the actual current record.

## Proven layout and dispatch

Actual symbols identify IOA_Device::CallIOProcs `0x9146aa94`, HP_IOThread::PerformIO `0x9146a70c`, HP_IOProc::Call `0x9146b778`, HP_IOProc constructor `0x91464790`, list GetIOProcByIndex `0x9146b744`.

IOA_Device+0x68 is its IOProc list. List+4/+8 delimit inline records of stride 0xa4; GetIOProcByIndex uses `mulli r0,r4,0xa4` at `0x9146b76c`. Constructor stores device at record+0 (`0x914647b4`), function at +4 (`0x914647b8`), clientData/refCon at +8 (`0x914647d0`).

HP_IOProc::Call entry arguments: r3=record, r4=now timestamp, r5=input timestamp, r6=input ABL, r7=output timestamp, r8=output ABL. It saves record in r30, now in r24, input timestamp in r26, output timestamp in r25, supplied output ABL in r28. A null ABL can select a record-owned fallback (+0x90 input, +0xa0 output).

Dispatch is a **tailcall**, `bctr` opcode `0x4e800420` at `0x9146b860`, with registered function loaded from record+4 at `0x9146b82c`. Actual outgoing ABI is r3=deviceID (device+4), r4=now, r5=input ABL, r6=input timestamp, **r7=output ABL, r8=output timestamp**, r9=refCon (record+8). Original CallIOProcs return target is `0x9146ac0c`, after its call at `0x9146ac08`. The not-callable route returns separately at `0x9146b874`; do not count that as a client invocation.

IsCallable checks record+0x14, record+0x58 and the sampleTime double at record+0x18 against input or output timestamp according to bit0 of +0x58. These field roles are statically inferred; no live timestamp mismatch or suppression has yet been measured.

**Do not use r2 as a CoreAudio TOC identity gate.** This Mach-O code uses r2 as scratch/vtable/field pointer. A sampled field named toc does not make it a stable TOC. The separate Miles PEF TOC gate remains specific to Miles.

## SoundManager registration agreement (device agent independent proof)

Actual SoundManagerComponents call at relative0xc08 invokes AudioDeviceAddIOProc with deviceID=HWstate+0xc, IOProc=HWstate+0x28, refCon=HWstate. The IOProc pointer is a generated 16-byte bridge, constructed at 0xadc..0xb34: lis r11,high; ori r11,low; mtctr r11; bctr. Pinned __data+0x3a00c supplies target relative0x5794 (current293 modulebase0x162ab000 => 0x162b0794).

Target0x5794 saves r9 as HWstate and copies **r7 output ABL**, not output timestamp, to r4 before calling0x57e8. Thus live record+8 must equal current HWstate; record+4 must equal HWstate+0x28 bridge pointer; bridge instructions must resolve to current modulebase+0x5794. Do not require record+4 itself to lie in the module code range.

## Smallest next owned-task verification

Extend the existing bounded task snapshot helper, rather than add an audio client. Within freshly word-verified HP_IOProc::Call PCs `0x9146b7dc..0x9146b84c` capture r30, r24, r26, r25, r28 and r3-r9, PC/LR/SP/thread identity. These saved registers are valid after the prologue and before lmw at0x9146b850. r28 can remain null when a fallback is selected; later outgoing r7 is authoritative.

For a successful fresh body sample, read only the exact mapped 0xa4-byte record; validate +0/+4/+8 and list membership/stride when the current device/list can be proven. Read bounded HWstate header and its +0x28 pointer; read exact 16-byte mapped executable bridge; prove target and the same process/mapping/code receipt. Follow only validated RAM/code ranges. A direct register-only sample at tailcall0x9146b860 gives the complete outgoing r3-r9 ABI, but record ownership cannot be inferred from r30 there because lmw already restored it.

Capture exact timestamp structs from validated pointers only after the Tiger SDK sizeof/offset ABI is independently established. Retain raw bytes, flags, sampleTime, hostTime, rateScalar and valid flags; collect mach_timebase_info separately in the owned guest. Do not equate guest hostTime with QEMU virtual or host monotonic time without that contract.

Remaining hard gates: current record/HWstate/bridge ownership; fresh task/thread and pointer bounds; exact timestamp ABI/timebase; connection from HWstate into the independently proven CarbonSound channel/private/SoundComplete chain. Static code and PC snapshots alone do not prove these objects.

Only after these gates pass may a finite, default-off observer count actual client dispatch/return and timestamps. Pair original CallIOProcs return by call context (not tailcall-local LR), reject cross-thread/cross-client ambiguity, account for skipped/not-callable routes, and retain recorder-off quality control. No clock, guest DMA slowdown, buffer, or production patch is justified by the current proof alone.
