# Verified Miles sample provenance and smallest cursor diagnostic

## Actual copied code establishes the handle layout

At verified `SS_fill` entry, r3 is saved as driver r31. Instructions5903b8–5903f0 load array base from driver+0x40, add a loop byte offset, require sample status at +0x08 equal4, pass that exact address in r3 to SS_stream_to_buffer, increment byte offset by608 (0x260), and bound iteration by driver+0x34 sample count. This is an inline SAMPLE array, not an array of sample pointers:

`handle(i) = *(driver+0x40) + 608*i`, `0 <= i < *(driver+0x34)`.

Both SS_stream_to_buffer and SS_merge load sample+0x04 as the parent driver. At590c4c–590c64, SS_merge reads current index at +0x40, shifts by2, reads source base at +0x0c+4*index and position at +0x1c+4*index, then adds them for the source cursor. SS_stream_to_buffer reads length at +0x14+4*index, subtracts the corresponding position and limits the span. For a two-buffer sample, the alternate index is selected with XOR1 at5908ac–5908f8. The independently extracted AIL_sample_position getter corroborates the position address. Therefore positions in this merge branch are byte offsets, not hardware output-frame counts.

Fields to retain per candidate sample: handle; parent_driver+0x04; status+0x08; source bases+0x0c/+0x10; lengths+0x14/+0x18; positions+0x1c/+0x20; current index+0x40; two-buffer mode+0x74; flags+0x58; rate+0x60. Native PCM without an ASI/filter branch is the simplest diagnostic source. A source pointer does not by itself establish the speech asset: compare a bounded read of its bytes with the exact imported written WAV payload (allowing the actually observed format), before attributing it to the fixture.

## Existing trace limitation

The35463 event file has2204 callback entries with r3=0x190c240 and17632 fill entries with r3=0x1907240. There are no entry records for stream-to-buffer or merge. r3 in those two recorded sites is callback context/driver, not HSAMPLE. The recorded r4–r6 are site arguments and must not be renamed source fields. A current driver contract from50526 belongs to another process and cannot identify35463 handles retroactively.

## Strict snapshot gates

1. Same owned emulator, guest PID and current mapping verified against copied code and live TVector; reject an old manifest after process restart.
2. Driver pointer comes from actual fill r3 and matches the separately walked current driver node. Read exact header bytes; verify count/base are readable and stable over the snapshot. Check count against an explicit diagnostic bound (e.g.128 samples), multiplication/addition overflow and 32-bit user-address bounds. Do not follow an unbounded pointer chain.
3. Read at most count*608 contiguous bytes (35 samples in50526 would be21280 bytes); derive handles arithmetically. Require sampled handle+0x04 equals the driver, status is the actually accepted value4 for active mixing, current index0/1 for the proven two-buffer branch, and selected position<=selected length. Capture inactive slots for validation only, not source-loss claims.
4. Validate sourcebase+length against readable guest mappings and overflow. Read only a small known-source payload slice. Re-read driver count/base and selected sample metadata; reject mixed/torn snapshots if identity/index/length changes during the read. Position changing during an asynchronous snapshot is expected and cannot become a deadline measurement.
5. A one-time snapshot proves structure/source identity only. Cursor change through a zero island needs records tied to actual stream/merge execution and destination-chunk identity. Different CPUs can alter fields; include guest process/address-space identity, TOC, monotonic timestamp, verified site/word, handle, call pairing and read failures. Zero-capacity/overflow/mismatch gates reject the run.

## Smallest decisive observation

Use only the native PCM fixture and one source-qualified active handle. At stream/merge entry and verified return, record the selected index, both source positions, lengths/status, plus source handle and actual destination region/chunk count established from fill. Retain a tiny PCM slice or checksum of the resulting chunk before it is queued. This produces three distinct outcomes:

- No stream/merge call for the source while output contains zero: upstream callback/feed omission.
- Call occurs but source position stalls and output remains zero: sample-source availability or branch termination; inspect status/length/index at that event.
- Source position advances and the produced chunk is good, but consumed DMA is zero: downstream buffer ownership/queue/overwrite.
- Source position advances while produced chunk is already zero: mixing/format/source-read path.

A generic late callback interval or one snapshot cannot discriminate these cases. Preserve bounded recording and stop-time flush; no added HAL client, function calls, synchronous logging or global timestamp patch is needed.

Read-only artifact; no guest operations, build, VM launch or production edits.
