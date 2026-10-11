# SM observer staging integration — prepare / finalize

Completes the item the 10 October handoff left open: *"Temporary
publication/setup integration for the new SM observer still needs
completion. Reuse the existing Miles split prepare/finalize approach; do not
repeat the failed strategy of doing all discovery after READY or using a fixed
absolute 390-second arm."*

Two scripts, mirroring `oct10-setup-admission-publication.py`:

| | when | what it does |
|---|---|---|
| `oct11-sm-ioproc-prepare.py` | during menu/loading, **before** READY | all discovery; writes `<label>.sm-prepare.json`. Publishes nothing. |
| `oct11-sm-ioproc-finalize.py` | **after** CUA READY | revalidates against a fresh read, pauses the owned VM, publishes once, resumes. |

```sh
python3 /tmp/pe9800/oct11-sm-ioproc-prepare.py  OWNED_PID GUARD LABEL [--delay-sec 3] [--window-sec 60]
python3 /tmp/pe9800/oct11-sm-ioproc-finalize.py LABEL READY_RECEIPT.json /ABS/CONTROL --qmp QMP
```

## What prepare proves, before READY

Exactly one `/Applications/Warcraft III Folder/Warcraft III` by the supported
Tiger `ps -axo pid,command` form; the typed object graph via the existing
`oct10-coreaudio-scoped-data-collect.py` (accepted, and its pid equal to that
live Warcraft); `bridge_target == module_base + 0x5794`, giving entry and
exit `+0x57e4`; the Core wrapper return and SM inner return, cross-checked
between `stack_helper` and the coherent candidate; stack extents, each page
aligned, nonoverlapping and <= 64 MiB, 1..32 of them; the guest AudioTimeStamp
ABI and timebase; and the Miles context — `channel+8` from the driver
contract's sound channel, read with the MD5-pinned `oct10-miles-read-memory`.

## What finalize re-proves, after READY

READY cue verified, owning the same emulator, **under 120 s old**. The same
single Warcraft. A fresh collector run whose `module_base`, `record`,
`device`, `hwstate`, `generated_bridge` and `device_id` are unmoved — any
movement restages rather than reusing. The caller pair unmoved. The ABL read
fresh from `record+0xa0`, with its exact mapped span from a fresh `vmmap` for
that pid (ambiguous or absent mapping is refused, not widened). The Miles
context re-read and byte-identical.

Then, and only then: `stop`, assert `running==false` and `status=='paused'`,
re-check the single Warcraft **while paused**, write the 368 bytes, fsync,
write the ready word `0x534d5031` **last**, fsync. `cont` runs in a `finally`,
so a failure anywhere still resumes the VM. Nothing is read after the ready
word.

## Offline validation performed

- The packer reproduces the accepted fixture control
  `oct10-sm-ioproc-visibility.control` **byte for byte** — the ABI is
  confirmed, not assumed.
- The plugin's latched `.config` is byte-identical to the control, so the
  receipt's `control_sha256` satisfies the validator's identity check.
- Harvesting run against the retained `oct10-sm-scoped-retained` evidence
  yields 14 stack extents, entry `0x162b0794`, exit `0x162b07e4`, core return
  `0x9146ac0c`, timebase 1000000000/24949183, and passes every structural gate
  the validator applies (alignment, context/ABL span, window, delay, stack
  count, nonzero nonce).
- `oct10-validate-sm-ioproc.py` on the existing fixture reads all 354 records
  and now fails on exactly one thing — `fresh publication receipt required` —
  which is the receipt `finalize` writes, with all five flags the validator
  demands.

## Not done

**Never run against a live guest.** Every check above is offline or against
retained artifacts. Two values are read live and have no retained stand-in:
the ABL pointer at `record+0xa0` and its span. The 16-byte context read is
exercised only by reconstruction.

This is staging, not a repair, and not evidence of sound quality. It does not
prove timely presentation; the handoff's falsifiable interpretation still
governs what the resulting trace can and cannot show.
