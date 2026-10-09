# Final Cut Pro 6: Tiger startup investigation

## Status

**Startup is verified by the user and reproduced locally on the original Tiger VM.** Final Cut Pro reaches its ordinary editor with four CPUs reporting 1.67 GHz. Viewer/Canvas surface corruption is the next issue; see `FINAL-CUT-PRO-PREVIEW-HANDOFF-2026-10-07.md`.

Candidate: `/Users/adam/Developer/PowerEmu/build/PowerEmu FCP Test.app`

This is an isolated experimental app with the existing 9200/9800 comparison switch and the latest Warcraft performance work. No release or commit was made. The startup investigation used a disposable overlay. Subsequent user-authorized testing set the original Tiger VM to report 1.67 GHz, and the user selected four CPUs. Final Cut Pro itself and its requirements/licensing files remain unmodified.

## What failed

Installed application: Final Cut Pro **6.0** on Tiger **10.4.11**, QuickTime **7.6.4**, 2 GB RAM, 256 MB VRAM, Radeon 9800, four active CPUs. Tests used the existing disposable Tiger Audio Test overlay, not the original Tiger disk.

The original executable loads its dependencies and exits with **status 0**, without a crash report. It reaches Registration Information; selecting **Register Later** leads to the same early exit. Nothing was submitted to Apple.

A diagnostic interpose recorded:

```text
QuitApplicationEventLoop
Final Cut Pro 0x0025ca24 — KGInit(), before KGPostSplash()
Final Cut Pro 0x00428058 — OpenApplication()
...
Final Cut Pro main() returns
exit status=0
```

Disassembly shows that `DoLicensing()` calls `AECheckConfiguration()`. A nonzero result sets the application's shutdown state. `KGInit()` subsequently quits before showing the splash screen. Despite the caller's name, the specific observed failure was a system-requirements warning, not evidence of a serial-number failure.

A probe that preserves the original Apple check methods observed:

| Check | Original result |
| --- | ---: |
| CPU speed, multiple processors | **237** |
| CPU type and single-processor speed path | 0 |
| Screen resolution, QuickTime, OS | 0 |
| OpenGL extensions and VRAM | 0 |
| RAM and Quartz Extreme | 0 |

The bundle's `Contents/Resources/minsys.plist`, which is more detailed than Info.plist, specifies a 500 MHz blocking threshold and a **1250 MHz warning threshold** for both single and multiple processors.

A standalone **non-UI** probe against Apple's unmodified `MRCore` and that exact minsys.plist reproduced:

```text
hw.cpufrequency: 900000000
hw.ncpu: 4
Requirement result=237
Final Cut Studio Installer recommends ... 1.25 GHz;
this system has ... 900.00 MHz.
```

The same disk, emulator, graphics card, RAM and CPU count, with only the firmware's CPU-frequency property changed:

```text
hw.cpufrequency: 1420000000
hw.ncpu: 4
Requirement result=0
```

The 900 MHz control was repeated after the passing run and returned 237 again. Evidence and diagnostic sources are in `docs/evidence/fcp-launch-2026-10-07/`.

## Host change

`app/Sources/PowerEmu/VMRunner.swift` already promises a minimum reported speed of 1420 MHz for compatibility. Previously the firmware property was generated only when optional `cpuMHz` was present. Older configurations with that field absent inherited OpenBIOS's 900 MHz default.

The fix applies the existing minimum to missing values too:

```swift
let reportedMHz = max(c.cpuMHz ?? Self.minReportedMHz, Self.minReportedMHz)
```

The boot command then always writes that frequency to the CPU node. Existing explicit choices still receive the same minimum as before; larger choices remain larger. This changes reported hardware metadata, not actual execution speed or the audio/timebase clock.

No Final Cut Pro executable, requirements plist, serial data, graphics capability check, or license check was patched or bypassed. No GPU emulation change was needed for this finding.

## Validation completed

- Original Tiger launch failure reproduced and deliberate exit traced.
- Apple's non-UI requirement checker: four CPUs, 900 MHz → 237; 1420 MHz → 0; repeat 900 MHz → 237.
- One CPU, 1420 MHz → requirement result 0, using the same checker.
- Release build of the candidate completed.
- Candidate passed deep/strict code-signature verification.
- Old performance candidate and new candidate contain identical emulator bytes after removing their packaging signatures: SHA-256 `bc5423553fbc3fce94d847f1f2fa441be90701e5435e53cad8d6f377320658c2`.
- Repository whitespace check passed.

All owned guest test processes were stopped after the probes.

The experimental host app has existing shared changes; preserve them. This task added the CPU-frequency fallback and this evidence/handoff only.

## Next interactive test — required before calling it fixed

1. Unlock the host Mac and launch **PowerEmu FCP Test.app**.
2. Cold-boot the Tiger VM. A saved RAM/sleep state may retain the old device tree; resuming it does not test this fix.
3. Keep the 9800 selected initially. Confirm `sysctl hw.cpufrequency` reports at least 1420000000 in the guest.
4. Launch **the original Final Cut Pro from Applications**, without diagnostic environment variables or injected libraries.
5. Select **Register Later** if prompted. Do not submit registration information.
6. Confirm the splash screen, first-use dialogs, and complete editor appear. A menu-bar name alone does not count.
7. Quit normally, launch again, and test a disposable blank project. Check window drawing, importing a small test clip, playback and saving. Launch success does not establish reliable editing/export performance.
8. Repeat ordinary startup with one CPU, then compare the 9200 if a graphics-specific failure remains.

If the app still exits, capture its next initialization stage rather than changing additional hardware blindly. The old pre-splash CPU warning has a concrete fix, but a later independent failure remains possible.

## Diagnostic caveats

The initial Objective-C interpose probes crashed because their direct calls to Apple's PPC method implementations did not set r12 to the implementation entry point. Those are **probe-induced crashes**, not baseline application crashes. The final C observer uses an assembly tail-call helper that sets r12 and leaves all original return values intact. Do not use the discarded probes as evidence of a GPU fault.

The desktop diagnostic wrapper was moved into the disposable guest's `~/Documents/PowerEmu Diagnostics/`. Its temporary libraries do not survive a guest reboot. Use the original application for normal testing. No diagnostic library is packaged in the candidate.

## Follow-up: configurable speed

The General tab now offers **Reported processor speed**: 1.42, 1.50, or 1.67 GHz. The setting uses the existing persisted `cpuMHz` field, is disabled while running or asleep, and applies independently to 1, 2, and 4 CPUs. Firmware now writes the selected frequency to **every configured CPU node**. Missing/older low values retain the 1.42 GHz compatibility floor; values above 1.67 GHz are capped at the new maximum.

Verified all three speeds with all three CPU counts against the actual firmware-property generator, checked legacy/default/range handling, rebuilt and verified the signed candidate, and opened the app through computer-use tools. Tiger's setting was saved at **1670 MHz**, with its existing **1 CPU** choice retained. The app is open at General; Tiger remains shut down for the user's cold-boot test. Full editor launch is still pending the user's test.
