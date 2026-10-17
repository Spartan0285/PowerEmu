# Unintended host drop and Office palettes — October 16

User priority: a host desktop folder dragged/released back on host desktop unexpectedly copied into guest, possibly after passing over Harmony. Exact path not reproduced. Secondary: Office formatting palettes lose their moved position and do not remain floating above their document as in normal guest mode.

Test11 host87758/backend87785 running at initial inventory. Left both untouched; no CUA/guest changes/second emulator. Requested shutdown before isolated live work. Preserve Test10/Test11.

## Drop candidate (unshipped)

Production HarmonyProxyView previously accepted file/promise types at entry and performed import without checking current release location, target identity, destination visibility, active Harmony state, current drag/session or frontmost host window. It also raised the proxy before inspecting import payload. This is a concrete missing validation, not proof of the user's exact event sequence.

Added HarmonyDropIntent, binding drag sequence to Harmony epoch, invalidated on exit/end and consumed once. Entry/update/prepare/commit all validate live registered proxy, current ordered guest window, destination-window identity, visible/nonminimized content, non-menu/non-drag-image, source copy support, local visible bounds and frontmost host hit-tested window at the supplied drop point. Epoch rotates on setActive. Import and raising occur only after validation and supported payload parsing. Ordinary file and promised-file callbacks unchanged. No transfer on hover.

Regression tests cover release without entry, leave/release, outside release without exit callback, Harmony reentry, mismatched drag, preparation, intentional one-shot import and deliberate leave/reenter. Source tests/HarmonyDropIntent/main.swift; result build/harmony-drop-2026-10-16/drop-intent-check.log. Full release compilation PASS (51.77 seconds), actual output app/.build/out/Products/Release. Log build/harmony-drop-2026-10-16/release-build.log; existing Swift concurrency warnings remain. No signed user candidate yet; current release output also contains prior unshipped host owner draft, so do not package blindly.

Live gate: real harmless host folder, remain on host desktop; hover guest then release host; hover/leave/reenter and deliberate guest drop; Escape cancel; covered/minimized/closed target; promise drop; Harmony exit/reentry. Confirm no destination/staging work for rejected drops and exactly one intended transfer. Topmost hit testing during real AppKit drag must be qualified, since drag-image window handling is not proven by pure policy tests. Do not stop user VM without shutdown response.

## Palette investigation (no patch yet)

Guest reportWindows queries CGS level to filter desktop/Dock/menu and classify drag images, but WINDOW geometry does not transmit floating class. HarmonyProxy initialization sets every proxy to .normal, so floating relationship cannot be represented by that path. Do not fix by making every proxy globally floating: palettes must remain associated with their owning guest app and not cover unrelated host apps.

Host position follows guest geometry; pendingMove clears after1.5seconds and snaps to hostFrame(guestRect). Guest MOVEWINDOW uses matching AX window then AXPosition set; failure/no-match produces LOG. Need actual palette MOVEWINDOW result and owner/window classification before changing persistence. Do not guess palette from title/shape or keep an unsupported host-only coordinate that breaks click mapping. Alpha capture/decoder already uses premultiplied RGBA; no evidence yet of the user's precise transparency expectation or lost per-window opacity.

No commits, pushes, releases or bundle mutations. Resume priority with drop live checks once user closes VM, then owner-scoped palette behavior.


## Owned90907 live check after user shutdown

Inventory confirmed user Test11 host/VM stopped. Internal-only current host candidate built/signed, baseline internal host/Info saved. Test11 guest Agent0c8b476707163d57a0e55e2a4d0ddd8c temporarily installed, exact flags verified; one-display private clone under480second guard. HARMONYREADY true and real Finder navigation/window movement passed.

CUA file drags from harmless host-fixture/Drop-Sentinel generated no destination PEDROP events; independent native Finder-to-Desktop-sidebar control also did not move the folder. No guest sentinel copied. These attempts are UNQUALIFIED, not evidence the guard rejected a real drag. Do not repeat the same cross-window coordinates blindly or present as live validation. File drag source delivery must first be established. Policy regressions/build pass; actual AppKit drop/topmost test still outstanding.

