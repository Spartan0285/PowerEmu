# Independent existing-client observer validator

Tmp-only `oct10-validate-sm-ioproc.py`;19 fixtures PASS in `oct10-sm-validator-fixtures.json`. No guest launch or production edit. ABI is current Control368/Rec320, distinct from older control versions.

Usage: `python3 oct10-validate-sm-ioproc.py PREFIX --publication FRESH_RECEIPT.json --output RESULT.json`. `--fixture` skips only fresh runtime-publication requirements and must never score an actual guest run.

Fresh receipt schema needs exact captured `control_sha256`, `nonce`, `owned_pid`, `guest_pid` and true retained-proof gates: `fresh_ownership_verified`, `fresh_context_verified`, `fresh_sites_verified`, `guest_timestamp_abi_verified`, `published_while_owned_vm_paused`. These booleans are a setup interface, not independent live verification: retain their same-run object/code/SDK/addressspace receipts and independently audit them before interpreting timing.

Validator checks exact file count/ABI, bounded configuration, nonoverlapping Stack extents, complete serial order, paired original SP/LR, entry/read/exit inside actual arm epoch, supported entry/exit CPUs, client/HW/ABL identity, timestamp full-span pointers, zero error/drop/unfinished counters and successful stopped finalflush. ABL is count+bounded12-byte scalarrecords with zero unusedtail/reserved bytes; no PCM read or bytes→frames conversion.

AudioTimeStamp fields are decoded BE from actual64-byte ABI. Interpret only valid flags. NOW requires validhostTime for guest lead; its sampleTime can be invalid and is ignored. OUT requires validsampleTime+hostTime for output cadence/lead. Any valid sample/rate must be finite; validrate positive. Unknown flags reject unsupported interpretation. No hostmonotonic−guesthostTime subtraction, playback perfection or guestclock causation claim follows.

## Concrete pre-use assumptions

- Candidate r7 equality to published record+a0 ABL is not guaranteed by the static API: HP_Call uses suppliedoutputABL when nonnull and only otherwise record+a0. Require fresh observed outgoingABL identity or explicit approvedsupplied/fallback handling, not an assumed fallback.
- Candidate NOW/outTimestamp Stack-only spans need freshactualpointer evidence. Registered livearguments are provenance; not every legal timestamp pointer must be stackallocated. A bounds failure must retain firstfailed pointer/context so it is actionable rather than lost.
- Sixteen Miles code words identify a program/context class, not uniquePID if another Miles/Warcraft task has identical virtual mappings. Setup must prove only one matching client or retain a true addressspace discriminator. Fresh setupPID alone does not make a globalinstruction observer PID-specific.
- Exit wrapper r3zero is unconditional and does not prove outputfilled. Return contextmust pair restoredSP/LR; do not filter clobbered exitr9 or MachOr2.
- Capture/read overhead and guard contention remain diagnosticconfounds; observer-off quality controls required before promotion. A failed/partial capture remains explicit unscored.


## Final no-disk PPC validation

The final Control368/Record320 implementation was independently validated against `/tmp/pe9800/oct10-sm-ioproc-visibility` (354 complete records). The validator now requires `object_errors == 0`, including rejection of an absent field; the host suite has 21 passing cases. Every retained fixture record has valid paired SP/LR, NOW/OUT flags 7, host ticks 1234/6789, rate scalar 1, and one two-channel 2048-byte ABL. All capture errors/drops/unfinished are zero and final stopped flush succeeds. Evidence: `oct10-sm-ioproc-visibility.independent-validation.json`.

The object reread verifies current record's device/bridge/HW and ABL pointer at entry; the context anchor is checked again at exit. This proves recorder mechanics in the physical PPC fixture, not actual Warcraft ownership, downstream output success, or sound quality. Actual use still requires a same-run fresh publication receipt backed by exact current graph/code/ABI evidence and before/after single Warcraft executable PID inventory. Context bytes alone cannot identify a process.
