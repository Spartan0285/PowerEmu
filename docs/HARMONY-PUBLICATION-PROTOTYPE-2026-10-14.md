# Harmony cooperative publication experiment — October 14, 2026

## Result

Implemented and ran an isolated Tiger cooperative pixel exporter and native host receiver. Three runs each completed 240 changing sequence publications, all host pixels verified, no replaced/dropped jobs or guest/worker errors, and six exact complete-window reference captures per run. Covered updates and resize passed with consistent direct orientation. This establishes a correct cooperative source/transport boundary. **It does not improve Finder/Word, establish scanout FPS, or pass the performance gate.**

The installed signed Harmony test build and normal capture fallback remain unchanged by this experiment. Cursor and Dock fixes remain installed. No original guest disk, production graphics/audio code, or tools release was changed. The owned isolated VM was stopped after retention.

## Measurements

| Run | Sequence publications/sec | Commit→ACK median / p95 | Private capture range | Capture flush maximum |
|---|---:|---:|---:|---:|
| First | 12.13 | 49.32 / 99.94 ms | 56.06–114.02 ms | 0.253 ms |
| Repeat | 10.13 | 51.91 / 121.50 ms | see retained six references | 0.040 ms |
| Drawing breakdown | 11.58 | 51.37 / 83.93 ms | see retained six references | 0.354 ms |

Final run source generation/immutable copying median34.54ms, p9552.56ms; AppKit display median20.02ms, p9541.72ms; explicit window flush median0.049ms, p950.148ms. Host transfer+decode+full-pixel verification median2.11ms/p954.35ms; main-queue wait+resize+layer commit/flush median1.97ms/p952.43ms. This supports separating guest rendering, private capture, and delivery. It does not identify a single universal cause of ordinary-app latency.

Guest timings use initialized `mach_absolute_time` conversion; host timings use host uptime. Only elapsed values are compared: no cross-domain absolute subtraction. ACK follows layer commit/flush, not physical display. Six synchronous reference captures delay producer ticks; throughput is validation-loaded, not a transport ceiling. Source pattern repeats every12 generations; every adjacent publication in these runs changed pixels. Source generation is additional fixture work and must not be mistaken for unavoidable real-app capture cost.

## Implementation and gates

- `guest/tools/pewindowpublish.m`: standalone Aqua fixture owns only its two test windows; immutable RGBA source, one executing and one replaceable pending frame, bounded240 timing rows/six references, stopped logging,25sec deadline. TCP to slirp host10.0.2.2, ephemeral authenticated receiver; not production capability negotiation.
- `tools/harmony-publish/Host.swift`: actual `HarmonyWindowFrame` decoder; validates nonce, bounded headers/payloads, sequence/dimensions/every source pixel, tracks distinct changing publications, publishes to a native layer, ACKs, requires final sequence240.40sec deadline.
- `tools/harmony-publish/analyze.py`: requires full guest240 summary, sent+replaced240, no errors, six exact references with consistent orientation, host/guest sequence and count equality, final240. Never treats one successful frame as a complete run.
- `tools/harmony-publish/fixture.py`: independent RLE generator tests valid covered/resize phase sequences, wrong identity, oversized payload, duplicate sequence, and damaged pixels. All five pass.

Receiver build:

```sh
xcrun swiftc -O -parse-as-library tools/harmony-publish/Host.swift app/Sources/PowerEmu/HarmonyWindowFrame.swift -o build/harmony-publish-host -lz
python3 tools/harmony-publish/fixture.py build/harmony-publish-host
```

Guest builds against verified10.4u SDK using gcc4.0/PPC; only unused included helper warning. Launch as an Aqua `.app`, not an SSH console NSApplication. Run only on independent clone with bounded owned-process guard. Receiver emits owner-only `RESULT.json.config` containing port/nonce; transfer through established strict guest SSH, never expose credentials or loosen key validation. Reference logs/JSON/summaries are retained under `docs/evidence/harmony-publication-2026-10-14/`.

## Next work

1. Do not promote this as a responsiveness build: 720frames is below the proposed1000-frame correctness gate, rate below30, p95ACK above33ms, and no input latency measurement exists.
2. Avoid extra pattern-generation work in the next transport control; retain a realistic drawing control separately. Split guest packing/queue/send/ACK costs before attributing the round trip to transport. This is diagnostic, not an ordinary-app fix.
3. Establish a real application's existing completed backing-store ownership, byte format/stride, bounds, lifetime and damage/flush boundary on the actual Tiger build. No guessed pointers/API names or screenshot crops. Research ownership failures rule out treating CGS owner connection IDs as authorization.
4. Start with read-only bounded access to one 2D window in the clone, compare against complete covered/resize reference captures. Keep accelerated/uncertain windows on complete capture; no WindowServer/system-framework modification in the first experiment.
5. Only after that succeeds, integrate capability negotiation/session generations/accepted-base recovery into actual Harmony and measure matched click-to-visible latency, changing images, covered correctness, and audio contention. Native host wrapping already exists and is not the established bottleneck.
