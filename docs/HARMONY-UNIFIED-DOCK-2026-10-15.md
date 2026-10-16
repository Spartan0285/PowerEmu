# Unified Harmony Dock — October 15, 2026

## Result

The three representative modes have been replaced with one application identity per canonical VM package path and guest application path. Current signed review build: `build/staging-hourly/PowerEmu Harmony Dock Test 5.1.app`. Test 5 had a confirmed blank icon after helper exit and is superseded. The backend and Tools ISO are unchanged from Test 4.3; this is a Dock lifecycle change, not an audio or frame-rate claim.

Running guest apps appear automatically. macOS owns pinning and ordering. Closed apps do not need an always-running helper. The searchable Guest Applications browser has Open and Show Shortcut in Finder, without shortcut checkboxes or a second permanent-launcher flow.

## Native application contract

Each target is `~/Applications/PowerEmu Guest Apps/<stableID>/<Name>.app`. The distributed host and `GuestApplication.app` template remain Developer ID signed. The host verifies the template's Apple Developer ID anchor, expected Team ID and role before using it to create a local per-app launcher. Each generated launcher has a unique VM/app bundle identifier and a sealed ICNS resource, then receives a local ad-hoc signature. These generated launchers are created on the user's own Mac, not shipped as ad-hoc-signed downloads. No quarantine is removed and no system policy or library-validation setting is changed.

An owner-only receipt pins the generated application's executable URL, identity, source CDHash and generated CDHash. Static verification checks the completed app, and dynamic SecCode checks gate adoption and actions against the expected running executable. This supplements the session/owner/VM routing checks; distributed notifications are not an authenticated IPC transport against another process running as the same user. The generation pattern is informed by [Chromium's locally signed app shims and saved-CDHash validation](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/apps/app_shim/app_shim_manager_mac.cc) and Apple's [Sign to Run Locally distinction](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements). It does not claim Developer ID or notarization for each generated local app.

This supersedes Test 5's identical-template-copy approach. That approach kept a valid pin and launch target but provided no static artwork. A normal Finder custom-icon attempt was rejected because it failed strict signature verification. The per-app artwork is now incorporated before local signing; runtime session state and live artwork remain sibling data. A running bundle is not rewritten. The host briefly waits for the initial guest icon; late icon changes update the live representation and are incorporated into the sealed app once it has exited.

Representatives start through LaunchServices with exact-path substitution disabled. The per-target lease coalesces starts, while the native unique bundle identifier distinguishes applications. The stable filesystem path is preserved during the Test 5 to 5.1 upgrade, including the already pinned private Chess target.

A valid complete process snapshot determines runtime presence, including valid empty reports. Disconnection publishes unknown state rather than app exit. Guest Quit is graceful and waits for actual exit; a pending Save/Cancel does not cause helper respawn. Artwork updates leave the representative process and signed bundle intact. Cold launch waits for fresh Tools/application-list verification before opening the requested guest app.

## Verification retained

- Release host build and launcher parsing/install checks pass.
- Native lifecycle fixture passes: no launch on shortcut preparation, one icon per VM/app, multiple guest processes grouped, stale session/VM actions rejected, duplicate user launch coalesced, Quit/Cancel simulated, icon updates without restart, disconnect versus empty report, durable restart targets and two-VM isolation.
- Native Open Documents fixture passes against the signed application template, including exact scoped paths. Initial standalone Mach-O attempts failed native application routing and were rejected, not shipped.
- Native cold launch of the final Chess application target started only the independent cloned Tiger VM, opened one Chess process and entered Harmony. CUA verified the complete board. Harmony exit/re-entry retained the same representative PID and rendered the board again.
- A prior bare-executable trial was only a direct-execution test; it did not establish native Dock cold launch. The final application-bundle test replaces that evidence.
- Strict nested signatures pass for template, copied Chess target and user build. Packaged helper bytes equal the tested template. Final host executable instructions equal the live QA build; its signature changes for the separate user build identity. Backend/Tools bytes equal Test 4.3.

Evidence: `build/harmony-unified-dock/{runtime-check.log,native-open-evidence.txt,native-cold-launch.json,user-build.json,build-final.log}`. The source changes are in `GuestDock.swift`, `GuestAppLauncher.swift`, helper/main.swift and host process/browser routing. Existing dirty GPU, SMP, audio, cursor and capture work is preserved.

## Native pin verification

