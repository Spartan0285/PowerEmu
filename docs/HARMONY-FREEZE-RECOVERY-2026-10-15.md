# Harmony freeze and reentry recovery — October 15, 2026

User reports switching is slow; all Harmony windows stopped updating, Tiger remained usable outside Harmony, and reentry timed out. Classic was mentioned as preceding activity but is explicitly out of investigation scope. Screenshot says Tools did not respond; it does not prove resolution failure.

## Live evidence (23:10–23:25 EDT)

User host PID34794 is Dock Test 5.1, backend55576 using the original Tiger disk. Neither was stopped or modified. No second VM was launched. Strict trusted SSH to localhost2222 timed out during banner exchange. Host two-second sample has no evident main-thread stall; backend sample shows main-loop execution and guest CPU activity, not a demonstrated global emulator deadlock. Samples retained under build/harmony-stall-2026-10-15.

Host lsof shows the agent listener but no connected agent socket; process inventory shows no guestfwd nc child for this VM. This changes the next diagnostic priority: absent bridge/reconnect must be distinguished from an AX call blocking a still-connected Agent. No guest stack/version/flags were obtained, so current root cause remains unproven.

## Concrete recovery defect under review

PEAgent connect runs a blocking TCP connect on its main run loop. The existing two-second SO_SNDTIMEO is installed only AFTER connect succeeds, so it cannot bound a failed reconnection. A missing guest network path can therefore prevent the main loop handling controls/retries. active_capture_review owns a narrow bounded-connect helper, fixture, and integration only; no Agent deployment yet.

Independent audit also confirms synchronous FOCUSWINDOW, RAISE, RAISEHARD and MOVEWINDOW AX operations can block the main loop. Existing async menu/background AX fixed the controlled paused-Chess menu stall, but does not prove this user's failure fixed. PE_FOCUS_ASYNC protects main-loop progress for FOCUSWINDOW only, with one potentially blocked worker and stale-result gates; no reliable speed gain was measured. Do not promote it as a complete fix or blindly move CGS onto workers.

Local Apple header documents AXUIElementSetMessagingTimeout as available10.4, global for this process when given system-wide AX object. No timeout change made; verify actual Tiger SDK/runtime and bounded failure/normal focus behavior before candidate use.

## Overnight scope

Hourly follow-up resumed by explicit user authorization. First fix and qualify freeze/reentry recovery; retain signed build for user, then proceed with Coherence sharing parity and audio without waiting overnight. Preserve dirty files and Test6 occlusion optimization. No commit/push/release. User live VM remains untouched; independent clone/owned overlay only for future bounded tests after process inventory, strict480second guard, CUA GUI, pinned SSH trust. Do not claim a new tested build yet.

## Implementation checkpoint

Bounded-connect helper now implemented and native loopback success/refusal/deadline/flags fixtures plus ASan/UBSan pass. No live Tiger recovery claim. Review also found unbounded frame-socket connect while holding captureLock, which can block subsequent captures across Harmony transitions; same deadline should cover that and default-off direct request channel. Avoid mutable static timebase initialization with concurrent main/capture users. Trusted PPC10.4u build fixture pending.

Sharing reviewer proposes additive session/token CLIPSYNC/CLIPACK for reliable paste, but no implementation yet. Before implementation revise its proposed disconnect fail-open: never replay queued input into a new session or different focused window; queue must be bound to VM/session/focus, cancel safely and release modifiers on the existing input target as appropriate. ACK only after successful guest pasteboard mutation. This remains secondary to freeze recovery.

The candidate now covers all three connect sites (control, frame delivery, default-off direct receiver), each at2seconds. Parent added Makefile header dependency. Timebase uses local state to avoid concurrent initialization races. Agent active_capture_review is completing trusted ibookip SDK10.4u fixture/fullAgent compile in isolated /tmp/pe-bounded-connect; retain actual outcome before packaging. Native unit tests do not establish live Tiger reconnection or natural freeze recovery. No user-facing build is ready yet.

## October 16, first overnight follow-up

User host34794/VM55576 still running; left untouched, no second emulator launched. Collected completed independent review: full Agent compiled with10.4u SDK/AGENT_RUN off, existing send:text warning only. Durable candidate/fixture/receipt copied from tmp to build/harmony-stall-2026-10-15/bounded-connect. Actual physical PowerBook g3ip reports Tiger10.4.11/8S165; strict trusted upload and standalone loopback fixture run succeeded (exit0). Timeout, successful connection, refusal and flags restoration pass on actual Tiger. This does not establish natural Harmony stall recovery. No systemAgent deployment or preferences changes on either machine.

