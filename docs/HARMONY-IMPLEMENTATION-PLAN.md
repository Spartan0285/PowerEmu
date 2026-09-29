# Harmony: revised implementation brief for Claude Code

Date: 27 September 2026

## This revision replaces the previous implementation sequence

The user requires independent guest windows that participate in host stacking, focus, minimization, application Dock presence, menus, and bidirectional drag-and-drop.

A masked desktop is a diagnostic or fallback presentation, not the main implementation milestone. One transparent host window cannot interleave a native Mac window between two guest windows.

Do not restart broad display-pipeline investigation based on the superseded diagnosis. Read the corrections in `HARMONY-STATUS.md`, especially sections 6b and 6c. Synthetic tests now show content progression; some apparent stalls were transparent surfaces. Remaining failures need valid reproductions.

This brief specifies experiments and an intended architecture. It does not claim complete-window capture, Tiger drag interception, or the proposed host application ownership model have been proven.

## User requirements

1. Keep the guest running with a full-sized virtual display, while hiding its desktop/wallpaper, menu bar, and Dock from host presentation.
2. Present live guest windows with appropriate shapes and rounded corners. Interleave them with native host windows and support correct focus and stacking.
3. Minimize and restore guest windows through the host Dock.
4. Represent each running guest application in the host Dock. Route Quit and explicit Force Quit to that guest application.
5. Present the active guest application's menus promptly in the host menu bar, retaining PowerEmu controls where appropriate.
6. Support file and supported-content drag-and-drop between host and guest applications, Finder windows, and the host desktop.

The visible host desktop belongs to the host. A drop there must reach the host. The hidden guest Desktop is accessible through a guest Finder window or an explicit destination, not an invisible fullscreen drop target.

## Working rules

- Read applicable repository instructions and inspect current changes before editing. Preserve existing uncommitted work.
- Verify the active emulator checkout and executable. Reviewed scripts default to `~/Developer/poweremu-qemu`, with a `POWEREMU_QEMU` override. Do not edit an obsolete checkout under `~/QEMU Project` accidentally.
- Record build revision, uncommitted source state, guest OS, and test configuration.
- Preserve normal desktop mode and isolate experiments behind reversible flags.
- Keep useful agent, Dock, menu, and file-transfer work. Avoid a wholesale rewrite before the capability gates pass.
- Do not add capture delays, focus cycling, periodic raises, or screenshot healing as substitutes for content ownership.
- Do not count copies or callbacks as proof of fresh content. Decode a sequence drawn in the pixels.
- Validate instrumentation with an independent control. Previous measurements failed because counters were covered, input never reached its target, or harness overhead was counted as latency.
- Separate verified findings from hypotheses. Recheck source locations because Claude may already have changed the code.

## Intended architecture

| Component | Responsibility |
|---|---|
| Guest integration | Identify applications and windows; obtain content; report lifecycle, focus, menus, and supported drag payloads; execute guest commands |
| PowerEmu coordinator | Maintain identities and sessions; route commands; manage content transport, file transfer, and recovery |
| Host application representative | Own a guest application's native host windows, Dock presence, minimization, projected menus, and host drag sessions |

Prototype promoting the existing Dock helpers into host application representatives. Currently helpers own Dock tiles while proxy windows belong to PowerEmu. Test whether placing each guest application's proxies in its representative process makes native ownership behavior reliable.

This is a design hypothesis. Validate activation, host window grouping, menu ownership, minimization, and recovery before migrating all applications. Shared Harmony menu code should run where the active host application can publish its menus; do not assume an inactive PowerEmu process can own the active representative's menu bar.

Use stable identities including VM session and lifecycle generation. A reused guest PID or window ID must never inherit an old command, window surface, or menu action.

## Immediate task 1 — Prove complete-window content

### Question

Can PowerEmu obtain a complete, current image of a guest window while another guest window covers it, without activating or raising it?

This is the primary architectural gate. Desktop crops contain no current pixels for covered regions. Independent host movement can expose those regions even while they remain covered in the guest.

### Experiment

