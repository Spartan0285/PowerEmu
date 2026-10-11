# Downstream scheduling discriminator after prompt command admission

## What the existing evidence establishes

Actual run 166 offers about 47.462 seconds of queued audio during a 60-second observer epoch while the device consumes 59.604 seconds. Individual fills complete well before their buffers are handed off. Queued native references 5/6 are intact; qualified native reference 6 is damaged before DMA consumption, then the host faithfully reproduces that waveform. This is underfeeding of the running device, not evidence to slow DMA or enlarge the host queue.

The retained ordinary Warcraft crash stack provides important dispatch provenance: `MacSS_GlobalCallback` is invoked by `InvokeSndCallBackUPP → ProcessCmd → ProcessNextCmd → SoundComplete`, inside SoundManager's `BigEndian16DecompDispatch → IOA_Device::CallIOProcs → HP_IOThread::PerformIO → HP_IOThread::WorkLoop`. In this actual Tiger build the callback executes on the CoreAudio hardware I/O thread. It is not dispatched by the game's main UI/event loop. Older documentation describing interrupt-time callbacks must not substitute for this observed Tiger thread.

Actual import relocation proves Miles uses SndDoImmediate for bufferCmd and SndDoCommand(..., true) for callBackCmd. Apple's original buffered-sound example recommends that combination. Changing it to a queued buffer command or synchronous callback would be an unsupported detour.

## Smallest next observation if admission succeeds promptly

Observe the actual existing SoundManager IOProc invocation that encloses the Miles callback, not a newly registered helper. Use one bounded native-reference window, no new audio client. Freshly identify the actual current CoreAudio/SoundManager component mappings and resolve their executing IOProc/HP_IOThread call boundary from the current copied code and runtime callback stack. The older crash PCs establish direction only; never use them as a fresh instruction manifest.

At that verified boundary, retain call entry/return, current actual thread/stack scope, the real `inNow` and output AudioTimeStamp sampleTime/hostTime/flags, and output frame capacity. Interpret arguments using the actual Tiger AudioDeviceIOProc ABI and executing call-site disassembly. Pair the nested Miles callback and buffer-command admission inside that same invocation. Process/address-space identity must be proven; shared framework PC/TOC and common stack addresses alone do not identify Warcraft. Record memory read intervals, reject pointer/format/identity errors, and retain only bounded preallocated scalar data.

This distinguishes two falsifiable cases:

1. The hardware I/O thread arrives late, sampleTime jumps, or its output interval has already passed when the converter requests a Miles buffer. The cause is guest scheduling/clock-to-deadline handling below the game. Correlate with actual device FRAME_CNT and virtual-time progression; do not relabel a stale output timestamp as healthy just because admission returned zero.
2. Actual HAL invocations remain regular with continuous sampleTime, but SoundComplete/callBackCmd service and source consumption occur too sparsely. The cause is SoundManager converter/command progression or missed buffer boundary inside an otherwise healthy I/O thread. The next narrower target is that existing converter's source-read/copy/callback boundary, not IRQ priorities or the game's UI loop.

A successful command status proves only acceptance. Immediate return duration includes observer work. Offered frames divided by elapsed time proves a service deficit but does not identify which scheduling domain omitted the work. Do not repeat CPU/GPU/period/format permutations or patch the clock based on averages.

## Emulator contract checks already relevant

Screamer advances FRAME_CNT only for actual DMA frames and paces DMA on QEMU virtual time. Retained run 166 has approximately 59.998 seconds of virtual progression and no frame-counter reset over the 60-second epoch, ruling out a global clock slowdown as the explanation for only 47.462 seconds of offered content. The earlier source-window FRAME_CNT-read-age gate did not find material stale counters, and IRQ admission was prompt in its retained control. Neither proves that the guest hardware I/O thread met its deadlines; the proposed existing-client timestamps address that specific missing fact.

## Primary-source context

- [Apple Inside Macintosh callback contract (archived Apple-authored documentation)](https://leopard-adc.pepas.com/documentation/mac/Sound/Sound-130.html): a channel callback runs when Sound Manager processes callBackCmd. This does not establish Tiger's dispatch thread; the actual crash stack does.
- [Apple develop issue 23, buffered-sound example (archived Apple publication)](https://vintageapple.org/develop/pdf/develop-23_9509_September_1995.pdf): buffered playback example uses SndDoImmediate(bufferCmd) followed by SndDoCommand(callBackCmd).
- [Apple AudioDeviceIOProc documentation](https://developer.apple.com/documentation/coreaudio/audiodeviceioproc?language=objc): inNow includes I/O-thread wake scheduling latency. Use the actual Tiger SDK ABI and flags before interpreting a retained timestamp, rather than assuming a modern API layout.

Read-only second opinion; no guest operation, build, launch or production change performed.