Next bounded-connect fixture adds elapsed-time and interrupted-wait gates. Separately reviewing host Connection synchronous writes without timeout and partial-write stream handling; no host code change or attribution yet. Current user's VM prevents isolated live testing under the no-second-emulator constraint; continue offline/focused physical-helper checks without stopping it.

Strengthened timeout fixture also passes actual Tiger:250ms requested,252.294ms observed with25 delivered timer signals, flags preserved and new socket reconnect succeeds. NativeASan/UBSan259.837ms/40 signals; LeopardPPC250.046ms/40. Retained under connect-regression-20261016. Host transport audit confirmed unbounded synchronous main-actor writes and partial failure retaining a corrupted framed stream; sharing_review now owns bounded asynchronous FIFO/one-shot-close implementation and socketpair tests (no live attribution). Root changed only timeout overlay title to “Harmony could not start”; actual dimension mismatch retains its specific message.

### Host recovery candidate implemented, not live-qualified

AgentConnection.swift replaces the old synchronous Connection in GuestAgent.swift. FIFO writes are off-main, capped8MiB/512frames, expire1second from enqueue, use nonblocking IO and absolute deadlines, and close the entire framed connection on failure. Socket shutdown/cancel plus serial writer teardown protect fd lifetime; disconnect callback is one-shot after read callbacks. Nonblocking setup failure cancels before source resume. Oversized/malformed headers reject. Queue limits apply to outstanding active frame too. Socketpair tests cover stalled reader, FIFO, partial failure, queue count/age, malformed input, callback uniqueness and descriptor reuse. Native tests and debug/release builds pass; no live host transport performance/recovery claim.

VMDisplay Tools-disconnect callback now exits active/preparing Harmony through existing requestHarmony(false), clears pending preparation/focus/capture/proxies, returns to normal desktop and reports connection loss. releaseAll runs first to release QEMU keyboard/buttons independently of deadTools. Existing Dock disconnected behavior retained. This fixes a missing teardown path in code, not a demonstrated natural-event recovery yet. Guest resolution restore commands cannot be delivered over a lostTools connection, so ordinary desktop can retain Harmony dimensions until a later mode request; do not claim complete mode-restoration coverage. Dual-display/reentry held-key and actual guest reconnect UI checks remain mandatory before a userbuild. Secondary-screen host restore uses existing exit path.

Latest release output path confirmed app/.build/out/Products/Release; final release build log build/harmony-stall-2026-10-15/release-build.log. Independent active_capture_review reviewing final transport concurrency and teardown. User VM remains running; no candidate install/sign/promotion, no commit/push/release. Next hourly run: collect review, then guarded live recovery when user VM is no longer running; do not repeat unchanged diagnostic captures.

Final independent read-only review found no concrete transport concurrency/ordering defect; verified stale-session guards and dual-screen host teardown. Final release build including releaseAll completed exit0. Known offline mode-restore limitation remains. Live userVM unchanged.

## October 16, 01:26 EDT follow-up

Inventory still shows user original-disk VM55576 and Test5.1 host34794. No emulator launched/stopped and no user bundle modified. New tests/GuestAgentTransportIntegration compile actual GuestAgent.swift and AgentConnection.swift against a temporary Unix socket, with only unrelated menu/debug/launch-validation stubs. shareClipboard=false; no real clipboard mutation or VM traffic. Independent sharing_review completing malformed first peer, split HELLO, new control session, invalid frame-session handshakes, stale old-close and active-disconnect callback gates. Retain its final output before claiming pass. No production edit this follow-up.

Further live Harmony fault/reentry, held-input and dual-display validation requires user VM to be shut down; do not start another emulator or discard guest work. Guest connect candidate has actualTiger standalone tests, host transport has socketpair+build tests, but neither proves the natural freeze fixed. No test build is promoted yet. Offline screen-resolution replay after disconnect remains a known limitation; avoid adding unqualified replay that could target a newer display topology.

