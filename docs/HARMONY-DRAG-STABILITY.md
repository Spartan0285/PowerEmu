# Harmony Finder drag stability — Tools 2.18 candidate

The user reported that holding a Finder file drag in Harmony dropped the item
within one or two seconds, preventing guest-to-host drag testing.

## Confirmed cause and changes

A disposable Tiger 10.4.11 probe held a drag for six seconds. Finder created a
separate CGS window at `kCGDraggingWindowLevelKey` (500). That image became the
frontmost CGS window while the AX-focused window remained the Finder folder.
The old agent reported the image as `FOCUSED`. On its first captured frame,
the host could make its proxy key, causing the source proxy's resign-key
handler to cancel the gesture and release the guest mouse button. The image
could also cover the pointer in host hit testing, preventing drag export.

- Tools 2.18 sends `DRAGWINDOWS` before each `WINDOWS` report and excludes these
  image windows from `FOCUSED`. Classification uses the system drag window
  level, not dimensions or overlap.
- The host still displays drag images, but makes their proxies mouse-transparent
  and ineligible for key/main status or explicit activation.
- Guest-target hit testing looks through these images to the underlying host
  or guest window, allowing a drag to leave the guest.
- First-frame delivery cannot take key focus while a physical or tracked
  pointer gesture is active. This also protects older tools during a drag.
- A late export-preparation callback is checked against its gesture generation
  before releasing the guest button or changing drag state. An obsolete reply
  cannot cancel a newer press.
- Debug logs record focus loss and forced button releases for any residual issue.

## Verification

Evidence: `docs/evidence/harmony-drag-stability-2026-09-29/`.

- Tiger: six-second controlled Finder drag; image level 500 while document AX
  focus remains unchanged.
- Tiger with Tools 2.18: real control stream classifies the image, never reports
  it as focused, and clears its classification after explicit release.
- Tiger native save sheet: correct AXSheet identity/parent and dismissal.
  Fixture reopen did not produce a new sheet; repeated Tiger reopen and Word
  2004 remain interactive acceptance work, not claimed as passing.
- Leopard with the packaged host and Tools 2.18: drag image remains visible
  during the six-second probe and receives no guest focus request.
- Host transport regression: classification arrives before geometry, malformed
  IDs are ignored, empty reports clear the set, and reconnection still passes.
- Production file-promise delegates: receiver-selected filenames, serialized
  exports, byte-for-byte output, and active/queued disconnect completion pass.
  This uses a simulated guest endpoint; it is not a physical Finder drop test.

Build: `build/Harmony Drag Stability/PowerEmu.app`, bundled Tools **2.18**.
Both the host build and guest tools must be updated for complete classification.
The running user VM is not replaced during testing.

## User acceptance

Use disposable files. Hold a guest Finder drag within the folder for at least
10 seconds, cross another guest Finder window, then drag to host Finder and
the host desktop. Verify the copied bytes and that the source remains intact.
Cancel one outgoing drag, start another immediately, and verify the delayed
first request cannot release the second drag. Recheck host-to-guest copying.
