# Exact scoped task DATA acquisition

Ready tmpcollector: `/tmp/pe9800/oct10-coreaudio-scoped-data-collect.py`; verifier: `/tmp/pe9800/oct10-coreaudio-scoped-data-verify.py`. No VMlaunch/guestreads performed by this agent.

For a later parent-owned setup (not a third boot this turn), parent uploads the already physically validated exact binaries `/tmp/oct10-coreaudio-stack-snapshot`, `/tmp/oct10-miles-read-memory`, `/tmp/oct10-task-region-query`, then ONE fresh owned observer-free unscored setup:

```
python3 /tmp/pe9800/oct10-coreaudio-scoped-data-collect.py GUESTPID CURRENT-GUARD-JSON oct10-FRESH-LABEL
```

Inherited setup/cleanup gates remain: exactownedbackend/strictguard120sec initialmargin,90secglobalcollectorbudget, actualCLOCK_MONOTONIC, freshTigerPID/command+vmmap, exactremotehelperMD5, freshwholeSMprologues/Corecallsite, coherentactualstackpair and balancedresumereceipts. Timeout or missing/malformed cleanupreceipt stops the exactbackend **before** killingSSH. No productionobserver/audio client.

The new path classifies exact writableprivatePEF payloads as **DATA**, not anonymousRAM/code. GlobalordinaryRAM allowlist remains unchanged. It first reads exactfreshcoherentrecord0xa4 andHWstate0x2c; bothpayloads are retained before structuralgraphfalsification, rather than repeatedly reject a legitimatefile-backeddata label.

Each exceptional PEF DATA span requires a current private readable/writable vmmap entry and successful kernel queries covering the entire exact span with actual read/write protection. Read-only, device-labeled, unsupported, failed or out-of-span queries reject acquisition. `shared`, `reserved`, `share_mode`, and `external_pager` are retained as observations, not invented DATA permission or anonymous-backing predicates. The query reads no payload and changes no VM.

Raw query stdout/stderr, exit status, requested span and parsed values are saved **before** validation. Rejections report individual expected/actual fields. Exact payload stdout/stderr and actual byte count are also saved before status/length checks, including partial or failed reads. The stopped 54266 run's discarded query values cannot be recovered or inferred. Metadata changes do not erase diagnostic evidence: final structural ownership acceptance separately requires before/after query and payload-capture metadata stability.

After those two directcoherentpointers, device/list/bridge may be followed only through typedcurrentparentfields. If any exacttypedspan is alsoprivatePEF, it gets its own metadatareceipt and fixedbound (device0x6c/list12/bridge16). No arbitraryregionscan or genericPEFpayload API. The inlinevector is checked only as an arithmeticmembershipview within the queried record's currentregion; no vector-wide payloadread is permitted.

Allstructuralchecks still determine acceptance: savedrecord→saveddevice/HWstate, device→list, exact0xa4listmembership, HWstate deviceID/bridge agreement, exact16bytebridgegrammar/currentmodule target, freshwholecode, beforeafterobjectidentity andprocess/mappingstability. Unsupportedgraph/misinterpreted/stalesavedpointers produce retainedpartialpayloads and accepted=false. No attribution from incompletegraphs.

Success explicitly reports anonymous_backing_proven=false and bridge_current_execute_permission_proven=false. Current callchain/objectregistration can be proven without claiming its payload is anonymousmemory or its mappingcurrentlyexecutable. RemainingCarbonSound/Miles ownership and timing/sourceboundary gates are unchanged.

Tests: `oct10-coreaudio-scoped-data-fixtures.json` has 19 passing cases, including stable shared/reserved/share-mode observations accepted as DATA without anonymous or execution claims; changed metadata still rejects structural ownership. `oct10-coreaudio-scoped-data-collector-fixtures.json` has 9 passing cleanup groups. `oct10-coreaudio-scoped-data-retention-fixtures.json` has 5 passing cases covering rejected query evidence and partial/nonzero-exit payload retention. Original 11 record and 17 stack fixtures remain passing. Syntax checks pass. These are synthetic validator/mock cleanup fixtures, not live object proof.

## Retained actual guest 279 reanalysis

`oct10-sm-scoped-retained.reanalysis.json` accepts the actual retained ownership graph after a narrow offline validator correction. Before vmmap coalesces four typed DATA spans under PEF binary 00400000–00505000; after vmmap labels their unchanged kernel regions MALLOC_TINY. The parser correctly represents both actual outputs. The old qualification wrongly required the PEF label at both endpoints. Each endpoint now must satisfy either the existing unchanged ordinary RAM validator or exact scoped private PEF rules. Kernel fields/region containment and typed address/length stability remain mandatory; unsupported and read-only endpoints still fail. No global allowlist changed.

Actual graph: record0x40c390 is index0 of the current 0xa4-stride list, device0x163eea60/ID258, refCon HWstate0x4464e0, generated bridge0x42c720 targets current SoundManagerComponents0x162ab000+0x5794. All before/after object and code payloads agree; coherent saved stack and balanced cleanup verify. This establishes the dispatch ownership chain, without claiming current bridge execution permissions, anonymous backing, CarbonSound-channel ownership, timestamp ABI or an audio improvement. No new boot/read was necessary.
