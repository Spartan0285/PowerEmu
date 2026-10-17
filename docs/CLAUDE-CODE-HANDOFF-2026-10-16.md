# PowerEmu — Claude Code continuation handoff

Updated October 16, 2026. Prepared at the user's request. This document records existing authorization and evidence; it is not permission to commit, release, stop the user's VM, or broaden access.

## Start here

Repository: `/Users/adam/Developer/PowerEmu` (the previous shell cwd was sometimes `/Users/adam/QEMU Project`; set the workdir explicitly). Branch `main`, last observed HEAD `a64d6e4 PowerEmu 0.4.2 (11)`. There are many intentional uncommitted and untracked changes. Inspect `git status`; do not reset, clean, overwrite, or commit them indiscriminately.

Latest user-facing candidate:

`/Users/adam/Developer/PowerEmu/build/staging-hourly/PowerEmu Harmony Palette Test 13.app`

It is signed and was **user-confirmed working in Tiger** on October 16 (not released; Leopard and other Office palettes unverified). User was told to reinstall its bundled **Tools 2.24 test payload** and restart Tiger. Same version number does not mean the installed payload is identical. Preserve Test10, Test11, Test12 and Test13 as independent artifacts.

At handoff inventory, Test13 host PID17765 was running, and no `qemu-system-ppc` was present. This is a snapshot, not permission to stop anything: inventory again. Assume the user may be beginning verification. The `poweremu-hourly-improvements` automation is **PAUSED**; leave it paused unless the user asks otherwise. Do not run competing autonomous GUI/VM tests while the user tests.

## Current priorities

1. Obtain/act on Test13 palette feedback. Preserve Test12 accidental-file-import prevention.
2. Remaining Harmony correctness and active-window/app-switch responsiveness, without undoing working focus recovery, Word font selection, Dock trust/persistence, dual displays or cursor behavior.
3. Coherence sharing parity after the active Harmony issues are settled.
4. Source-qualified audio fixes; much diagnostic work exists, but do not imply a newer proven playback improvement.
5. Safe disk restore/Sorbet support; DMG handling remains unimplemented.

User favors measured improvements and working builds over prolonged speculative diagnostics. They authorized lower-model research/review subagents earlier; coordinate file ownership if using them. No further commit/push/release is currently authorized. Earlier release authorization applied to the already released Dock work, not these newer candidates.

## What Test13 changes and what passed

Word 2004 Formatting Palette was a true AXWindow/AXFloatingWindow but CGS level0, like its document. A generic high-window-level heuristic would miss it. AX MOVEWINDOW successfully changed actual guest coordinates, but switching Finder→Word reset the palette. A redundant-display-mode-skip experiment did not fix this and was removed.

Test13 identifies floating palettes through the existing bounded sheet worker, with explicit AX subrole and current PID/PSN/CGS owner/geometry validation. It forwards a classified palette's title drag through the existing guest pointer path instead of performing a host-local drag followed by AX position assignment. This lets Word process its own drag. No host-only position cache is used.

Host stacking uses relative ordering above a visible document of the same guest owner, not a globally floating window level or child-window attachment. Sheets/menu/drag images/minimized/vanished windows are excluded. Classification is cleared on disconnect/exit and gated by the existing worker/session epoch.

Live owned run13821, guest Word261/CGS connection41483, palette74/document72:

- Two actual CUA title gestures, confirmed by PEEVENT74 and guest pointer down/up, moved guest coordinates700,58→800,108→900,158. No MOVEWINDOW used.
- Finder activation hid the palette; returning to Word preserved900,158.
- Harmony exit and reentry preserved900,158, HARMONYREADY true and frames continued.
- Independent host CGWindow front-to-back list after activating Document1 placed palette74 before document72, both layer0.
- The palette Bold button worked after movement; document text visibly became bold.
- Pure palette ownership/exclusion policy and drop-intent regression tests passed.

Limits: other Office apps/palettes and transparency have not been verified. An intermittent Office Save/Cancel crash remains unresolved. CUA bulk `typeText` produced repeated characters, and a rapid paced sequence yielded bcd rather than exact abcd; do not claim exact keyboard-string validation. Do not blindly repeat bulk text input. A prior repeat-drag attempt in run10562 actually targeted Finder29 despite a palette screenshot, so it was rejected as a palette test, not counted as a product regression.

All owned13821 tests stopped within480sec; exact original guest Agent/Info, internal host/Info and private two-display configuration were restored. No original user disk was tested or modified.

## Test13 artifact verification

Receipt:
`build/harmony-drop-2026-10-16/palette-live4/test13-receipt.json`

SHA256:

- Host: `3f3eeade874ba3222a483e09ac0b57806d04bb1d261412ee87095191f05f9a0d`
- Tools ISO: `7e33ad457eafb7aeb4ee70eab46d7b38cba3d77c6dcd9b459f1fae375afb701f`
- Guest Agent: `7a3269f9423e0dbdda212c8fad9b564d4f744737d2a9450db8842ada9464eddb`

