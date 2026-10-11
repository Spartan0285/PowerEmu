# Existing SoundManager IOProc timestamp observer review

Current retained ownership58714 now establishes current record40c390/device163eea60/deviceID258/HW4464e0/bridge42c720→SMbase162ab000+5794, with stable graph and exact code. These stopped addresses cannot configure a future process; revalidate fresh identity/graph/code before a bounded observer.

## Exact entry and return

Hook PRE module+5794 (`mflr r3`,7c6802a6): registered ABI r3deviceID,r4NOWtimestamp,r5inputABL,r6inputtimestamp,r7outputABL,r8outputtimestamp,r9HW/refCon. Module+579c copies r7 into r4, destroying NOW; no later r4 hook may be labelled NOW. Mach-O r2 is scratch, never a shared TOC filter. All core register descriptors must retain the already proven core-feature fix.

Return hook PRE module+57e4 (`blr`,4e800020) follows restoreSP+50 at57d4, restoredsavedr30/r31 at57dc, and mtlr at57e0. Match validated entry to this return using originalSP and restoredLR9146ac0c, retaining fresh client identity in pending context; CPU can migrate. Never use tailcall-local LR or require clobbered exitr9 to remain HW. If stack identity/client context or overlaps are ambiguous, reject. Wrapper sets r3zero at57d8; exitOSStatus0 is structurally unconditional and does not prove successful mixing/output.

## Timestamp and ABL gates

Actual Tiger ABI: AudioTimeStamp64bytes, sampleTimeBEdouble0, hostTimeBEuint64+8, rateScalarBEdouble+16, wordClock+24, SMPTE+32, flagsBEuint32+56, reserved+60. Retain raw64byte copies and flags; interpret only fields whose validity flags are set. Reject nonfinite valid sampleTime/rateScalar and unsupported partial/torn reads. NOW and outputTS are distinct roles; input pointers may legitimately be null in an output-only device and must not become mandatory false-failure gates.

Retain guest mach timebase from the same owned guest. Guest timestamp hostTime/sampleTime and host CLOCK_MONOTONIC entry clocks are different domains. Do not subtract them without a validated conversion/relationship. Converted guesthostTime NOW→outputTS lead and sampleTime deltas can describe the guest contract; positive lead alone still does not prove timely downstreamDMA fill.

OnPPC32 AudioBufferList has u32count then12-byte buffer scalars(channelcount,dataByteSize,datapointer). Confirm guest ABI offsets explicitly, bound count before reading exact scalar extent, and retain pointers without following PCM payload. Null/nonzero and completeextent gates remain separate from format. Byte count divided by4/8 is not a proven frame count without fresh same-run HAL streamformat; CoreAudio float/interleaved/planar representation differs from S16DMA. Do not assume one2channelbuffer or claim zero output from scalar metadata alone.

Timestamp/ABL pointer provenance comes from the freshly validated actual IOProc entry arguments. Bound each exact span in current ordinary data mappings; do not scan memory or promote DATA bytes to execute permission. Stable reread of headers/flags is useful to reject torn observations. Preserve explicit capture-read errors/drops and stoppedflush.

## Pairing with Miles

Only entry/return scopes that pass originalSP/LR/client identity and complete coverage should contain nested Miles events. A scope gap/edge excludes its timings; matching audio source must remain independently qualified. Cross-CPU events require monotonic ordering or explicit per-CPU append ordinals for equal sameCPU timestamps; equal crossCPU timestamps stay ambiguous.

Record existing callback arrival, NOW/outputTS sampleTime/hostTime and bounded ABL scalarstate; do not add another HAL client, change deviceperiod, write PCM or synchronously log per event. Preallocated bounded memory and stoppedflush remain mandatory. Observer-off source-quality controls remain required before promoting any causal or playback claim.

This next observer can show actual dispatch cadence and timestamp/deadline relationships of the already existing client. It does not by itself close HWstate→CarbonSound ownership, kernelDMA clipping/deadline or guestclock causality. No new boot or production change was made for this review.
