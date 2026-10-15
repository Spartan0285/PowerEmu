# Harmony owner-filtered AX lookup candidate — October 15, 2026

`PE_FOCUS_OWNER_LOOKUP=1` enables a default-off lookup path in `guest/src/PEAgent.m`. It obtains the requested CGS window's owner connection, maps that connection back to a Process Manager PSN, revalidates the mapping, and queries only that process's AX windows and attached sheets. The existing geometry tolerance, minimized-window guard, focused-window identity check, sheet blocking checks, and caller behavior remain in place. An invalid or unresolvable owner returns no target; it never falls back to a geometry match in another process. With the variable unset or set to any value other than `1`, the legacy all-process lookup remains active.

All four wid-bearing paths use the wrapper: raise, focus confirmation, move, and minimize. No focus, raise, move, or input event is performed by the lookup fixture itself after its disposable window/sheet setup.

## Bounded comparison fixture

`guest/tools/pefocusownercheck.m` has an external read-only mode: `pefocusownercheck WINDOWID EXPECTEDPID`. It calls `NSApplicationLoad` and reads the existing CGS rectangle, with no test-window creation or activation. It first requires the legacy AX lookup to resolve the expected PID and matching geometry, then performs 12 ordered baseline/candidate/return lookups. It compares AX element identity and CGS/AX geometry and checks the CGS owner maps to the expected PID. If the target exposes an attached sheet, it also checks sheet-parent identity. It reports Process Manager and AX-window scan counts plus monotonic and CPU timings, and fails closed on a candidate lookup with an invalid window id. `alarm(30)` and line-buffered output bound and retain evidence if Accessibility IPC stalls. It requires Accessibility access in the disposable Tiger session and does not change AX permissions.

The first live own-window fixture attempt failed before scoring any comparison: the legacy AX lookup returned PID0 for its self-owned Cocoa window (`build/harmony-owner-lookup/oct15-live.log`). No focus or input was sent. This failure remains retained; the strict own-window and required-sheet checks have not been relaxed. The external mode was added to test a real existing app window instead. Its staged launcher passes Finder window40 / PID188 and is at `build/harmony-owner-lookup/PEFocusOwnerCheck.app/`.

The trusted `ibookip` host compiled both PowerPC artifacts with gcc-4.0 and the actual10.4u SDK. Outputs are copied locally under `build/harmony-owner-lookup/`:

- `pefocusownercheck-ppc` SHA-256 `54c8e6f38cb3f63329e4972f8833a46fe8dc1e628f4694fd749bf40aea6327fa`
- `PowerEmuAgent-ownerlookup-candidate.ppc` SHA-256 `d6f909da3dd888424213cbd40cc832f44dfe00707e9b6a59a89f8d1b71998135`

The remote staging preserved the pre-change `/tmp/pe-harmony-format/src/PEAgent.m` as `PEAgent.ownerlookup-baseline.m` (MD5 `71340af209358f536a54c7c730b22b53`). The candidate was compiled in `/tmp/pe-focus-ownerlookup`; existing staged source and agent binaries were not overwritten. The updated external fixture compiled successfully with only the repository's existing `send:text:` declaration warning and was staged into the launcher bundle. No owner-filtered live comparison has yet completed. Its live identity and timing results are still required before considering this candidate for any test build.

## Actual Tiger read-only result

Owned60533/480sec guard. First self-window fixture failed baseline resolution(pid0); retainedunscored in evidence/harmony-focus-owner-2026-10-15/oct15-live.log. Subsequent external READ-ONLY Finder wid40/PID188 comparison passed all12 baseline/candidate/return identities, exact geometry, owner mapping, invalid-ID rejection; exposedsheet0 so sheet behavior unverified. Mean elapsed28.729/28.016/28.336ms. This does not establish a worthwhile speedup; leave owner filterOFF. Source scan-count field counts both process enumeration and eligible-process visit and is not a pure AX-query count. Allobservations retained in oct15-finder-external.log. VMstopped beforedeadline. Next target is bounded asynchronous AX focus confirmation/raise, with sequence/cancellation and actual pending-input safety preserved; simply filtering lookup owner did not solve input delay.