Integration final result PASS, retained build/harmony-stall-2026-10-15/guest-agent-integration/run.log. Production classes tested with fragmented HELLO, malformed first peer, replacement/late-close ordering, mismatched frame session and exactly-once active disconnect. Harness failure paths exit cleanly rather than generating crash dialogs. No production changes or extra build in this follow-up. User notified once that saving/shutting down the current VM is needed for guarded live qualification; avoid repeating that notice on unchanged hourly runs.

## October 16, 02:22 EDT follow-up — internal staging

Inventory unchanged: user host34794/VM55576 left running and untouched. No new VM, repeated workload or user notification about shutdown. Prepared a separate **internal-only** signed bundle at build/harmony-stall-2026-10-15/PowerEmu Harmony Recovery Internal.app, copied from stopped isolated Integration Preview. Uses current queried SwiftPM release host, tested backend19ffdd80..., private clone support override, skip-occluded1, input-priority0, existing native-polling1/visible-cache0/AIC1. No focus flag promotion.

Internal Tools ISO carries exact SDK-built bounded-connect Agent14ea912c... in a copied legacy installer package; install/uninstall executable checks and mounted read-only ISO payload hash pass. Tools remains2.24 in this internal fixture, not a new public/user release. Original guest/build packages and all installed/running apps remain untouched. Root/nested strict signatures PASS. No launching or installation. Staging recipe/receipt, binary hashes and ISO readback are under build/harmony-stall-2026-10-15/{stage-internal.py,internal-stage-receipt.json,internal-iso-readback.json}. Build is not user-ready: actual disconnect/reconnect, held-key release, switching, dual-display and normal focus/menu checks remain unperformed. Internal bundle is Developer ID signed but not notarized; no notarization requested.

Next safe live setup must adapt existing owned guard exact executable validation to this distinct internal bundle; do not bypass guard paths. Inventory first; only run after userVM has stopped. Save/restore clone Agent/login/environment and config. Verify installed candidate bytes/flags, use bounded disconnect fault plus normal switching and exit/reentry, retain actual frames and input outcomes. No repeated offline tests justified without source change/failure. Live root cause still unproven.

## October 16, 03:25 EDT — guarded launch preparation

UserVM55576 still running, unchanged. Prepared dedicated build/harmony-stall-2026-10-15/owned.py from the established guard, with separate state/logs and exact new internal-backend executable identity. New preflight refuses when any PPC emulator runs; register requires the only running backend to be that exact internal bundle plus existing isolated-support/2319 checks. Existing full-command identity, strict pinnedSSH, QMP-only ownedstop and480second age-based deadline retained. Syntax check passes; actual preflight correctly rejected PID55576 (exit2). No register/launch/SSH/stop performed, no source rebuild or test repetition. This is guard preparation only, not live validation. No additional user shutdown reminder sent.

## October 16 live recovery first attempt

User shut down original VM. Owned clone31312 booted under480second guard, one-display temporary configuration. Initial SSH banner timeout resolved after boot; candidateAgent exactMD5 40dbd041f642f87c82a3200612104519 deployed temporarily. PREPARE caused disconnect fallback; not a recovery pass. Found host parser regression: valid partial payload exceeding128bytes wrongly hit header-only limit after parserbreak. Independent reviewer correcting with fragmented-large-payload regression. Original AgentMD5 a48b78f5f35a2a9ff707f7ad6d77a0f4 restored and verified before ownedstop; exact config restored, frontend terminated. No user build promoted. Flags reportedfocus0/menu0/background0; next live candidate must explicitly preserve intended async menu/background settings.

## October 16 live qualification and Test 7

Corrected parser cap applies to incomplete headers only. Large fragmented SCREENS integration and full AgentConnection regressions PASS; release rebuild PASS. Owned32671 candidate exact bytes and focus0/menu1/background1 verified. CUA entry HARMONYREADYtrue, Finder pixels/navigation/new window, controlled Agent termination caused automatic desktop fallback and connection-loss notice. Agent GUI restart reconnected; reentry succeeded without guest reboot and Finder Applications pixels updated. TextEdit launched through Finder, paced abc visibly exact, normal exit/reentry and Save dialog visible. Bulk typeText was truncated; do not claim bulk input fidelity. CUA host menu remained open during one screenshot attempt; explicit menu Cancel resolved observation. No universal AX hang or natural-root-cause claim.