Useful separate palette reproduction: CUA Word265 Formatting Palette74 drag700,58→850,158 then850,158→950,208, both MOVEWINDOW AX result0. After CUA Harmony exit/reentry (HARMONYREADY true), next small drag reports original700,58→710,68. Position reset across transition is reproduced, not failure to move initially. Timing of reset relative to resolution restoration/PREPARE remains unmeasured; do not attribute root cause yet. Floating-level transfer gap remains static finding; actual palette CGS level/owner snapshot still needed.

Stopped before guard; original Agent/Info verified restored, exact private two-display config restored, saved internal host/Info restored and strict signature passes. Final inventory clear. Test10/Test11 untouched, no original disk accessed. Receipts/log live-90907-receipt.json and live-90907.log. No new user build ready; current host also includes unshipped menu-owner draft, which must remain excluded from a scoped shipping candidate. User shutdown is now confirmed; next bounded owned run does not need another shutdown request if inventory stays clear.


## Test 12 — actual native drop and owned96419 transfer qualified

Shared `harmonyDropHitsView` now implements AppKit destination/window/bounds/topmost validation for both the real proxy and a harmless native source/target fixture. Two CUA deliberate file drags in that fixture produced entered/prepare/commit and visibly incremented its count; a release outside its target produced operation0. Fixture source/log: build/harmony-drop-2026-10-16/native-drag/. The first launch's drag was unqualified (no target events); later qualifying evidence is retained separately in append-order log. No fixture commits copy data.

Owned96419 exact scoped host removes the prior unshipped menu-focus owner draft, uses Test11 guest payload, independent clone and480second guard. CUA native source → actual Harmony Finder home window61 produced PEDROP entered+accepted drag16. Guest /Users/adam/readme.txt MD5 matches harmless source38d923f64ff6470ab28d54a5c1dee5e3. Next CUA drag17 entered the same proxy but released beyond its right edge: native operation0, no PEDROP accepted and no second transfer. This qualifies deliberate file import and entered-then-release-outside handling, not the exact original user desktop gesture or promised-file delivery. Existing sequence/epoch/single-consumption regressions pass. Do not add NSEvent.mouseLocation validation: CUA's targeted event position and global hardware pointer differ, as retained event logs demonstrate.

Signed separate build: `build/staging-hourly/PowerEmu Harmony Drop Safety Test 12.app`. Exact path in test12-receipt.json. Host release build/strict deep signature PASS. Tools ISO unchanged byte-for-byte from Test11; no new Guest Tools required for this host-only guard if Test11 Tools are installed. Test10/Test11 untouched. No release/commit/push.

## Palette diagnosis from96419 — still unresolved, do not ship guessed fix

Actual palette75 moves700,58→900,158 (AX0). Exit-only15second CGS trace preserves900,158. Display after exit already1728×1074. Initial combined trace resets after reentry. A six-line candidate skipping redundant setMode built on trusted PPC compiler and was temporarily installed; after reentry and Word refocus palette still reset700,58. Candidate removed from source and NOT in Test12. This does not prove display switching caused reset; likely app activation/internal palette state needs next controlled comparison.

Important correction: actual Formatting Palette75 reports **CGS level0**, as does Word document73. Generic above-normal-level classification would miss it. Read-only process-manager/connection proof maps Word271 to41991; both palette/document belong to this connection. The older pemenutrace helper's CGSConnectionGetPID call returned its own PID286; its PID field is invalid for ownership and was not used. Its id/rect/level fields were independently checked. New paletteprobe uses established PSN→CGSConnection mapping, but direct SSH AX calls return-25204. Next inspect explicit AX subrole in the installed Agent's existing matched-window path (or an actual GUI-session helper), not title/shape/level guesses. No owner-scoped floating or persistence patch yet. Do not cache only host coordinates because input must remain aligned with actual guest geometry.

All owned96419 stopped beforeguard; originalAgent/Info hashes verified restored, original internal host/Info and exact two-display config restored+strictsigned. NativeDropCheck stopped. No user/original disk touched. Evidence palette-96419.json, palette-exit-96419.json, palette-owner-96419.log, palette-candidate-96419.log, live-96419.log and test12-receipt.json. Pause autonomous VM/GUI work while user tests Test12; offline palette work can continue.


## Offline follow-up16:54Z — next bounded classification probe prepared