Live/mounted guest binary MD5 `49a2fa2270f27ca912a025e328559b19`; Info MD5 `9da327ced58562e6247177144211f438`.

Strict deep codesign verification passed. Mounted ISO exact binary/Info and execute modes passed. Initial staging caught a missing executable bit; it was repaired before ISO creation. Staged host equals the live-tested code after signature removal and normalization of __LINKEDIT vmsize: only one signing-allocation byte at3553 differed. Do not casually normalize other differences.

Test12 was unchanged:
- Host SHA256 `d2c9a68201a4286a2e09f149ad1166cdca5e397162575b62f6209d3a559c158c`
- ISO SHA256 `243ad3c36a9333d5ed26de6103131b3817dcf158b006416aaa93eb56eca3038f`

## Source and build traps

Production changed palette files:
- `guest/src/PESheets.inc`: `PESheetReportWithPalettes` extends existing bounded worker; does not add a new periodic main-thread AX walk.
- `guest/src/PEAgent.m`: worker publication and default-off `PE_PALETTE_CLASSIFY`.
- `app/Sources/PowerEmu/GuestAgent.swift`, `VMDisplay.swift`, `VirtualMachine.swift`: owner map transport/lifecycle.
- `HarmonyWindows.swift`: palette map, relative ordering, `usesGuestPaletteDrag`, existing pointer gesture path. Live-content/order/minimize/restore gates are included in Test13.
- `HarmonyPalettePolicy.swift`, `tests/HarmonyPalettePolicy/main.swift`: pure owner/exclusion policy.

Production working tree also contains unrelated unshipped menu-owner/other drafts. **Do not blindly package its current executable.** Test13 was built from Test12's scoped source plus only palette changes:

`build/harmony-drop-2026-10-16/palette-scoped-host`

Always query the real SwiftPM output:

```sh
swift build -c release --package-path build/harmony-drop-2026-10-16/palette-scoped-host
swift build -c release --show-bin-path --package-path build/harmony-drop-2026-10-16/palette-scoped-host
```

Hardcoded arm64 release paths have previously been stale. Last observed scoped output was `.build/out/Products/Release`. Do not overwrite scoped source from production wholesale. Reconcile reviewed changes deliberately if moving toward a future release.

Test13 flags: host `POWEREMU_HARMONY_PALETTES=1`, `POWEREMU_HARMONY_PALETTE_DRAG=1`; guest `PE_PALETTE_CLASSIFY=1`. Source defaults remain off. Existing recovery/occlusion/lazy-sheet flags are preserved. Explicit focus-async and input-priority experiments are not newly enabled.

Packaging script: `build/harmony-drop-2026-10-16/palette-live4/stage.py`. It refuses to overwrite the existing Test13 app; use a fresh candidate name/directory for new work. Signed identity comes from existing `scripts/signing.local`; do not expose its contents or modify signing trust. Never mutate running app bundles.

## Drop safety must remain intact

`HarmonyDropIntent.swift` plus destination checks in HarmonyWindows tie an import to drag sequence, Harmony epoch, live destination/bounds/topmost validation, and one consumed drop. Entering a Harmony window alone must not import a host file. Exit, release outside, stale session, replaced/closed/minimized target and duplicate completion must reject.

Actual Test12 owned96419: deliberate file drag16 copied one harmless file with matching MD5; drag17 entered the proxy then released outside, operation0 and no second import. Native fixture deliberate/outside behavior also passed. The user's exact initial desktop gesture and promised-file delivery are not fully qualified. Preserve these honest limits.

## Safe live testing workflow

Read `docs/HARMONY-DROP-PALETTES-2026-10-16.md` newest sections first. Use CUA/native UI tooling for GUI actions. If locked, continue CLI only; do not bypass the lock. Shell is appropriate for builds, logs, read-only diagnostics and trusted guest commands, not alternative synthesized GUI automation.

1. Inventory all emulator and frontend processes. Never start another emulator alongside the user's VM or stop the user's VM without need/authorization.
2. Use only the independent cloned Tiger base and owned overlay. Private config:
   `build/audio-tests-2026-10-14/support/Virtual Machines/Tiger Harmony Audio Test.poweremu/config.plist`