The user pinned Chess and confirmed, after the Test 5.1 correction, “Icon looks right and Chess opens.” Read-only Dock preferences retain the exact stable application URL across VM/host shutdown. Native cold opening that exact URL launched the independent VM and Chess in Harmony. The final recorded boot was initiated by the agent's native open; user confirmation establishes visible Dock artwork and successful opening, not an independently timed user-click boot trace. Drag/reorder remains unscored.

Old temporary/session-cache pins cannot become reliable merely by retaining their old URLs. Old standalone executable files are retained, while new native targets are application bundles; old pins may need replacement once. Physical movement of a VM package changes the path-based identity; editing the VM's display name does not.

No claim is made about complete Parallels parity, native Force Quit forwarding, every window-list behavior, or live Tiger Save/Cancel until separately exercised. Tools from Test 4.3 support this build; reinstalling Tools is not required for the Dock change.

## Cleanup

All live QA uses the independent cloned base and owned overlay with an absolute 480-second guard. The original Agent, Info.plist and login preferences were restored and verified after the earlier installer check. Final native cold launch exercised the Test 4.3 Tools installation. Afterward the guest Agent was stopped, original executable/Info/login preferences were restored and byte-verified, and the guest filesystem was synced. The exact private two-display config is restored and the owned QA VM/host are stopped; never change a running application bundle. The original user disk is not opened by these tests. No commit, push or release was made.

Final cleanup receipt: `build/harmony-unified-dock/guest-restoration.json`. The final native Keep in Dock request received no pin confirmation before the bounded run ended; read-only preferences showed zero test pins. Do not describe pin/reorder persistence as passed. The signed Test 5 package is ready for user verification of that remaining native interaction.

## Manual pin follow-up

The user successfully pinned the final Chess application. Read-only Dock preferences verify the exact target `.../5ac2f5a6d494d9c888031dd8122f1bc2/Chess.app/`, label Chess. Its URL, bundle and strict signature survived owned VM and host shutdown. Actual user click of that retained pin is the remaining cold-launch check; requested immediately after shutdown. Evidence: `build/harmony-unified-dock/{manual-pinned.plist,manual-pinned.json,manual-pin-lifecycle.json}`. Do not count earlier programmatic native opens as that actual Dock click.

## Test 5.1 closed-icon correction

- Focused source/receipt/process tests pass, including unsigned or forged ad-hoc template rejection, wrong CDHash/source/identity, symlink and permission failures.
- Native lifecycle and Open Documents fixtures pass with the generated local apps. A live artwork update leaves the running executable unchanged; static artwork is refreshed only after exit.
- The existing closed Chess target was rebuilt at its pinned URL. Strict signature verification passes. A separate process queried the actual native file icon while no helper or VM was running; `build/harmony-unified-dock/closed-Chess-icon.png` shows the expected knight. This is a native file-icon check, not a manufactured Dock screenshot.
- The user confirmed the retained Dock tile now displays the correct artwork and opens Chess. Final native file-icon lookup and strict signatures pass after the owned VM and helper stopped; see `final-artwork-verification.json`.
- `build/harmony-unified-dock/user-build-artwork.json` records the signed Test 5.1 package, unchanged Developer ID template, unchanged backend/Tools and the host code fingerprint matching the QA build. No new Tools install is required.

## Final Test 5.1 follow-up

The user reported a macOS crash alert naming `GuestLauncherTrustChecks`. Retained crash reports are earlier assertion failures from the development fixture, not the shipped launcher or Chess. The corrected trust implementation passes its native fixture. The fixture now catches errors and exits with a readable failure instead of trapping; an invalid-template negative control exits 1 normally. No trust checks were weakened. This fixture is not packaged in the user application.

The user-confirmed icon/open correction and strict signed Test 5.1 package are ready. The latest independent VM was stopped within its guard, the exact original private config was restored, and the user's Chess pin was retained. No further guest installer completed in this final run. The older cloned Agent's process report did not establish a live graceful-Quit result; simulated lifecycle checks pass, and this limitation is not presented as full live Save/Cancel verification. Earlier pending-state paragraphs above are historical receipts superseded by this final follow-up.

## User acceptance and release authorization

The user independently confirmed the complete native Dock cycle: pin app, quit VM, click the retained icon, PowerEmu starts the VM, enters Harmony and opens Chess. Quitting the guest app leaves the icon pinned; reopening works again. The user authorized commit and release, requesting a Tools version increment. Release target is PowerEmu 0.4.2 (11), Tools 2.24. This supersedes the earlier remaining user-click gate; drag/reorder was not separately scored.