No VM/GUI/installed-Agent changes while user verifies Test12. Separate diagnostic Agent copy in build/harmony-drop-2026-10-16/palette-diagnostic compiles on trusted PPC host with10.4uSDK. Default-off PE_PALETTE_MOVE_DIAGNOSTIC adds up to16 observations only to an existing resolved MOVEWINDOW: verified PSN/CGS owner, AX role/subrole/errors, pre/post owner+geometry stability and level. No title capture, new window enumeration, floating guess or production behavior change. README and binary receipt retained. This is diagnostic preparation, not a palette fix or new user build; actual Tiger runtime remains untested. Test12 executable/ISO hashes remain exact.

Next controlled sequence separates app activation (Finder→Word without Harmony exit), Harmony transitions, and native guest title dragging versus AX-only movement. Prior mode-skip trial also restarted Agent, so do not attribute its failure exclusively to Word activation. Classification requires successful stable current-owner AX rows; generic AXWindow/unknown is not permission to infer a palette. Do not add query work to periodic reporting/main control path in shipping code. Preserve existing pause on autonomous VM/GUI while user tests.


## Owned3085 — explicit palette identity and activation-only reset

After the user requested continued palette work, inventory was clear. Bounded owned clone3085 used exact Test12 host and temporary diagnostic Agent; no original disk accessed. Actual Word253 palette74: role AXWindow/subrole AXFloatingWindow, all query errors0, verified owner/stable geometry, CGS level0. Harmony drag700,58→900,158 returned AX0. CUA switched Word→Finder→Word without Harmony exit or Agent restart; subsequent small drag reported700,58→710,68. Thus activation alone reproduces the reset. Office internal position bookkeeping is a hypothesis, not yet proven. Native guest title-drag attempt after exiting Harmony did not visibly move the window and is unqualified; do not repeat those coordinates blindly or call it a comparison.

Original Agent/Info hashes verified restored, owned3085 stopped before480sec, exact internal host/Info/private two-display configuration restored and strict signature passed. Evidence palette-live/live-3085.log. Inventory clear.

Default-off floating candidate added: guest PE_PALETTE_CLASSIFY=1 extends the existing single bounded sheet worker with explicit AXFloatingWindow/owner/geometry validation; same session epoch gates publication. Host POWEREMU_HARMONY_PALETTES=1 accepts explicit owner pairs and selects a same-owner visible document, excluding sheets/menus/drag images/minimized/vanished windows. Relative ordering only, no global floating level, no child-window attachment or automatic relative movement, no modal/input redirection. Only active Harmony with the matching key-window owner can reorder. Disconnect/session exit clears classification. Pure policy tests and existing drop-intent tests PASS. PPC10.4u build PASS (existing send:text warning); full host release build PASS32.06sec after channel-forwarding correction. Actual SwiftPM output app/.build/out/Products/Release contains unrelated prior draft: do not package blindly. Candidate is NOT signed/staged/live-verified or enabled in Test12. Position persistence remains unresolved, so no palette user build ready.

Test12 executable/Tools ISO hashes reverified unchanged. Next: review candidate, scoped live floating checks (document click, palette movement, unrelated host app, sheets and app switching); obtain a qualified native guest title-move comparison before choosing persistence behavior. Preserve guest/host geometry alignment; no host-only cached position. No commits/push/releases.


## Owned8496 — scoped floating candidate and stronger move readback

Scoped host built from retained Test12 source plus palette changes (excludes owner draft), signed internal, temporary guest classify49a2fa2270f27ca912a025e328559b19 installed/verified. Private mouse setting seamless for attempted native comparison. Word264/current CGS connection23827 palette88/document86. Actual Harmony drag700,58→900,158 read back at CGS900,158 after setter AX0. Finder activation hides palette; returning Word restores700,58. Supports activation-associated reset with actual guest move, not merely setter status. Native desktop drag still did not move and remains unqualified even with seamless setting. Host paste navigation duplicated path; corrected via keyboard Finder m/down/down/open, then inner m/open. Do not blindly repeat paste.

Harmony exit/reentry continued frames; floating feature enabled but no independent host z-order receipt yet, so not qualified as fixed. All owned8496 stopped before480sec, original Agent/Info hashes and host/config restored/strict signature pass; user Test12 host left running untouched. Log palette-live2/live-8496.log. No new user build.

