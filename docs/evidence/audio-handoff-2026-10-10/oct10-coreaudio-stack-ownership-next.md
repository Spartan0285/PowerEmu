# Next ownership discovery: validated saved-register stack route

Stopped54202 / freshguest267 produced zero records inside the narrow HP_IOProc body after500 rounds/10ms; errors/drops0. This proves only that no qualifying snapshot was obtained. It does not establish an inactive engine. Prefer a deterministic stack-route gate to another denser random sample of that tiny body.

## Actual static route

Pinned files/hashes and module receipts are in `oct10-coreaudio-dispatch-proof.md` and `oct10-coreaudio-discovery.copies.json`. All addresses below are exact actual parsed PPC instructions; SM addresses are relative to current SoundManagerComponents module base, which must be freshly established.

1. **CallIOProcs retains the current record in r29**: atCoreAudio `0x9146ac04`, opcode `0x7c7d1b78`, `mr r29,r3`; then `bl HP_IOProc::Call` at`0x9146ac08`. Its expected return is`0x9146ac0c`. r30 is current device throughout this caller.
2. HP_IOProc::Call saves caller r23..r31, uses its own r29/r30, then restores those registers via`lmw` at`0x9146b850` before tailcalling the registered function at`0x9146b860`. Thus the SoundManager bridge receives caller r29=current record and r30=current device. **Do not read HP_Call's saved r30 as its own record**: that slot contains the caller's device.
3. Actual SM registered target, relative`0x5794`, has:
   - `0x5794 mflr r3`
   - `0x5798 stmw r30,-8(r1)`
   - `0x579c mr r4,r7` (outputABL)
   - `0x57a0 stw r3,8(r1)`
   - `0x57a4 mr r30,r9` / `0x57a8 mr r3,r9` (HWstate)
   - `0x57ac stwu r1,-0x50(r1)`
   - `0x57b0 bl0x57e8`, returnrelative`0x57b4`.
   It preserves incoming r29 and saves incoming r30=device. Define its allocated frame address **W**. Its backchain is **S=W+0x50**. Saved device is`W+0x48`; its saved return is at`S+8 = W+0x58`, expectedCore`0x9146ac0c`.
4. Inner SM functionrelative`0x57e8` has:
   - `0x57e8 mfcr r5`, `0x57ec mflr r2`
   - `0x57f4 stmw r22,-0x28(r1)`
   - `0x57f8 stw r2,8(r1)`
   - `0x57fc mr r27,r3` (HWstate)
   - `0x5800 stw r5,4(r1)`
   - `0x580c stwu r1,-0x90(r1)`
   - `0x5818 lwz r29,4(r3)` (overwrites live r29; saved r29 remains).
   Define its allocated frame **I**. Backchain`*(I)=W=I+0x90`. Saved original r29=currentrecord is`I+0x84`; saved original r30=HWstate is`I+0x88`. Its saved return is`W+8=I+0x98`, expectedcurrentSMbase+`0x57b4`.

The adjacent frame pair therefore provides **record, device, HWstate**, even when execution is deeper in the mixer/decompressor/Miles callback. This is a static derivation, not yet a demonstrated live stack pair.

## Smallest coherent acquisition

One bounded, **unscored**, observer-free owned setup only. Reuse strictowned backend/guard/2319/freshWarcraftidentity/helperhash/currentvmmap checks. Do not run any audio-quality capture while suspending a task thread.

Use a tmp helper that obtains the current task's thread list, suspends **one thread at a time**, captures PPC state, walks bounded currentStack memory, then resumes that same thread immediately on every path. Never suspend the whole task/VM. Count only the helper's own successful suspension; resume exactly once without undoing any external suspension. Each error/goto/timeout/cleanup path must callthread_resume after a successfulthread_suspend; do not use a host SIGKILL timeout that can strand a suspended thread. An internal strictbudget and signal cleanup flag are required, with an external guard as lastresort.

Walk at most32 backchains /4KiB frame-distance peredge /64KiB totalspan from actualSP. Require16byte alignment, strictly increasing addresses, each read wholly inside the **same exact current ordinary Stack mapping**, no wrap, no cycles. Read only backchain and caller-linkage fields needed to locate a candidate; no blind arbitraryRAM reads. On a candidate read `I+0x84/+0x88`, `W+0x48`, `W+8`, `S+8`. The caller savedLR for a frame is at its **backchain+8**, not indiscriminately atframe+8. Validate both frame sizes, both exact returns, and currenttext mappings before interpretation.

Retain raw PPC state, currentthread identity, Stackbounds, each link/address/value, the two provenprologue byte ranges and their runtime matches, internal capturebegin/end guestmach ticks, and resume status. Afterresume validate actual object identities using the existing boundedrecord/list/device/HWstate/bridge validator; avoid claiming object memory readafterresume was simultaneous with the stack snapshot. Beforeafter stable identity checks still required.

The exact current modulebridge, freshfullprologue/body bytes, actualdevice/list0xa4 membership, record+0device, record+8HWstate, deviceID agreement and generatedbridge equality/target remain required. No historical module/stack/object address may substitute. The original narrow-body validator must not accept a stack-derived record pretending it came from live r30: introduce a separate explicit provenance mode/schema.

## Required gates before another launch

- Host fixture constructs valid adjacent I/W/Sframes and checks all offsets against the exact PPC prologues.
- Reject malformed/backward/cyclic/unaligned/outofbounds chains, wrong return/frame size, changedcode, missing/aliased object pointers, multiple ambiguous candidatepairs, truncatedread, stopped/noncurrenttask, or unsuccessfulresume.
- PhysicalPPC own-task fixture: a known nested assembly call chain with knownsavedr29/r30 constants; suspend/read/resume returns correctconstants and the worker continues. Assert **every successfulsuspend has one successfulresume**, including injectedpartialread/error/timeout paths.
- Parent reviews same task/process/Stackbounds and currentmoduleword/wholecode receipts. Only then one freshunscored owned setup may collect it. If no candidate pair, retain an explicit acquisitionfailure; do not keep relaunching permutations.

## What this does not prove

This route closes only HP_IOProc registered-client ownership if successful. It does not prove timingcausation, timestampcorrectness, or successfulsounddelivery. The current SM live channel/private/SoundComplete chain and opaqueCFMcallback still require their separate checks. No productionplaybackpatch or observerpromotion follows from the stopped zero-snapshot result.
