# Adaptive Harmony capture scheduling

September 28, 2026. Candidate: `build/Harmony Adaptive Refresh/PowerEmu.app`.

Host-only scheduling change. Bundled Tools remain **2.11**, including the previous exclusive-fullscreen detection. No Tools reinstall is needed if 2.11 is already running. The running VM is not replaced.

## Behavior

- The host's active guest proxy, or its pending guest-focus target, gets foreground priority. While PowerEmu is inactive, the guest's last-focused window no longer receives that priority.
- Foreground images remain completion-driven without idle delays. At most three foreground requests precede a due background request; background requests use oldest-completed order.
- Visible background windows back off after repeated unchanged images: 100, 200, 400, then 800 ms after completion. Covered windows can back off to 2 seconds. A changed image resets the delay to 50 ms. These are eligibility delays, not guaranteed update intervals; capture time and contention add latency.
- First images and resized windows take priority. Focus bypasses idle delays; an uncover notification invalidates the delay. Failed captures retry after 500 ms so an unsupported window cannot monopolize first-image priority.
- The existing one-request/one-decode limit, immutable complete images, stale-sequence and proxy checks remain. Minimize/restore behavior is unchanged. No guest damage-notification mechanism is claimed or introduced.

## Checks and evidence

`app/Tests/Harmony/CaptureScheduling.swift` exercises foreground/background fairness, stationary backoff, host inactivity, focus changes, changed/uncovered windows, first-image priority, failed-capture retries and window-ID reuse. Existing title-click and Dock restore regressions also pass. The production app build and deep/strict signature verification pass. Live responsiveness and CPU usage remain to be compared in the guest.

A deterministic simulation uses four visible windows and a fixed 40 ms capture cost, with one changing foreground window and three stationary background windows. Over 50 seconds after warmup:

| Policy | Foreground captures | Each background window |
| --- | ---: | ---: |
| Previous | 833 | 139 |
| Adaptive | 1,070 | 60 |

This is a scheduling simulation, **not measured guest FPS or a measured CPU saving**. Its fixed capture cost omits real transport, guest workload, host timer jitter and differences between changed/unchanged captures. A separate continuously-changing workload checks that all background windows continue receiving captures.

## Live validation

Compare the same workload on the previous Fullscreen Refresh build and this candidate. With several stationary windows open, type, scroll or animate in the active window. Then switch to a host app and back, uncover guest windows, resize, and minimize/restore. Check a background progress indicator: its first update after a long quiet period can wait for the background polling interval; subsequent changed frames receive more frequent service. Background animation shares capture time with the foreground and is not promised foreground frame rates.

If this tradeoff proves too noticeable, reduce the visible idle cap based on the measured workload. The next architectural investigation is a reliable guest damage signal, which could eliminate polling delay without resuming constant capture of unchanged windows.