Next default-off POWEREMU_HARMONY_PALETTE_DRAG hypothesis forwards explicit palette title drags through existing guest pointer path rather than host-local AX move. Current classification/owner/session/drag/sheet gates; documents unchanged, no new synthetic global events or position cache. This is a candidate only and needs actual successful guest motion, release/cancellation, input alignment and activation persistence verification. Test12 drop policy unchanged. No commits/releases.


## Owned10562 — first qualified persistent native palette move

Scoped signed Test12+palette host with default-off native palette title gesture and classify Agent49a2fa2270f27ca912a025e328559b19. Fresh Word254/CGS41483 palette74/doc72. CUA title drag delivered PEEVENT74 and guest POINTER800,65 down→1000,165 up, no MOVEWINDOW. Actual CGS position changed700,58→900,158. Finder→Word, Harmony exit, and Harmony reentry each retained900,158; HARMONYREADY true/continued frames. This is the first successful actual-position persistence control; no host-only cache.

Repeat drag after reentry is UNQUALIFIED: CUA showed palette screenshot but actual PEEVENT targeted Finder29, producing1000,165→1100,215 and Finder activation; Word returned with palette still900,158. Do not label it a native palette drag failure or product focus regression. Need fresh target confirmation and repeated gesture/control-input/floating-order receipts before promotion. Relative floating remains unqualified without host order evidence. Added live-content/order/minimize/restore gates to default-off native gesture after run; not yet rebuilt/live-tested.

Original guest Agent/Info hashes restored and verified, owned10562 stopped before guard, exact internal executable/Info/private configuration restored; strict signature PASS. User Test12 host untouched. Retained palette-live3/live-10562.log and exact backups. Test12 drop code unchanged. No user build ready, no commit/push/release.


## Test13 — owned13821 repeated palette and relative-order checks

Fresh same scoped host with live-content/order/minimize/restore gates, exact classify Agent49a2fa2270f27ca912a025e328559b19/Info9da327ced58562e6247177144211f438. Word261/current owner41483, palette74/document72. Two CUA title drags explicitly logged PEEVENT74 and pointer down/up, no MOVEWINDOW, actual CGS700,58→800,108→900,158. Finder activation hid palette; Word return and Harmony exit/reentry retained900,158. Independent host CGWindow front-to-back receipt after Window→Document1 activation places palette74 before document72, both layer0. Finder-active receipt retained. Bold palette click produced visibly bold document text, showing control coordinates work after movement. CUA bulk typeText produced repeated characters and subsequent rapid key sequence showed bcd instead of exact abcd: no exact keyboard-string regression claim; do not use bulk text as input qualification. No transparency or every-Office-app claim.

All owned13821 stopped before480sec, original Agent/Info hashes verified restored, exact private config/internal executable/Info restored and strict signature PASS. User Test12 host untouched. Pure palette policy and drop intent regressions rerun. Signed separate `build/staging-hourly/PowerEmu Harmony Palette Test 13.app` ready for scoped user verification. Reinstall bundled Tools2.24 and restart Tiger. Mounted ISO binary/Info equal exact live payload and executable modes verified; initial staging caught missing execute bit, repaired before ISO creation. Staged host equals live-tested scoped host after signature removal and normalization of __LINKEDIT vmsize (one signing-allocation byte differed at3553); Test12 hashes unchanged. No commit/push/release. Existing Office Save/Cancel crash unresolved; unrelated owner draft excluded. Evidence palette-live4/receipt, order snapshots, after-exit/reentry and live-13821.log.

## Test13 — user-confirmed in Tiger

User tested `PowerEmu Harmony Palette Test 13.app` (host SHA256 `3f3eeade…f9a0d`, launched as PID40265) on their own Tiger VM after reinstalling its Tools 2.24 payload, and reported the Word palette behaviour "working well in Tiger". This is a user confirmation of the palette drag/persist/order flow, not of Leopard, other Office palettes, or the drop checks individually. Source defaults remain off and nothing is committed; the scoped host differs from production only by the unshipped menu-focus owner-PID check (HarmonyWindows/VMDisplay/HarmonyInteraction).

## Palettes made a normal-build default (uncommitted)