1. Create a deterministic animated guest window with a frame number repeated across multiple areas, including areas that will be covered.
2. Capture it with no overlap, partial overlap, and full overlap. Verify the application continues generating content during the test.
3. Display the resulting image in a simple host window, independent of the production screenshot/cache machinery.
4. Verify every region belongs to the target and that frame progression continues without capture-related focus changes.
5. Record completeness, generation consistency, capture latency, guest CPU cost, and transfer cost.
6. Repeat with representative real Cocoa, Carbon, and accelerated content before claiming broad compatibility.

### Candidate sources, in order

- **Leopard:** guest-side `CGWindowListCreateImage` targeting a specific window. Test actual behavior and cost on the emulated OS.
- **Tiger:** investigate guest window-server backing-store or export facilities. Record the already-failed interfaces in `HARMONY.md`; do not repeat them without a changed premise.
- **If those fail:** investigate guest-side integration that exports window content before desktop occlusion. This may require window-server or application instrumentation and separate handling for Cocoa, Carbon, and accelerated surfaces.

A successful Leopard experiment does not establish Tiger support. Label capabilities by guest OS and content type.

Time-box the initial API/export investigation to one focused engineering session. If it fails, write a capability report identifying the missing guest integration. Do not expand host-side feature work around an unproven source.

### Pass condition

A fully covered, actively drawing guest window produces complete current images with no foreign pixels and no capture-related activation or raising. Report measured performance; do not call a slow snapshot proof a production streaming solution.

### Fallback decision

If export cannot be made available, a non-overlapping workspace inside an oversized guest scanout may be tested separately. It must prove display-size capacity, application positioning, popups, dialogs, accelerated content, and input mapping. Off-screen placement is not equivalent: applications may stop rendering there.

Do not silently substitute a masked-desktop group for the user's independent-window requirement.

## Immediate task 2 — Prove host application ownership

Build a small experimental representative for one guest application with two windows. A generated test surface may isolate host behavior initially; integrate the proven guest content source afterward.

### Required demonstrations

- A native Mac window can sit between the two guest proxies in host stacking order.
- Clicking a proxy makes the correct host representative active and requests the correct guest window activation.
- Minimization and restoration use real host windows and preserve identity.
- The representative supplies the correct projected menu when active.
- Normal Quit leaves the representative alive while the guest presents a save prompt.
- Canceling that prompt leaves its Dock tile and windows intact.
- Confirmed guest application exit removes the representative and its windows.
- Representative failure can be recovered without automatically terminating the guest application.

### Current behavior to replace

`helper/main.swift` currently requests guest Quit and returns `.terminateNow`. That does not wait for guest exit and cannot represent a canceled quit correctly.

Normal Quit should enter a pending state and wait for lifecycle confirmation. Apple supports deferred termination through `applicationShouldTerminate` and `reply(toApplicationShouldTerminate:)`; choose the appropriate lifecycle implementation and test it.

Explicit Force Quit must be a coordinator command targeting the verified guest application identity. Do not depend on a force-killed helper running a callback. Unexpected helper death is not automatically user authorization to kill the guest application.

Execute application commands directly in the guest. Do not automate clicks on hidden guest Dock icons; the guest Dock reflects application state afterward.

## Immediate task 3 — Prove actual bidirectional file dragging

### Current gap

At review time, `VMDisplay.swift` ignored the dropped-on window ID and called `dropFiles(..., into: "~/Desktop")`. This is file transfer to a fixed location, not application-aware drag-and-drop. Verify the current source before changing it.

### Required demonstrations

1. Drag a host file into a specific guest Finder folder and verify it arrives in that folder.
2. Drag a file from guest Finder onto the host Desktop using a native host drag session.
3. Cancel each direction and verify no unintended completed transfer or leftover active drag state.
4. Test duplicate names without silently deleting existing destination files.

### Design requirements

- Use explicit drag/session IDs, offered data types, allowed operations, destination identity, completion, and cancellation.
- On the host, use native drag sessions and file promises where appropriate.
- Discover the actual guest drag payload. Pointer motion outside a window does not identify dragged files or data.
- Treat Tiger guest drag discovery/interception as a capability experiment; it may require application integration.
- Route guest Finder drops to actual folders. Route application drops to supported drop or open-document behavior and distinguish those semantics.
- Preserve file data and relevant metadata/resource forks for legacy Mac files through the chosen transfer transport; test this explicitly.
- Default early file tests to copy semantics. Implement move only with verified destination completion before source removal.
- Stage by unique transfer ID rather than a shared basename. Report failures and clean up canceled transfers.

