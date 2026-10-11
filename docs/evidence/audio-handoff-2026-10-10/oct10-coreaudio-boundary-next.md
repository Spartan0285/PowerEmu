# Existing CoreAudio thread discriminator: smallest next boundary

## What core20007 proves

The corrected recorder's actual503 complete command pairs have LR verified, zero status returns, zero error/drop gates and successful stopped flush. Immediate upper duration median79us/p95721us/max9.141ms; callback command median15us/p95106us/max4.793ms. Immediate duration includes the existing payload snapshot. The retained event span is26.853 seconds, menu/loading only; no ESC or known reference playback occurred. It cannot establish Warcraft sound quality or deadlines during damaged playback.

## Capture one existing boundary

Prefer the actual `IOA_Device::CallIOProcs(AudioTimeStamp const&, AudioTimeStamp const&, AudioTimeStamp const&)` boundary before instrumenting several scheduling layers. The historical actual Tiger crash establishes its nesting above SoundManager BigEndian16DecompDispatch and MacSS callback, but supplies direction, not valid new addresses.

The PPC C++ member-function ABI uses r3=this and r4/r5/r6=the three timestamp references, so this boundary fits the corrected recorder's existing GPR set. A direct AudioDeviceIOProc callback needs r7/r8 to observe output buffer/time, so it would require a larger recorder change. The semantic order inNow/input/output must be proved from this actual call-site disassembly and Tiger ABI, not inferred solely from the demangled name.

## Required fresh mapping and identity gates

1. In one fresh owned isolated setup, copy the actual guest CoreAudio Mach-O and SoundManagerComponents binaries read-only through strict owned SSH. Pin exact SHA256, architecture slice and OS build. The most recent map names CoreAudio __TEXT91444000–914c0000 and SoundManagerComponents162ab000–162e5000; these are historical discovery hints only. Never put them directly into a new plugin manifest.
2. Parse the actual PPC Mach-O symbols and resolve the exact CallIOProcs function and its caller inside PerformIO. Inspect the complete function and all return epilogues, exact instructions, pointer assignments, and the call that invokes the registered IOProc. If symbols are stripped or ABI cannot be established, reject this target instead of guessing from historical PCs.
3. During fresh setup verify current mapped executable bytes, actual executing PC/LR, corresponding current object/stack context and exact function-pointer/call-target provenance. Whole mapped-file equality alone does not establish execution. Shared framework code and a generic framework TOC are not process identity. The current recorder's sole Miles TOC gate cannot simply admit this framework site: any new scope must validate the actual Warcraft-owned IOA object/current mapped stack and current Miles driver/header/bases, or a supported actual address-space identity. Do not broaden capture to arbitrary processes.
4. Compile a tiny no-disk PPC method/ref fixture to establish pointer-register decoding and entry/return boundaries. Confirm `AudioTimeStamp` size/offsets/validity flags from the actual Tiger SDK and actual guest mach timebase. Do not borrow modern header layout or equate guest hostTime with host CLOCK_MONOTONIC.

## Bounded measurement

Retain one60-second native known-source window. No extra AudioDeviceAddIOProc, AudioDeviceStart or silent observer client. Use preallocated bounded scalar records flushed only after stop; validate readable timestamp pointer ranges and snapshot read intervals, invalid flags, errors/drops and complete scope pairing. Snapshot inNow and outputTime before and after the invocation, plus entry/return execution time and nested Miles callbacks/command events. Multiple incomplete edge scopes must be explicit exclusions, not assumed successful processing.

Require one qualified exact source and the same known capture retention gates before making any playback conclusion. Pair device FRAME_CNT/sample progression with valid guest sampleTime and its real guest timebase; raw ingestion time is not presentation time.

## Falsifiable split

- Actual existing IO thread invocation gaps or sample-time jumps spanning loss identify scheduling/engine deadline failure below Miles. A later ready sample buffer cannot repair an already-consumed hardware interval.
- Continuous regular IO invocations with sparse nested Miles callbacks, despite prompt successful SoundManager commands, identify converter/command progression within the IO thread.
- Both paths regular, but clean offered bytes becoming zero after downstream copying, shifts the next target to the actual copy/clip boundary and ownership, not generic CPU/GPU/period permutations.

This proposal is diagnostic. It justifies neither a global clock offset, slowing DMA, changing the command pairing nor larger host buffers. No live mapping is presently verified for the proposed framework target, and no code/VM/playback change was made by this review.