3. Save fresh exact backups of private config, internal executable/Info, guest Agent/Info/preferences before changing them. Never reuse stale backups as current user state.
4. Internal app is `build/harmony-stall-2026-10-15/PowerEmu Harmony Recovery Internal.app`, bundle id `com.poweremu.harmony.recovery.internal.oct16`. Signed internal launch may autostart the private VM.
5. `build/harmony-stall-2026-10-15/owned.py preflight` refuses another emulator; immediately `register FRESH_LABEL` after launch validates exact backend/private disk/port and installs a480second stop guard. It supports `ssh COMMAND` and `stop`, not status. Use bounded tests and restore before the guard.
6. Owned SSH uses existing `tigeremu`, port2319, existing tiger_key, strict pinned host-key checking and exact process command validation. Do not weaken trust or print credentials. Temporary boot banner timeouts are not permission to disable checks.
7. Candidate install/restore helper: `build/harmony-drop-2026-10-16/palette-live3/payload.py`. Inspect before reuse: its restore uses retained original clone Agent/Info, so confirm those are still appropriate. Expected prior restored MD5s Agent `a48b78f5f35a2a9ff707f7ad6d77a0f4`, Info `7fff3559a75e102ab1cf40e01bbd757d`.
8. Restore guest payload while VM is still alive; stop owned backend; terminate only exact owned frontend; restore exact saved host/config; resign and strict-verify. Inventory again. Preserve user-host processes.

Read-only guest position probe source/binary: `build/harmony-drop-2026-10-16/paletteprobe.m/.ppc`. Upload to owned guest `/tmp/pepaletteprobe`, run with fresh Word PID. PSN→CGS ownership/rects are valid; direct SSH AX errors-25204 are expected. The old pemenutrace PID field is invalid (returned self); never use it for ownership. Host read-only order probe: `palette-live4/order.swift` and executable `order`.

CUA observations can be stale across proxy focus changes. Reacquire app, inspect current AX title and screenshot, and verify resulting PEEVENT window ID. Proxy Finder/Word activation may report a5sec timeout but still activate. Do not infer failed activation solely from timeout or successful gesture solely from screenshot. Use deliberately paced keys; bulk paste/type has repeatedly been unreliable in Tiger.

## Other established behavior and rejected approaches

- User confirmed Test10 recovery works; preserve bounded connection recovery and session/epoch focus leases. Cannot cancel an already-blocked AX call; not every freeze is fixed.
- Test11 lazy sheet enumeration improved Word focus request→ack medians218/268/221ms in candidate/baseline/candidate (~18%); Finder mixed. Not general FPS or input-to-photon evidence.
- Word custom Font selection requires a narrowly scoped parent AXPress then a fresh validated leaf. User confirmed it works. Guest menu may visibly pop up: user explicitly rejected suppression/delay; do not revive it. Exact font preview rendering in host menu is not implemented.
- Stable per-app/per-VM Dock launcher cold-start/pinning was user-confirmed and released. Keep icons/trust/identity stable; don't resurrect three modes or huge menus.
- Half-resolution output showed essentially equal guest capture cost. Direct/cooperative capture prototypes and owner narrowing failed performance gates. Do not repeat guessed flags/priority/channel/scaling permutations.
- Host TCP_NODELAY trial was invalid because this host connection is AF_UNIX. Pixel fixture measures dispatch→decoded counter only, not photons/general app FPS.

## Audio and sharing continuation

Read `docs/AUDIO-NEXT-REVIEW-2026-10-14.md` and `docs/AUDIO-TRACE-AUDIT-2026-10-14.md` before audio work; they supersede older investigation instructions. Preserve the user-confirmed FreezeTest3 roughly95% baseline. No new proven playback improvement from the later probes. Slice/lifecycle experiments remain off.

Known-good queued Miles PCM became irregular before DMA; host output matched DMA. Next qualified experiment is existing default-off BQL/MMIO recorder plus source-qualified Miles/SM/raw/host captures on a single-display clone. Restore missing fixture/reference first. Prior dual-display workload failed OpenGL initialization and is unscored for audio. Timestamp-gap estimates are not source loss. Require nonempty full reference coverage, zero recorder drops/errors, stopped flush, same-binary symbols, and recorder-off controls before promoting any fix. No generic clock/buffer/period changes based on counters.

Sharing clipboard polling is500ms with no CLIPACK; socket clipboard writes and USB keyboard injection are distinct paths. Merely sending CLIP before CmdV does not prove ordering. Reliable paste needs bounded session/token-scoped acknowledgement and actual validation. Follow `docs/HARMONY-COHERENCE-DOCK-AUDIT-2026-10-15.md`. For restore work read `docs/SORBET-RESTORE-NEXT-2026-10-14.md`.

## Main evidence/read order

1. `docs/HARMONY-DROP-PALETTES-2026-10-16.md` — newest Test13 and previous failed controls.
2. `build/harmony-drop-2026-10-16/palette-live4/` — receipt, order snapshots, after-exit/reentry, live-13821.log, backups, stage script.
3. `docs/HARMONY-FREEZE-RECOVERY-2026-10-15.md` — Test10/Test11 and recovery limits.
4. `docs/HARMONY-WORD-2026-10-16.md` — Font fix, rejected suppression, Office crash.
5. `docs/HARMONY-COHERENCE-DOCK-AUDIT-2026-10-15.md` — parity and performance experiments.
6. Audio/restore docs above.

Keep evidence concise and distinguish passed tests, unqualified attempts, and user-confirmed behavior. Tell the user when a signed build is worth testing; don't claim diagnostics alone are an improvement.
