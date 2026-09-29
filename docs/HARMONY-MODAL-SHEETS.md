# Modal sheets and Save dialogs

## Report

Microsoft Word 2004's Save dialog became hidden behind its document in Harmony. Exiting Harmony revealed the dialog above the document and allowed saving. No document was modified during this investigation.

## Findings

- The complete-capture path publishes each proxy independently with `orderFront`. It does not attach sheets to parent document proxies.
- `proxyRaise` raises a document proxy even when the guest may have a modal dialog blocking that document.
- Periodic guest focus changes deliberately do not restack host windows. That preserves host/guest interleaving, but does not enforce sheet ownership.
- `PEFindAXWindow` searches application-level AXWindows only. It does not descend into document sheets.
- `confirmFocus` requires equality with the application's AXFocusedWindow. That is insufficient for sheets represented as child accessibility elements while the document remains the focused window.
- The live trace contains repeated `PEFOCUS failed id=324` messages while Word was open. It does not include role/parent information, so the exact representation of Word's Save dialog is not yet proven.

## Required fix

1. Inspect Word's Save dialog accessibility role, parent, modal state, bounds, and CGS window ID in an isolated Office guest. Distinguish attached sheets, standalone modal dialogs, and floating palettes; do not infer modality from size or overlap.
2. Report explicit guest child/parent window relationships separately from ordinary window ordering. Resolve child AX elements with bounded traversal and invalidate relationships when either window disappears, the agent reconnects, or Harmony exits.
3. Attach a sheet proxy above its document proxy using native NSWindow child-window ordering. Do not use a globally elevated window level.
4. Route activation of a blocked document to its modal child. Prevent queued document clicks from reaching the guest while its sheet is active. Do not replay that click into the dialog.
5. Extend focus confirmation to correctly resolved sheet elements and their owning focused document. Preserve strict checks for ordinary windows rather than accepting any focused window in the same app.
6. On dismissal, remove the attachment and restore appropriate document focus without raising unrelated guest applications or host windows.

## Acceptance checks

Use a disposable Word document. Exercise Save As, Cancel, overwrite confirmation, and repeated reopen; click the parent while the sheet is open; switch between host and guest apps; test a second Word document and other guest windows. Verify visual ordering, keyboard destination, and that a blocked parent click never activates a dialog button. Repeat with a Cocoa sheet and an application-modal dialog. Verify both initial frame arrival orders, relationship removal, and reconnect/exit cleanup.

Status: a sheet-specific candidate is implemented below; Office 2004 acceptance remains open. The no-Finder-restart experiment is separate from this defect.

## Implemented candidate: Tools 2.17 (2026-09-29)

The isolated Mac Studio Leopard 10.5.8 test confirmed that Cocoa exposes the
save panel as an `AXSheet` in the document's `AXChildren`; `AXSheets` is absent.
A probe run directly through SSH cannot query that GUI process (`-25204`);
launching the probe as an application in the guest desktop session succeeds.

- `PESheets.inc` follows explicit sheet relationships, matching each element to
  a unique same-owner CGS window by bounds. Ambiguous matches are ignored.
- `SHEETS` reports child/parent IDs separately from ordinary window order.
  One background query runs at a time, so this discovery does not block the
  guest input/report loop. Transition/disconnect generations discard old results.
- The host rejects cyclic/deep relationships, attaches painted child proxies
  with native `addChildWindow(..., ordered: .above)`, and leaves window levels
  unchanged. Missing/minimized proxies detach; exit/disconnect clears links.
- Activating a blocked document selects its sheet. Parent pointer gestures and
  queued content clicks are discarded rather than replayed into the sheet.
  Sheet pixels do not acquire the document's synthetic draggable title bar.
- Guest focus lookup includes sheet children. A sheet can confirm focus through
  its owning focused document; a document with a sheet cannot confirm a queued
  document click as safe.

### Live evidence

See `evidence/harmony-modal-sheets-2026-09-29/`. The disposable Cocoa fixture
uses no user document and cancels saves. The guest tools and host release build
compile successfully. Live checks have confirmed:

- Explicit sheet identity and parent (`72 -> 70`, subsequently `102 -> 100`).
- Native host child attachment and sheet-before-document stacking.
- Raising the parent redirects to the sheet.
- Two Cancel/reopen cycles remove/recreate sheet proxies while retaining the
  same document proxy.
- Agent replacement/reconnection restores sheet relationships.
- Harmony exit clears all proxies; re-entry reattaches the still-open sheet.
- Packaged application passes strict code-signature verification.

The test app is `build/Harmony Sheets Test/PowerEmu.app`, with Tools 2.17.
It is a candidate, not an alpha release sign-off. The user's running MacBook
Air app is not replaced automatically.

### Remaining acceptance work

Office 2004 is not installed in this isolated Leopard guest. Its actual Save As
and overwrite dialogs still require a disposable Word document test. Generic
application-modal dialogs and palettes are not inferred from overlapping
rectangles; this patch handles explicit sheet relationships. Host application
switching, physical keyboard input, and screenshot-level appearance still need
interactive verification. Leopard also exposes a separate narrow decorative
sheet window; it remains an independent proxy and should be inspected visually.

For the fixture, launch `guest/tools/pesheetfixture.m` as a Cocoa app in the guest
GUI session. Its control file `/tmp/pesheet-command` accepts `cancel` and `open`.
The probe reads a PID from `/tmp/pesheet-target` and writes
`/tmp/pesheet-probe.log`; launch it as an app, not directly from SSH.
