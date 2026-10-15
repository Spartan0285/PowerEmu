# Harmony responsiveness — October 14, 2026

The dual-display entry and coordinate fixes are preserved. Recent live capture logs showed host decode means around 0.025–0.091 ms, while capture round trips commonly exceeded 100 ms. Host decoding is not the current dominant delay; no Metal replacement is warranted from these measurements.

## Host changes

- Mouse press/release paths previously sent the same pointer position twice before the button transition. Removed the outer duplicate; `proxyButton` still submits coordinates before the button. Focus acknowledgment, modal blocking, release ordering and drag handling remain intact. This reduces these paths from three POINTER commands to two per transition.
- After button, keyboard or scroll input is forwarded, mark the interacting window for one prompt capture opportunity and request immediately when the worker is free. At most two input-priority selections may precede normal scheduling; other windows retain first-image and fairness opportunities. Priority expires after 600 ms, respects failed-window retry deadlines and cannot cancel or overlap an outstanding capture.

Only one capture/decode remains in flight. Existing sequence/delta validation and last-good-image retention are preserved.

## Validation and limits

Interaction scheduling fixtures cover prompt input ahead of unrelated first images, one-shot consumption, expiry, continuous-input background fairness and failed-window backoff. Coordinate regression passes. Release build and signed live validation status are recorded below.

These are reduced overhead and scheduling changes, not a measured claim of a particular click latency or frame rate. Guest capture and guest command processing still bound responsiveness. The next larger investigation should separately profile guest capture, delivery and focus acknowledgment under the same workload before changing polling rates or adding concurrency.

Release build succeeded and the refreshed PowerEmu Harmony Test.app passed strict deep signature verification. Live isolated Tiger validation: clicked Macintosh HD, observed selected icon and keyboard navigation to a new disk proxy; dragged that proxy onto Sidecar with its complete surface intact and submitted a content click there. Recorded down/up POINTER commands remained correctly paired. Capture response means settled around100–150ms; this unmatched functional run does not establish a speedup percentage. Log: docs/evidence/harmony-dual-2026-10-14/responsiveness-run.log. The owned VM was stopped while Harmony was active to check teardown.

## Active-window budget and background throttling follow-up

This replaces the earlier two-input/three-foreground scheduling budget above. Host native complete-window scheduling now uses a 450 ms interaction burst with at most six consecutive foreground selections while an eligible background window waits. Ordinary foreground scheduling uses four selections. Repeated input does not reset the fairness streak. A focus change resets the previous window's streak so the newly selected window gets prompt service. One immediate input selection may precede unrelated first images; new/resized windows and sheets then retain their priority.

Visible changing background windows are eligible no more often than every 125 ms (eight opportunities/sec); covered windows no more often than every 800 ms. Stationary windows back off to one second visible/three seconds covered. These are eligibility intervals, not promised frame rates. Background work shares the same serial capture budget. Host NSWindow occlusion state determines visibility. Hidden-to-visible transitions mark a prompt refresh without waiting out idle backoff; failure retry limits still apply. Foreground capture remains completion-driven, and the existing opt-in cache idle pacing remains separate/disabled in this build.

No pixels, codecs, guest capture APIs, guest resolution, GPU/SMP/audio paths or sequence/base validation changed. Only one request/decode is outstanding. The Dock trust fix is included.

Meaningful scheduler checks passed: bounded continuous-input fairness, new-window priority, focus switching, exposure refresh, visible/covered limits, failed-window backoff and cache pacing compatibility. Release build succeeds; staged app passes strict deep signature verification.

A deterministic four-changing-window simulation with 500 capture opportunities at 20 ms intervals allocated foreground 375 times in the committed baseline, 400 times in the new steady policy, and 429 times with continuous input. This validates budget allocation only. It is not measured guest FPS or click latency. There has been no matched live changing-frame benchmark for this candidate yet.

Signed candidate: build/staging-active/PowerEmu Harmony Test.app. The user's VM is still running in the prior build, so installation/relaunch waits for the user to save work, shut down and quit. Do not open this candidate against the same writable disk while the previous VM runs. After installation, test sustained scrolling, typing immediately after switching windows, opening sheets/new windows, revealing covered windows and cross-monitor dragging. Keep the previous Dock-fixed build as rollback.

User confirmed shutdown/quit. Verified no process remained inside the test bundle, installed the signed candidate at build/PowerEmu Harmony Test.app, and verified its strict deep signature again. Previous Dock-fixed build retained at build/staging-active/Previous Dock Fixed Harmony Test.app. Opened the installed app through CUA; its primary test VM window appeared. No automated stop guard was installed on this user test run.
