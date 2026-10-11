# Narrow backing query for the stopped SoundManager ownership candidate

The stopped `oct10-sm-stack-live` receipt contains a coherently captured, independently validated adjacent SoundManager frame pair. Six successful suspends have six resumes; errors and drops are zero. Exact return links are current SoundManager + 0x57b4 and CoreAudio 0x9146ac0c. Its saved record and HWstate candidates are 0x40c390 and 0x4464e0, inside the fresh vmmap private writable `PEF binary / CFMPriv_AGL` extent 0x400000..0x505000. The device candidate is ordinary malloc memory. No record/HW payload was read; ownership remains unproven.

The saved-register interpretation is consistent with the pinned CallIOProcs r29-record assignment, HP tailcall restoring caller r29/r30, wrapper saving device and assigning HWstate from r9, and inner prologue saving those registers before clobbering them. This does not establish that the captured pointers still belong to the active Miles client. Actual record/list membership, record→device/HWstate, device identity, generated bridge and Miles ownership links remain required. A PEF label neither validates nor disproves that object chain.

## Ready temporary helper

- Source `/tmp/pe9800/oct10-task-region-query.c`
- Tiger PPC binary `/tmp/pe9800/oct10-task-region-query`
- SHA256 `cf2b4f1ca3d1b5581d5a918048ad9b9b089b7e8ef5c50b2764556b869bfa3113`
- Actual physical SDK/runtime fixture `/tmp/pe9800/oct10-task-region-query.ppc-fixture.json`
- 23 passing gates `/tmp/pe9800/oct10-task-region-query.actual-proof.json`

Compiled warning-free using the established trusted ibookip compiler and exact Tiger 10.4u SDK. No emulator or guest was launched/read.

```text
/tmp/oct10-task-region-query PID ADDRESS BYTECOUNT [ADDRESS BYTECOUNT ...]
```

PID is decimal; addresses and byte counts are hexadecimal. Maximum twelve requests, each 1..256 bytes with checked 32-bit bounds. **All addresses must come from a newly verified current coherent stack; do not reuse the stopped example above.** The helper uses normal task_for_pid and makes two VM_REGION_BASIC_INFO/VM_REGION_EXTENDED_INFO queries per exact scalar span. It reads no target payload, suspends no thread, allocates no target memory and changes no protections. Returned object-name rights are deallocated. Unsupported flavor/partial ABI/next-region results fail explicitly.

Receipt schema 1 reports basic/extended status and count, exact region start/size, protection/max-protection, shared/reserved/inheritance/object offset, user tag, external_pager, share mode and shadow depth before/after. `covered_stable` requires both queries to contain the complete requested scalar and agree on identity fields. It does not require volatile residency counters to match. Top-level payload_reads=0 and vm_mutations=0 in normal mode. The physical --self-test allocates and populates its own test page only; fixture mode is never a guest capture.

## Narrow next setup and hard limits

In one unscored setup, collect fresh coherent candidate values, current task identity and maps. Query only the exact record 0xa4 bytes, HWstate 0x2c bytes and device 0x6c bytes, then repeat after the rest of the existing stable identity checks. Retain exact receipts even if unsupported. Compare query ranges with fresh vmmap ranges; reject discrepancy, mutation or incomplete coverage. Keep the existing object-reader PEF rejection intact until this evidence is reviewed.

`external_pager=0`, SM_PRIVATE and writable protection are supporting metadata, **not an anonymous-RAM certificate or object-ownership proof**. A CFM user tag, private COW page, or generic vmmap name can describe several underlying uses. This basic/extended helper does not prove a recursive leaf/submap classification; if that becomes necessary, a separately bounded vm_region_recurse query is the next explicit gate. It never authorizes a broad PEF allowlist, MMIO reads, following arbitrary pointers, or a production observer.

The physical fixture establishes both actual Tiger ABI counts (8/8) and populated anonymous metadata, not the backing of the stopped guest candidates. Host fixtures reject changed fields, unsupported/partial counts, next-region and partial-span results. File-backed metadata remains queryable but cannot become payload-read permission automatically.
