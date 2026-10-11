# Existing SoundManager IOProc observer: independent static review

Read-only review of `/tmp/pe9800/oct10-sm-ioproc-plugin.c`, Control368/Rec320, against pinned actual Tiger frameworks. No launch, guest reads or production changes.

## Timestamp ownership and true return

Stack-only timestamp bounds are supported for the pinned HP WorkLoop path. WorkLoop91468684 (`3b610080`) sets r27=its frame+0x80;91468924 movesr27 into r4 and9146892c calls PerformIO9146a70c. PerformIO9146a71c preserves that NOW pointer into r25. Its local input/output timestamp objects are frame+0x40 and frame+0x80 (9146a73c,9146a814). At9146a900..9146a91c it calls the device dispatch with r4NOW=r25, r5inputTS=r27, r6outputTS=r28. CallIOProcs preserves NOWr22, inputTSr26 and outputTSr23 and forwards those into HP_IOProc::Call. The callback tail at9146b83c..9146b84c emits r4NOW/r6inputTS/r8outputTS, with r7outputABL and r9refCon. These are pointers, not embedded timestamp values or frame counts. No heap timestamp extension is justified by this actual path.

For this exact Core return path, CallIOProcs9146ac00 explicitly sets HP_Call argumentr8=0 (opcode39000000). HP_Call savedr28 is therefore null; its fallback obtains outputABL at current record+0xa0 (9146b7f0, then9146b80c after construction) and outgoingr7 is thatr29 at9146b848. The exact published record+0xa0 identity is justified for this path, without assuming it for every IOProc caller. Publish only its freshly re-read current value; keep first unsupported pointer tuples as unscored evidence.

The wrapper's true return is SoundManagerComponents relative0x57e4, opcode4e800020 (blr), after0x57d4 restores the entry SP and0x57e0 restores the saved Core LR. Instrumenting before57e4 therefore sees the original entry SP and Core returnLR. The initial instruction relative5794 is7c6802a6 (mflrr3); before its execution r3 still carries deviceID. The returnedr3 is0 and must not be used as the entry deviceID.

The source's register indexing agrees: r[3]=r4NOW, r[6]=r7ABL, r[7]=r8outputTS, r[8]=r9HW. Source has no frameworkTOC gate, correctly. Match by originalSP+CoreLR in a shared bounded table supports CPU migration; duplicate active keys and unmatched/unfinished returns must reject attribution. Return does not snapshot caller-clobbered timestamp arguments again.

## Scope and rejection requirements

The source performs no register or guest memory reads before immutable publication or outside the armed window. It preallocates320×8192records, reads only two64byte timestamps, at most100ABL scalar bytes and16context anchor bytes; it never follows AudioBuffer data pointers. Nonblocking serialization drops rather than blocks under concurrent hooks. Complete attribution requires zero drops/guard/errors/read/bounds/torn/pair errors, complete entry/return pairs, final immutable config and flush receipts. Site word errors may include unrelated pretranslated contexts; they are conservative rejection, not evidence of guest malfunction.

Fresh setup must verify current modules/wholecode, actual registered record/refCon/deviceID/bridge, current record+0xa0 ABL pointer and its bounded readable mapping, actual Stack extents, fresh Miles anchor bytes in the executing process context, actual Tiger64byte AudioTimeStamp ABI and guest timebase. Historical addresses from279 are not publication inputs. A code anchor is context evidence, not an OS PID certificate; keep one current Warcraft process under owned setup and reject competing same-image instances.

Stack-only bounds should first retain a bounded nonempty runtime record before any scheduling inference. A bounds failure remains unsupported provenance, not permission to accept arbitrary heap pointers. Runtime byte visibility and pairing need the device agent's actual PPC fixture, then one unscored current owned setup. Neither those fixtures nor this review prove timestamp correctness, a missing callback, scheduling cause or an audio improvement. Paired Miles/raw/host source qualification and recorder-off overhead control remain necessary for quality claims.
