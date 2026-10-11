# Read-only clock-domain review

No clock patch is justified. The queue deficit is a real service-rate observation; it is not presently evidence that guest clock time runs at that deficient rate.

## What current source establishes

TCG Core99 initializes every CPU timebase at 25,000,000 Hz (`hw/ppc/mac_newworld.c:82,199`). `hw/ppc/ppc.c:509–525` derives TB from QEMU_CLOCK_VIRTUAL multiplied by that frequency plus the per-CPU TB offset. Screamer `hw/audio/screamer.c:550–573` derives due frames from the same QEMU_CLOCK_VIRTUAL delta multiplied by its negotiated sample rate. `system/cpus.c:213` and `system/cpu-timers.c:73–97` provide the virtual clock; actual MTTCG excludes icount. Running clock is host monotonic plus pause offset, not a count of emulated executed instructions. Thus CPU starvation can delay execution while both device and guest clock time advance.

Reported processor frequency in `CPUOptions.swift:46–51` only writes CPU node clock-frequency. It does not change TBFREQ or Screamer rate. `guest/src/PEClock.c:correct` changes calendar time through settimeofday/adjtime. There is no call that sets hardware TB or the Screamer frame count. Calendar adjustment and kernel monotonic/mach-clock implementation are separate; do not infer a measured mach slope merely from this daemon's calendar correction.

The source still allows per-CPU TB offsets and TB stop/start/store operations. Present evidence does not independently prove installed Tiger mach_absolute_time has no migration-related discontinuity, nor measure its rate against host monotonic in the latest scored window.

## Quantitative bounds from retained artifacts

Actual `oct10-sm-live-ownership.guest-abi.json` reports numerator 1,000,000,000 / denominator 24,949,183. If mach_absolute_time ticks follow the fixed emulated TB, this conversion predicts guest mach nanoseconds advance 1.002036820 host/virtual nanoseconds: **+0.2037%**. It predicts a slightly faster guest clock. It is not proof of actual tick source or offset stability.

Valid 78144 queue audit offers 53.8702948 seconds of negotiated 44,100-Hz frames across 59.960158 seconds of host clock: fraction 0.898434837, deficit **10.157%**. Callback median48.521ms is **4.481%** above a 2048-frame46.4399ms period. The nominal calibration discrepancy is much smaller and has the wrong simple direction for a late guest timer. The long service intervals and tails are not a uniform frequency ratio.

Fresh FRAME_CNT reads matching actual TX consumption rule out lazy counter advancement, not guest mach↔host slope, per-CPU TB discontinuity, or downstream CoreAudio timestamp service delay. Full host callback supply means raw DMA continues to arrive; it does not prove the correct source arrives on schedule.

## One smallest falsifiable discriminator

During the next existing unscored combined setup, add a **CLI-only**, bounded clock bracket, without registering any audio client or running during the scored reference window. Reuse a single strict owned SSH process. For 12 request/reply exchanges spread across ten seconds, host records CLOCK_MONOTONIC immediately before sending one byte and immediately after receiving a finite response. Guest records mach_absolute_time and the exact current mach_timebase_info after receipt and before writing response. Store only these finite samples, not hot-path file logs. Request/reply transport and scheduling place each guest tick inside a known host interval. Never substitute wall UTC or Python monotonic_ns.

Use first/last low-width brackets to calculate rigorous slope bounds: guest_delta_ns / host_delta_max and guest_delta_ns / host_delta_min. Reject the experiment if network/scheduling bracket widths cannot constrain slope to ±0.5%, if the guest suspends/restarts, or if epochs/timebase change. Preserve every bound rather than averaging away scheduling uncertainty. Check intermediate intervals for guest steps outside the brackets; a step means investigate per-CPU TB offsets/actual kernel tick source, not change audio buffering.

Simultaneously use the already available bounded producer trace to compare FRAME_CNT delta/rate against host delta across a stable active epoch, excluding resets/channel stops. No new device recorder is needed. This gives three independently labeled relationships: guest mach↔host; DMA frames↔host; admitted queue frames↔host. A ten-percent slow mach slope with DMA near44100Hz would preserve the clock-skew hypothesis. Mach slope near1 (or expected1.002) and DMA near44100Hz while queue stays~0.898 rules out steady clock skew as the dominant cause and redirects effort to SoundManager/CoreAudio execution/service. It does not rule out short scheduling gaps or stale audio timestamps.

Do not repeat CPU/GPU/period configurations. Do not slow the emulated DAC, alter firmware frequency, resample or offset timestamps based on this report. The test can be combined with the next necessary ownership setup and then stopped; no new quality trial is required merely to obtain a clock slope.
