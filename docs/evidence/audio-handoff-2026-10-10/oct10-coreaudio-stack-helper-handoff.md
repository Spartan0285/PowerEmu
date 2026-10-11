# Coherent SoundManager stack helper: ready for one unscored ownership setup

The temporary helper is compiled for Tiger PPC and has passed actual physical PPC cleanup/register/frame tests. It has not been run against a PowerEmu guest. This is an ownership discovery tool, not an audio fix or a timing measurement.

## Artifacts and identity

- Source: `/tmp/pe9800/oct10-coreaudio-stack-snapshot.c`
- Binary: `/tmp/pe9800/oct10-coreaudio-stack-snapshot`
- Binary SHA256: `9ed823e1d47e7d3e39042303882ed7c9114328b828fa964e2178e2b6f0ffdbee`
- Source SHA256: `f48b22b782e728fbd671928125bf6cde3e7520598279836906ec67c4b69d5b33`
- Physical receipt: `/tmp/pe9800/oct10-coreaudio-stack.ppc-fixture.json`
- Fifteen passing gates: `/tmp/pe9800/oct10-coreaudio-stack.actual-proof.json`
- Independent collection/validation: `/tmp/pe9800/oct10-coreaudio-stack-collect.py` and `/tmp/pe9800/oct10-coreaudio-stack-verify.py`.

Upload the binary using the existing strict owned-guest helper. Verify its identity before execution. Do not change task access policy or host-key trust.

## Exact CLI

```text
/tmp/oct10-coreaudio-stack-snapshot PID CODELO CODEHI STACKFILE SM_RETURN CORE_RETURN
```

PID is decimal. All address arguments and extent values are hexadecimal without a required `0x` prefix. STACKFILE accepts `/dev/stdin`, containing one `lo hi` pair per line. Supply at most 32 exact current Stack mappings from the same current process; extents must be page-aligned, nonoverlapping and at most 64 MiB each. Do not use an envelope across unrelated mappings or prior-run pointers.

CODELO/CODEHI select the freshly mapped SoundManagerComponents module, not historical addresses. SM_RETURN is current module base + `0x57b4`; CORE_RETURN is the pinned, freshly verified CoreAudio call return `0x9146ac0c`. Fresh code and process identity gates remain mandatory. The helper checks bounded reads and coherence; it does not prove code identity by itself.

## Receipt ABI

Schema 2, provenance `coherent-suspended-stack`. Top-level fields include `pid`, `range_low`, `range_high`, `sm_return`, `core_return`, `rounds`, `errors`, `drops`, `suspend_successes`, `resume_successes`, `resume_errors`, `self_thread_skips`, `total_stack_bytes`, `stop_requested`, `fixture`, and `records`.

Each record contains current PC/LR/SP, r3-r9/r24/r25/r26/r28/r30, current code word, exact Stack extent, mach tick interval, capture error, suspend/resume flags and `resume_status`, addressed `reads`, `frames` and `candidates`. Reads contain actual address, byte count and hex bytes. Frame links contain frame/backchain and the saved LR read at `backchain + 8`.

Candidate `rawslotshex` contains exactly 20 bytes in big-endian order: record from inner+0x84; HWstate from inner+0x88; device from wrapper+0x48; inner return from wrapper+8; wrapper return from caller+8. It is evidence to independently verify, not self-attested attribution.

## Safety and acceptance

Only use during an unscored setup. The helper temporarily suspends one thread at a time, preserves pre-existing suspension counts by exactly one matching resume, and skips its own executing thread. It limits collection to 500 rounds/10 ms, eight seconds globally, 20 ms per held thread, 128 records, 32 stack frames, 80 reads per record and 4 MiB total reads. It stops after the first coherent candidate. No allocations or output occur while a thread is suspended.

Normal capture must have errors=0, drops=0, resume_errors=0, every successful suspend matched by one successful resume, and a complete parseable receipt. A malformed or incomplete cleanup receipt is fatal. If resume fails or cannot be verified, stop and confirm termination of the exact owned emulator immediately. Do not wait for its ordinary guard and do not kill SSH first. External collection timeout must terminate the owned backend before terminating SSH. SIGTERM/SIGINT/SIGHUP merely set the helper cleanup flag; they do not exit while suspended.

The physical self-test intentionally has five injected capture errors. These are not permissible in a normal capture. Its six successful suspends have six successful resumes; the worker advances after each failure. Covered paths include invalid kernel-state flavor, actual linkage/candidate read failure, SIGTERM flag and actual held-time budget expiry. Failed-resume receipt rejection is tested synthetically; actual failed resume is not induced. Fifteen host gates also reject cycles, unaligned/out-of-bounds frames, oversized edges, wrong returns, partial reads and incomplete capped walks.

A coherent thread stack does not make later object reads coherent. Read record/device/HWstate/list/bridge before and after separately, verify their current identity and pinned code, and reject mutation. There is no playback improvement claim.