Following the user's Test13 confirmation, palettes are enabled the same way other validated Harmony settings are: `scripts/build-app.sh` LSEnvironment now sets `POWEREMU_HARMONY_PALETTES=1` and `POWEREMU_HARMONY_PALETTE_DRAG=1`; `scripts/release.sh` refuses a release missing either; `guest/Resources/Agent-Info.plist` sets `PE_PALETTE_CLASSIFY=1`. Code-level defaults stay off, so ad-hoc/dev launches without the plist keep the old behaviour.

Settings aligned with Test10–13 (user's choice): `build-app.sh` also sets host `POWEREMU_HARMONY_SKIP_OCCLUDED=1` and explicit `POWEREMU_HARMONY_INPUT_PRIORITY=0` (release.sh requires SKIP_OCCLUDED); `Agent-Info.plist` now has `PE_FOCUS_ASYNC=0` (was 1 in released 0.4.2) and `PE_FOCUS_LAZY_SHEETS=1`. Parsed host LSEnvironment and guest Info dicts are now exactly equal to Test13's.

Candidate `PowerEmu Harmony Palette Default Test 14.app` (staging-hourly; receipt `palette-default14/test14-receipt.json`): Test13 bundle, Tools ISO byte-identical to Test13 (`7e33ad45…`), host = production `app/` release build SHA256 `0f69bbcd…91e6` (= Test13 source + menu-focus owner-PID check), LSEnvironment read from build-app.sh. Signed, strict-verified. Not yet user-tested.

## Test14 — user-confirmed

User ran Default Test14 (PID54628) and reported it "working well". Two remaining user-reported bugs: (1) clicking the guest Finder tile in the host Dock with no Finder windows open does not open a new Finder window; (2) after exiting and re-entering Harmony, guest window z-order is not preserved.

## Test15 — Dock reopen and z-order on re-entry (built, not yet tested)

Dock: a guest-app Dock tile only ever sent ACTIVATE (SetFrontProcess); nothing sent 'rapp', so Finder with no windows just took the menu bar. Now when `activateApplication(pid)` finds no visible/minimized proxy, the host sends ACTIVATE then new `REOPEN <pid>`; the agent does SetFrontProcess + kAEReopenApplication (shared `SendProcessCoreEvent`, also used by QUITAPP). Older agents ignore REOPEN and keep the old behaviour.

Z-order: in complete-capture mode each proxy did `orderFront` on its first image, and the scheduler fetches first images front-most first, so re-entry came back reversed. Also the guest list groups windows per app (see zorder notes), so it cannot give cross-app order. Now: on leaving Harmony the host saves its proxy stack front-to-back with owner pids; on first paint a proxy is placed `.below` its nearest shown predecessor (or `.above` its nearest shown successor) in a stacking order = (windows not remembered, in guest order) + (remembered windows in saved order, owner pid still matching). `focusedGuestWindow` is reset on exit. Not verified live; owned tests were not run because the user is testing.

Candidate `PowerEmu Harmony Dock Order Test 15.app`: receipt `build/harmony-drop-2026-10-16/dock-zorder15/test15-receipt.json`; host `230a53f4…2c26`; ISO `2e7c0dc2…a509` built via `scripts/make-tools-disc.sh` from a G4 `guest/scripts/build.sh` build (prior guest/build backed up to /tmp/guest-build-backup-170706); mounted agent MD5 `8ab9dc0f…b29a`, Info equal to source plist. Requires Tools reinstall.

## Test15 — user-confirmed

User reports Test15 working (Finder Dock reopen and re-entry z-order). New bug reported: in Word 2004 in Harmony, after clicking in the Formatting Palette (font) and then into the document, the document sometimes stops refreshing and both palette and document stay stale until the user clicks another app's window and back to Word. User asks whether all Harmony windows can refresh live.

## Word stall diagnosed (Test15 debug run) — Test16 candidate

User reproduced with Test15 + POWEREMU_HARMONY_DEBUG=1 (log kept at `build/harmony-drop-2026-10-16/palette-focus16/stuck-test15.log`). While stuck: guest FOCUSED = palette 131 (199x268), document 129; log shows `PEFOCUS failed id=129` for each document click; document still captured 12–24 times per batch, so nothing was frozen in capture. Cause: after the palette's font field takes Word's focus, a click on the document sends FOCUSWINDOW 129; the agent only acknowledges when Word's AXFocusedWindow equals the target, which Word changes only after the click arrives; on failure the host drops the queued click, so Word never gets it — a loop broken only by switching apps.

Fix: guest `PEPaletteHoldsFocus` (PESheets.inc) acknowledges when the app's focused window is an AXFloatingWindow and the target is not, in both the async and legacy confirm paths; host `receiveFocus` replays queued events on failure when the focused guest window is a classified palette of the target's app (covers older agents, after their timeout). Not verified live.

Candidate `PowerEmu Harmony Palette Focus Test 16.app`: receipt `palette-focus16/test16-receipt.json`; host `c5429088…83c0`; ISO `29c69b07…dbf`; mounted agent MD5 `b2e10e79…17bc`. Requires Tools reinstall.

## Test16 feedback and Test17 candidate

User: Test16 refreshes better, but clicking the palette sometimes brings up the document behind it, and the palette's font drop-down sometimes doesn't show or appears behind the palette. Log (`palette-popup17/test16.log`): palette 55 / document 53; `PEFOCUS failed id=55` on palette clicks (a palette button never takes Word's AX focus — the reverse of the Test15 case); drop-down pop-ups 82, 84–94 became key host proxies and went through the focus handshake, which cannot succeed for a non-AX menu window. Also the Test15 re-entry placement applied to every new window, so a pop-up could be slotted behind the palette by the per-app-grouped guest order.

Test17: guest `PEPaletteSharesFocus` acknowledges when either the target or the focused window is an AXFloatingWindow; legacy confirmFocus acknowledges a target with no AX window owned by the front process (pop-ups/menus). The async focus path does not have the pop-up rule yet (PE_FOCUS_ASYNC is 0). Host: a click on a classified palette of the guest's current application skips the raise/handshake (orderFront only); the failure fallback replays when either side is a same-app palette; relative placement applies only to windows in the first list after entering Harmony, all later new windows `orderFront`. Not verified live. Receipt `palette-popup17/test17-receipt.json`; host `38fb5b87…95ac`; ISO `25d019f9…bfe4`; agent MD5 `9e0864ad…04b0`.

## Test17 feedback and Test18 candidate

User (Tools reinstalled): font drop-down still behind the palette in Word, PowerPoint and Excel (screenshot `palette-popup18/test17-dropdown-behind.png`, log `palette-popup18/test17.log`). Window dump while open: pop-up 158 (276x616) first in guest order with focus=1, palette 156 next, document 154 behind. Cause: `HarmonyPalettePolicy.parentRelationships` picked the first same-PID non-palette window in front-to-back order, which was the pop-up, so `reconcilePalettes` ordered the palette `.above` the pop-up. Fix (host only): the parent must be behind the palette in guest order (within-app order is reliable; palettes float over their documents; pop-ups open in front). Policy tests extended (pop-up in front; no document behind) and pass.

Test18 `PowerEmu Harmony Palette Popup Test 18.app`: host `76b9c99a…e465`, Tools ISO byte-identical to Test17 (`25d019f9…bfe4`), no reinstall needed. Receipt `palette-popup18/test18-receipt.json`. Not verified live.

## Test18 — drop-down fix accepted by user

User moved on to a final bug after Test18 ("one last bug to fix before we commit and release"), implicitly accepting the drop-down ordering fix. New report: when switching between apps/windows, especially into a Word document window, the host pointer does not change to the I-beam; it stays an arrow or stays stuck as another shape.

## Test19 candidate — cursor (host only)

Causes found in code: (1) in complete-capture mode only proxy mouse-moved events move the guest pointer, and AppKit sends those only to the key window, so hovering a document while its palette (or another proxy) was key never moved the guest pointer and Word never showed the I-beam; (2) `setGuestCursor` only invalidated cursor rects, which apply on the next move in the key window, so a shape change under a still pointer never showed; (3) `mouseExited` always set the arrow, and moving between overlapping proxies can deliver the new enter before the old exit. Fixes: tracking areas add `.mouseMoved` (moves deduplicated by event timestamp for the key window); `setGuestCursor` sets the cursor immediately when a proxy is under the pointer (`proxyUnderPointer`); `mouseExited` only falls back to the arrow when no proxy is under the pointer; forced captures from pointer moves only for the key window. Test19 `PowerEmu Harmony Cursor Test 19.app`: host `6c4e149d…68ecd`, Tools ISO byte-identical to Test17/18. Not verified live.

## Test19 feedback and Test20 candidate — cursor shape

User: Test19 host cursor is the wrong shape for the spot compared with Tiger outside Harmony; position is right (log confirms clicks map exactly). Findings: Tiger's card is `hw/display/ppc_mac_gpu.c` (patched ndrv HWC registers at BAR+0xFF00): ARGB image, X/Y are the image's top-left and `hot_x/hot_y` are always 0, so the real hot spot never reaches the host; the non-Harmony layer places the image by top-left and is right, but Harmony built `NSCursor(hotSpot: 0,0)`, offsetting e.g. the I-beam by its hot spot. Also Harmony ignored the SHOW bit (dpy_mouse_set visible=false), so a hidden pointer (typing, or a software cursor) kept the last hardware shape. Test20 (host only): hot spot derived as last sent guest point minus reported image top-left, accepted when two consecutive reports agree and it lies inside the image; hidden pointer over a proxy → `NSCursor.setHiddenUntilMouseMoves(true)`; `PECURSOR` define/hot/hidden debug lines. Not verified live. `PowerEmu Harmony Cursor Test 20.app` host `62853f4c…0ea6`, Tools ISO unchanged (`25d019f9…bfe4`). GPU-side cursor log: `PPCGPU_SEQ_LOG=1` → /tmp/gpu_seq.log (off by default).

## Test20 result and Test21 candidate — cursor from the agent

Test20 log (`cursor21/test20.log`): 95 card cursor defines, the hot spot derived only once (4,4) and then wrongly reused for later shapes; and Tiger's driver hides the hardware cursor around every shape upload, so Test20's "hide while hidden" rule blinked the host pointer on each change. Both Test20 mechanisms are removed.

Per the user's model (the host owns the pointer in Harmony, so the guest must tell it what Tiger's cursor is), Test21's agent polls `CGSCurrentCursorSeed()` on each Harmony window report (12–24 Hz) and on change reads `CGSGetGlobalCursorDataSize/CGSGetGlobalCursorData` (hot spot argument read as a CGRect, origin used), sending `CURSORIMG "w h hotx hoty rowBytes depth comps bpc\n"` + pixels when depth 32 / bpc 8 / hot spot inside the image; every change also sends a `LOG CURSOR …` diagnostic. Seed reset on Harmony entry. Host decodes big-endian premultiplied ARGB and, once an agent cursor arrives in the session, ignores the card's cursor for Harmony. The private-call signature could not be pre-verified: SSH to the user's guest and the G3 are not key-authorised here (no passwords tried); the agent links against Tiger's CoreGraphics. Test21 host `bb33de3b…e24f`, ISO `c2ff4161…cfc2`, agent MD5 `2d933349…2ab4`. Needs Tools reinstall.

## Test21/22 results and Test23 — inverting cursors

Test21: agent `CGSGetGlobalCursorData` works (ok=1 every change, real hot spots). User: TextEdit cursors correct in Harmony, Word's not. Test22 image dumps (`cursor23/test22-cursor-images`, log `cursor23/test22.log`): the card's images include TextEdit's ARGB I-beam (card-0077) but never Word's; the agent's Word cursors (16x16 hot (4,5) I-beam, (12,4) margin arrow, (3,4) …) decode with **zero alpha everywhere** — classic Mac inverting cursors, which the WindowServer stores as alpha 0 with non-zero colour. Neither the card nor NSCursor can invert, so Tiger draws them in software outside Harmony (correct there), and in Harmony they looked empty → arrow fallback. Test23 (host only): `HarmonyCursorImage.resolvingInvert` turns alpha-0/non-zero-colour pixels into opaque black with a 1-px white edge before building the CGImage; unit test `tests/HarmonyCursorInvert/main.swift` passes. Host `0c8a943e…f1cd7`, Tools ISO unchanged from Test21 (`c2ff4161…cfc2`). Not verified live.

## Test23 — user-confirmed

User: "Yes it worked!" — Word's inverting cursors (I-beam etc.) now show correctly in Harmony with Test23.
