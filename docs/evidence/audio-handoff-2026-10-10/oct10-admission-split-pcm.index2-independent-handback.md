# Observed native index2: limited boundary result

The actual CUA screenshot verifies only native INDEX2 START2/STOP2. No index1/3 or full-three verification is inferred. Actual ESC→STOP2+0.5-second bounds were declared before acoustic fitting, using the retained clock pair.

Within those bounds, two chronological queue-source bursts qualify against the exact written PCM. Latest burst, associated with observed index2, starts queue577/hook531668102884000: prefix.999999978, full.999999945, 18/18 heldouts and zero source-voiced zeros. All1160 queue/admission scopes independently validate, statuses0, drops/errors0, finalflushtrue. Exact PID host log is qemu.log.prev; currentlog is a later failed launch. Host and raw retention are complete.

Full host index2 remains unqualified: prefix.895982, 0/18 heldouts. Do not rescue it by changing source fit or report exactloss counts.

Six of eight predeclared high-entropy256-frame portions of index2 have unique exact raw-byte anchors. All six host anchors preserve one fixed gain.6902066308 (heldout residual<7.6e-9) and one constant raw→host sample offset42363frames. Source→raw/source→host offsets are not constant: they change by4528frames across these inspected fragments. The shifts vary rather than representing one measured fixed latency or global rate. Thus the limited survivingfragments share altered timing before host conversion. Two absent exact snippets are not an exactloss measurement.

This supports the existing boundary claim: exact source is intact at observed queue hooks, SoundManager returns success, and surviving downstreamfragments already fail one source timeline by the rawDMA stage. It does not identify the downstream copy/erase/deadline cause or demonstrate improved playback. Full source-local joins and observer-off confirmation remain necessary before a production patch.