Start with Finder files. General text/image/application-specific dragging is a later capability, not implied by file-transfer success.

## Window content and presentation contract

Once task 1 passes, build production publication around:

```text
VM session
application identity + generation
window identity + generation
surface size/format generation
content sequence
shape generation
completion state
buffer ownership
```

Requirements:

- Publish completed content; do not let the producer overwrite buffers still being consumed.
- Prefer the newest complete frame under load. If updates are deltas, preserve cumulative damage when dropping intermediate updates.
- Resize, destruction, reconnect, and ID reuse invalidate older generations.
- Separate window shape/alpha from desktop-exclusion alpha.
- Apply rounded corners to appropriate windows; do not apply a universal rounded mask to menus, sheets, or irregular windows.
- Avoid capturing another window's shadow into window content. Choose one shadow representation.
- Do not treat an opaque crop as proof that the crop contains only the target's pixels.
- Exclude wallpaper, guest menu bar, and guest Dock by choosing which surfaces to export, where the content source supports this.

## Focus and menu protocol

Track these as distinct state:

- Active guest application.
- Keyboard-focused guest window.
- Frontmost guest window.
- Host key window.
- Modal owner/window.

At review time, guest `reportFocused` selected a top window partly for capture safety. That is not always the keyboard-focused document. Do not reuse capture heuristics as focus truth.

A host activation request receives a sequence number. The guest acknowledges resulting application/window state. Preserve input ordering relative to activation and reject obsolete acknowledgments.

Host stacking belongs to the host. Synchronize guest state for input and application behavior without cycling focus to refresh surfaces. When a native host application activates, stop routing keyboard input to the guest and handle guest inactive appearance explicitly.

Menu behavior:

- Decouple menu ownership from periodic window enumeration.
- Use activation state to select a cached menu for the correct application promptly, then refresh dynamic state.
- Stamp snapshots/actions with application and menu generations.
- Do not allow late responses to reinstall a previous application's menu.
- Refresh dynamic menus when opened; disable stale actions until validated when necessary.
- Route actions to their recorded target, not whichever guest application happens to be active on arrival.

## Acceptance criteria after the capability gates pass

These are initial targets, not established results. Measure guest application execution separately from display overhead.

| Area | Target |
|---|---|
| Completed guest content to host presentation | p95 ≤33 ms; p99 ≤50 ms |
| Controlled input to visible response | p95 <100 ms; report actual guest contribution |
| Foreign pixels in opaque test interiors | Zero across 10,000 move/raise/resize operations |
| Torn or mixed generations | Zero in deterministic frame-pattern tests |
| Animation | No unexplained pause over 100 ms while guest content is being generated |
| Focus | Correct target through rapid host/guest switching and modal transitions |
| Menus | No wrong-application menus or actions after late replies |
| Quit | Save/cancel/confirmed exit reflected correctly in Dock and windows |
| Transfers | Correct destination and payload; cancellation and collisions handled |

Record source content sequence separately from copy count. An unchanged static image can remain valid indefinitely; recopying an old animated frame is not progress.

## Required progress report

For each immediate task, report:

1. Exact capability tested and guest OS/content types covered.
2. Source/build/configuration used.
3. Reproduction and independent instrument validation.
4. Measurements and observed behavior.
5. Pass/fail against the gate, with remaining uncertainty.
6. The next implementation decision justified by that evidence.

Update status documentation with verified results. Label superseded claims clearly so old renderer hypotheses and contradictory defaults do not restart another investigation.

Do not mark the feature complete after a transparent desktop or successful synthetic animation alone. Completion requires the user's independent-window, application lifecycle, menu, and transfer behavior.

## References

- [Harmony status and corrected measurements](HARMONY-STATUS.md)
- [Existing architecture and failed approaches](HARMONY.md)
- [Parallels Coherence behavior](https://kb.parallels.com/au/4670)
- [Historical WebKit window-capture investigation](https://www2.webkit.org/show_bug.cgi?id=21495)
- [Apple: deferred application termination](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:))
- [Apple: file-promise drag-and-drop](https://developer.apple.com/documentation/appkit/supporting-table-view-drag-and-drop-through-file-promises)

Parallels is the experience reference. Its public documentation does not establish which internal capture architecture PowerEmu should copy.
