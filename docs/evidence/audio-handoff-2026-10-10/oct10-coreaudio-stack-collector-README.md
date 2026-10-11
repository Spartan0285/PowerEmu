# Coherent stack ownership collector — tmp-only

Ready files: `oct10-coreaudio-stack-collect.py`, `oct10-coreaudio-stack-verify.py`; actual physicalPPC helper `oct10-coreaudio-stack-snapshot` comes from the device reviewer. No helper or collector has been run against a VM by this agent.

Parent must first verify the device reviewer's physicalPPC fixture and upload exact compiled helpers to guest `/tmp/oct10-coreaudio-stack-snapshot` and `/tmp/oct10-miles-read-memory`. Then use ONE observer-free, unscored, isolated owned setup with its strictguard:

```
python3 /tmp/pe9800/oct10-coreaudio-stack-collect.py GUESTPID CURRENT-GUARD-JSON oct10-NEW-LABEL
```

The collector requires120seconds guardmargin initially, exactownedbackendcommand/metadata/2319/guardalive, currentTiger-supportedPID+command header/body, freshvmmap, and exacthelperMD5. It reads and validates whole actualSMprologues0x88 and CoreAudio callsite12 before any suspension. FreshnumericStackextents are streamed to helper `/dev/stdin`; no historicalStackfile or remoteconfigfilewrite.

Helper CLI uses actualcurrentSMmodulebase..base+0x3a000, freshStackbounds≤32, currentSMreturnbase+0x57b4 and Core0x9146ac0c. The helper performs finite same-thread suspend/state/stack/resume snapshots. Selected record must be an actual retained helper record, with exact addressed bytes backing its frames and savedslots; no syntheticr30 conversion.

Cleanup safety: helper runs through a separatePopen with20second outerdeadline. On timeout the collector first destroys **only its exact ownedbackend**, confirms stopped, THEN kills SSH. It never kills SSH first while the guest might contain a suspended thread. Malformed cleanupreceipt or unbalanced/failed resumes also force the ownedbackend stop. If exactbackendstop cannot be confirmed, the collector rejects and does not kill SSH. Balanced-but-nonzero helper errors reject the trial. Rawstdout/stderr/partialreceipt are retained. Parent must immediately stop on any resume-related fatal receipt; no quality test may follow it.

After coherentproof, the collector reads bounded actualrecord0xa4/device0x6c/list12/HWstate0x2c/bridge16 and codebodies, validates listmembership and exactobjectagreement, then reverseorderidentity/code rereads and currentprocess/vmmap stability. Totalcollectorbudget90seconds uses explicit clock_gettime_ns(CLOCK_MONOTONIC) throughout, matching the guardclock.

Bridge bytes are read solely as ordinary allocatedRAM data. Schema2 acceptance additionally requires the coherent actualSM/CoreAudio functioncall chain, currentregisteredrecord/refCon/device agreement and exactbridgegrammar/currenttarget. It does not claim currentmapping executepermission and does not relax schema1's existingxgate. This distinction is explicit in output.

Offline:

```
python3 /tmp/pe9800/oct10-coreaudio-stack-verify.py RECEIPT --out REVIEW
```

Fixtures: `oct10-coreaudio-stack-fixtures.json`17cases pass (validsyntheticchain and malformedchain/overflow/wrongreturns/partialslots/resumefailure/epoch/prologue/object cases). `oct10-coreaudio-stack-collector-fixtures.json`6mockprocesscases pass, including confirmedbackendstop beforeSSHkill. Neither syntheticfixture establishes a live chain. Original schema1 fixtures stillpass.

Still missing after success: HWstate→CarbonSoundclient ownership; opaqueCFMcallback execution/ABI; timestamp ABI/timebase and any scheduling fault. No sourcecursor, sourceownership, hardwaretiming or playbackquality claim follows solely from this receipt.
