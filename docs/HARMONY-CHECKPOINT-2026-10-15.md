# Harmony checkpoint — October 15, 2026

User authorized committing the confirmed Harmony improvements and continuing missing-display startup handling and app-shortcut management.

The application checkpoint preserves the user-confirmed Test2 responsiveness work, dual-display geometry/routing, cursor visibility, trusted standalone Dock representatives, durable launch routing and the bounded AX stability candidate. Experimental focus/capture/publication paths remain opt-in; failed experiments are not promoted. Disk-restore UI and separate audio/BQL diagnostics are outside this checkpoint.

Backend readback commit `396d1c76ff0b13e8bfc358763ed49238a51a5123` implements bounded translated-RAM targets and the missing split-coordinate download. Dependency commit `50ea608c8c2` tracks two headers already required by the previously committed audio observer, with no playback-policy change. Backend now has a local `main` branch; no remote was changed.

Live Tiger/Radeon9200 validation: covered/uncovered complete RGB captures pass; all pixels of initial/moved/resized/uncovered window captures match; direct GL readback5/5 and display4/4 pass. Chess renders and repaints in Harmony, including a pawn move/computer response and exit/reentry. No general FPS/audio/all-app claim. Full evidence and limits are in HARMONY-CHESS-STABILITY-2026-10-15.md. The backend flag and optional guest AX workers remain explicit candidate switches; signed Test3 supplies the tested settings.

Validation before checkpoint: Swift release build, capture-scheduling/guest-desktop/cursor/launcher fixtures, backend ASan/UBSan target/span/copy fixtures, and slot-observer dependency fixtures. Existing separately signed Test3 and Test2 remain available. No push or release is authorized by this checkpoint.