Cleanup initially detected candidate bytes instead of intended original; corrected in fresh guarded owned33652 using durable original-agent/original-agent-info.plist (MD5 a48b78f5f35a2a9ff707f7ad6d77a0f4 / 7fff3559a75e102ab1cf40e01bbd757d), explicit sync and verification before stop. Guest preferences/environment unchanged. Exact private config restored and frontend stopped. Attempted two-display start showed missing-secondary warning, so live dual-display recovery remains unqualified. All owned runs stopped before guard; original user disk never opened.

Separate Developer-ID strictly verified build: build/staging-hourly/PowerEmu Harmony Recovery Test 7.app. User support overrides/debug paths removed; tested host executable matches after stripping different app signing envelopes; backend preserved. Mounted ISO exact candidate/flags PASS. Tools remains2.24 test payload and MUST be reinstalled from this build then guest restarted. No public version/release/commit. Receipt user-test7-receipt.json; retained single-display log live-fixed-single-display.log. This is a user recovery test build, not proof all freeze causes fixed.

## Test10 — live recovery after reproduced Office failure; ready for scoped testing

Signed build/staging-hourly/PowerEmu Harmony Recovery Test 10.app uses full Test8 host (unsigned binary equality verified), final focus-recovery.ppc, no popup suppression and no experimental async focus. Strict signature and mounted ISO payload/flags readback PASS. Tools remains2.24 test payload: reinstall from this app and restart Tiger.

Owned73053: initial install helper missed original Agent136 -psn suffix; all early GUI results excluded. Corrected exact executable-plus-psn matching, restarted and verified candidate Agent323 before Word336 tests. Visible Save sheet in Document3, Escape reproduced Microsoft Error Reporting349. Unlike prior65623 failure, subsequent CUA exit/reentry succeeded twice with HARMONYREADY ok=true and continued frame responses. Retained live-73053-host.log, processes and Agent sample. This supports the narrow stale-focus recovery repair, not Office crash resolution or universal AX recovery.

Owned74181 clean session: candidate Agent255, Word262, CUA Finder launch/document creation. Full213-item Font menu exposed empty CUA tree and screenshot unavailable; attempted selection is UNQUALIFIED, no font-value pass claimed. Working Test8 parent/fresh-leaf selection preserved by source removal of suppression; custom font previews remain unimplemented. No compact diagnostic host used in these runs.

Both VMs stopped before480second guard; exact original Agent/Info MD5 restored (a48b78f5f35a2a9ff707f7ad6d77a0f4 / 7fff3559a75e102ab1cf40e01bbd757d), private two-display config restored, exact internal frontend stopped. No running emulator at final inventory; user disks untouched. Stage receipt build/harmony-focus-recovery-2026-10-16/test10-stage-receipt.json. No commit/push/release. Pause autonomous GUI/VM tests while user verifies Test10.

## October 16 — Test10 accepted; switching/refresh measurement

User confirms Test10 working and explicitly prioritizes noticeably faster app switching/active refresh. Preserve that build; no new user build or promotion from this pass. Snapshot guest source: build/harmony-switch-2026-10-16/Test10-PEAgent.m. No Test10 bundle changes, no installed Agent/preferences changes, no original writable disks.

Owned76816: actual production AX lookup fixture compared baseline/candidate/return. New default-OFF PE_FOCUS_LAZY_SHEETS defers recursive sheet enumeration until root windows fail to match, retaining root-first order and session/recovery behavior. Twelve normal-window iterations matched exact AX identity: mean13.836/12.316/13.323ms. Four attached-sheet iterations13.388/13.362/13.337ms, exact identity/relationship passes. Only about1–1.5ms benefit, not a noticeable user improvement; keep OFF. Source guest/tools/pefocussheetscheck.m, log build/harmony-switch-2026-10-16/live-76816.log.

Owned77582: actual production capture profile using retained own-window tile fixture. Fourteen candidate/full-reference pairs decoded byte-identically; detailed640x480 source shows full compression roughly100ms and capture roughly30ms after warmup; sparse tile responses roughly50–57ms. This measures capture/encode only, not host delivery/focus/input-to-photon. Existing tile path already enabled in Test10; not a new improvement. Complete packets/profile retained capture-77582.{log,packets}, independent bounded packet decoder validate-packets.py.

