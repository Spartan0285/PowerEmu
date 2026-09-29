# Harmony changed-tile refresh candidate

September 28, 2026. Candidate: `build/Harmony Tile Refresh/PowerEmu.app`. Requires guest **Tools 2.12** to use tile packets. Older tools continue using independent images. The adaptive scheduler, off-main-thread decoder and exclusive-fullscreen handoff remain included.

## Implementation

The guest still captures the entire window's backing store. For a changed detailed image with an acknowledged matching base, it compares canonical 32 × 32 tiles and compresses only changed tiles. Right and bottom tiles are clipped to the actual image dimensions.

The host explicitly negotiates `rle32 tiles32`. Encoding 4 contains a big-endian uncompressed-stream length and a zlib stream. That stream contains the base sequence, changed-tile count, and strictly ascending tile indices followed by each tile's RGBA bytes. Headers retain the existing window ID, dimensions and request sequence.

The host retains the exact immutable base image while its serial decode worker reconstructs a separate complete image. It checks window identity, base sequence, dimensions, tile ordering, counts, lengths and complete compressed/uncompressed payload consumption. The main thread rechecks the current proxy, request and accepted base before publication. Missing or invalid bases keep the last good image visible and reset acknowledgment so the next request gets an independent image. There is still only one request/decode in flight.

## Bounded cost and fallback

- Missing acknowledgment, stale sequence, resize or evicted cache entry: full image.
- Unchanged pixels: existing header-only response after exact comparison.
- Flat UI content: existing fast pixel-packet codec, bypassing tiles.
- Broadly changing detailed content: a 64-sample preflight rejects dense changes. This is only a performance heuristic; it never establishes pixel equality.
- Remaining candidates: tile collection has a raw-byte budget of one eighth of the image. Exceeding that budget aborts to the existing full-image codec. Compressed tile packets must also fit the budget.
- Unknown capability or older host: no tile packets.

This optimization reduces encoding, transfer and host decoding work for sparse changes in detailed images. It does **not** avoid the guest capture API, guarantee a frame rate, or eliminate every latency source. The byte budget does not guarantee a tile packet will be smaller than the hypothetical compressed full image for every possible image; comparing both encodings would itself add compression cost.

## Verification

`guest/tools/petilecheck.c` exercises 120 varied dimensions, edge tiles, unchanged input, absent bases and buffer-capacity guards. Native checks use address/undefined-behavior sanitizers. PowerPC-produced fixtures are decoded on the host and compared byte-for-byte. Swift checks reject missing/stale/wrong-window bases, resizes, truncated data, extra data, out-of-bounds/duplicate tiles and invalid counts. Base image bytes must remain unchanged.

`guest/tools/petilecapturecheck.m` runs the actual agent's capture and encoding methods against its own test window in the isolated Tiger 10.4.11 guest. It emits triples of an independent base, candidate update and full reference image. `app/Tests/Harmony/TileCapture.swift` verifies exact reconstructed pixels and immutable bases, including dense changes, resize, stale-base and legacy-negotiation fallbacks.

A deliberately detailed/noisy 640 × 480 test image with a 12 × 10 changing patch produced approximately **6.8 KB** tile packets versus **1.06 MB** independent images. The final run had median guest capture/encoding times of **36.68 ms** versus **128.55 ms** for an independent image. Host decode medians were **0.113 ms** versus **2.123 ms**. Raw final-run results and summary are retained in `docs/evidence/harmony-tiles-2026-09-28/`.

These are controlled test-window measurements designed to exercise sparse updates, not general application benchmarks or end-to-end wire measurements. Candidate capture precedes full-reference capture, and both run within one diagnostic process. The test's content is less compressible than most Finder windows; typical gains will vary. Dense updates still use complete images.

The production build and deep/strict signature verification pass. The bundled Tools 2.12 disc contains the exact compiled guest agent. Existing independent-image/geometry regressions (including 600 pixel-packet fixtures), transport, scheduling and interaction checks pass. The new feature still needs normal interactive testing of scrolling, dragging, overlapping guest/host windows, minimizing/restoring and application content changes.

## Try it

Finish the current VM session, open the Tile Refresh candidate, and install its bundled Tools 2.12. Check images/text with small local updates, then scrolling and resizing, which should fall back smoothly. Verify no stale pixels remain after switching between windows or restoring from the Dock. Return to the previous Adaptive Refresh candidate if there is a regression; it does not request tile packets even with Tools 2.12 installed.
