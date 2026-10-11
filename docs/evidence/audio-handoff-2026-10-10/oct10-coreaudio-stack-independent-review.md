# Independent saved-register acquisition review

Read-only review of the newest handoff and `oct10-coreaudio-stack-ownership-next.md`. No launch, helper build, production edit or extra research.

## Static offsets agree

The wrapper's pre-allocation `stmw r30,-8(r1)` saves incoming device at W+0x48 after its 0x50 allocation. Its saved return at S+8=W+0x58 must be CoreAudio9146ac0c. The inner function saves r22..31 before its0x90 allocation, so saved r29 is I+0x84 (record) and r30 is I+0x88 (HWstate). Its caller return is W+8=I+0x98, expected current SoundManager base+57b4. Require both adjacent exact backchains I→W→S and both returns; one matching word is insufficient.

The wrapper receives incoming record/device because the actual HP_Call tailcall restores caller r29/r30 first. HP_Call's saved r30 is therefore the device, not its private record. Original narrow-live-register ownership and stack-derived ownership need separate schemas.

## Required acquisition challenges

1. Own-task PPC fixture must exclude the helper's current thread, using its actual thread port identity and correct send-right cleanup. Accidentally suspending itself prevents all cleanup. External Warcraft acquisition must prove a different current task/PID and fresh Stack extent, with no historical port reuse.
2. Every successful suspend requires exactly one matching resume attempt, including state-read failure, truncated linkage/candidate read, signal flag, internal deadline and malformed-stack rejection. A failed resume is a fatal acquisition failure requiring immediate exact owned-VM stop. Do not continue, claim zero errors or merely leave the normal480-second guard to recover eventually. Never externally SIGKILL the helper while it owns a suspension.
3. Do not decrement external suspension ownership. Record preexisting suspend state; preferably skip externally suspended threads as nonordinary setup. Successful cleanup of one owned suspension is not established by total suspend_count returning to zero when another actor exists.
4. Signal handler should only set a sig_atomic_t cleanup flag. Keep the current suspended port/owned flag initialized before fallible work, check the flag and internal time budget between reads, and resume before allocation/formatting/printing, code receipts or post-snapshot object reads. No asynchronous thread_resume from a signal handler or longjmp across cleanup.
5. Bounded chain requires actualSP16-byte alignment, same current ordinary Stack region, strictly increasing addresses, per-edge distance≤4096, totalspan≤65536 and at most32 frames. Linkage reads at backchain+8 and candidate S+8 must individually stay in bounds; a backchain inside the region does not imply its linkage word fits. Reject wrap/cycle/partial read and multiple candidates.
6. Exact code/return identity is mandatory. A process running inside a transient prologue/epilogue can expose incomplete linkage; reject it, rather than trying to repair a chain with guessed frame sizes. Whole runtime prologue/body bytes and current text mappings remain independent of a successful stack walk.
7. Only the selected thread's state/stack is coherent while suspended. Record/list/device/HWstate reads after resume are not simultaneous: perform stable identity checks and retain their distinct times. Such ownership proof alone cannot establish timestamp/deadline causation or audio fidelity.

## Small fixture set before actual setup

Positive nested PPC assembly must reproduce the actual two allocation sizes and pre-allocation saved-register pattern, expose known record/device/HWstate constants, and demonstrate worker progress after resume. Inject each post-suspend state/linkage/candidate-read error, signal and deadline exit. Assert successful-suspend count equals successful-resume count and no lingering owned suspension. Include externally suspended state and self-thread exclusion separately.

Pure chain fixtures should reject wrong exactreturns, I/W size errors, wrong saved-slot offsets, aliased/null object pointers, duplicate candidate pairs, backward/cyclic/unaligned chains, out-of-region I/W/S linkage, boundary+8 crossing, frame33, span65536 overflow and truncated words. Stale code/currentmodule identity must independently reject even a valid constructed stack.

A physical fixture with one easy successful chain is insufficient evidence for fatal-error cleanup. If real resume failure cannot safely be injected, pure/mock the error path and make the parent treat its explicit fatalreceipt as immediate owned-stop, while the actual fixture proves normal owned resume and worker progress.