Owned78752: attempted flat-document tile eligibility experiment; all14 exact pixel comparisons passed, but runs0–9 used encoding4 even in baseline, so workload did NOT exercise the proposed flat-image bypass. Remaining cases dense/resize/stale-base/no-tile fallback; no comparative speed claim. Removed experimental PE_CAPTURE_FLAT_TILES gate from production source; archived source and fixture beside flat-78752.{log,packets}. Do not promote or label this speedup. Remote compiler staging source still has archived gate; resync before future compile.

All three owned VMs stopped before480second guard, exact two-display config restored and internal frontend stopped; final inventory clear. Original Agent untouched. Only lazy-sheet default-off source/fixture retained. Next: actual Test10 end-to-end switching trace, newly active window request/focus ack/first changed decoded frame separated from prior background in-flight capture. Retained host PEFRAMEBATCH means alone cannot attribute guest capture versus encode/transfer or switching latency. Avoid another isolated lookup optimization or flat fixture without proving target branch. Query SwiftPM bin path; current build output may be compact diagnostic and dirty host owner draft remains unshipped. No commit/push/release.


## Test11 — measured Word switching improvement; ready for user verification

Preserved exact Test10 host/backend and baseline bundle hashes. Separate signed `build/staging-hourly/PowerEmu Harmony Switching Test 11.app` enables only PE_FOCUS_LAZY_SHEETS in its bundled Tools2.24 payload. Reinstall bundled Tools and restart Tiger. No popup suppression, async focus, menu-report deferral or diagnostic phase instrumentation shipped. Production source default remains OFF.

Actual Word phase tracing found confirmation root lookup cost212–233ms; early menu-report deferral did not give a reliable benefit and was rejected. Same owned85064/app instances candidate→baseline→candidate Word request-to-ack medians218.006→268.326→221.481ms (three switches per group), about18% improvement or47–50ms. Finder results mixed. This is not FPS or physical input-to-photon measurement. Previous exact root/sheet identity fixture and production PPC stale-session/recovery fixture pass. Evidence: build/harmony-switch-2026-10-16/qualified-focus-summary.json and retained switch logs.

Clean owned86744 installed exact final Agent0c8b476707163d57a0e55e2a4d0ddd8c/Info bd2eb5b1c009dd411894b0e305f8fca8. CUA TextEdit typing visibly abcd, two Save/Escape cycles and Harmony exit/reentry passed; two HARMONYREADY true events and continued frames retained. Attempted Cancel click hit Where dropdown, so click-Cancel unqualified. No new Word font-value or Office-crash fix claim. Mounted ISO exact payload/flags and strict app signature pass; unsigned host equals Test10. Stage and ISO receipts retained.

All owned VMs stopped before guard. Original Agent/Info restored and verified, exact two-display config and internal frontend Info restored, internal app re-signed/verified. No running emulator; user disks untouched. Test10 bundle hashes unchanged. Pause autonomous VM/GUI tests while user verifies Test11; active-window refresh improvement remains outstanding. No commit/push/release.


### Test11 verification interval — offline refresh review

No VM/GUI interaction or production/build changes. Reviewed HarmonyCaptureScheduler and complete-window receive/decode/publication path. Foreground already bypasses background due deadlines, with four-request bursts (six after interaction); completed frames immediately request the next capture. One outstanding request deliberately remains through decode/publication to preserve accepted delta-base and session/proxy identity. Do not blindly pipeline requests or raise timer frequency.

Retained clean86744 cumulative decode mean0.014ms versus request-to-receipt27.2ms; repeat85064 decode0.029ms versus37.7ms. These are mixed-window/idle cumulative means, not active FPS or tail latency. Decode timing excludes main-thread dispatch wait and publication/reconcileSheets. Therefore additional decoder parallelism has little evidence of benefit; main-thread publication delay remains unmeasured. Machine-readable summary build/harmony-switch-2026-10-16/offline-refresh-review.json.

Next authorized live measurement should use bounded per-request monotonic timestamps for request, receipt, decode completion, main-thread entry, publication and next request, joined by session/sequence/window identity and pixel counter. Separate background capture blocking from guest capture/encoding and host dispatch/publication. Preserve single-flight/base checks; flush after test, not synchronous per-event logging. Source fixtures already show detailed full-frame compression can dominate, but don't extrapolate to normal documents or retry rejected flat-tile branch without proving eligibility. No new performance claim or build from this offline review; keep Test11 for user testing.
