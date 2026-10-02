/*
 * PESoundComponent -- a Sound Manager output device ('sdev') for
 * poweremu-audio, and a test application that registers it.
 *
 * The NDRV owns the device and proves it works, but nothing in Mac OS
 * routes audio to it: the Sound Manager plays through a sound output
 * device component, and the one in ROM drives the built-in AWACS.  This
 * is the component that puts our device in that list.
 *
 * It talks to the hardware directly rather than through the NDRV.  That
 * is not a shortcut around the Device Manager -- it is the one thing a
 * component may do that the driver may not.  A driver flagged
 * kDriverIsLoadedUponDiscovery is prepared during PCI enumeration, before
 * the file system exists, so it can only call libraries in ROM; a
 * component is loaded from disk long afterwards, when the Name Registry,
 * the Time Manager and everything else are available.  So the component
 * looks the device up the honest way, with RegistryPropertyGet, where the
 * driver has to be handed its addresses by the loader.
 *
 * The model is pull, not push.  The Sound Manager puts a mixer upstream of
 * us and we ask it for frames: a Time Manager task runs while the device
 * is playing, works out how much room the ring has, and calls
 * SoundComponentGetSourceData on the source until it is full again.  The
 * mixer converts to whatever format we advertise in GetInfo, so by saying
 * 44100 Hz, 16-bit, stereo -- the one format the device has -- we never
 * have to convert anything ourselves.
 *
 * Built as an application for now.  RegisterComponent with global set
 * installs it system-wide for the session, which means it can be tested
 * without writing anything into the System Folder; the guest's volume is
 * HFS+ inside an HFS wrapper, which hfsutils cannot write.  Packaging it
 * as a 'thng' in Extensions comes after it works.
 */

#include <stdio.h>
#include <string.h>
#include <MacTypes.h>
#include <Components.h>
#include <Sound.h>
#include <Timer.h>
#include <Devices.h>
#include <MixedMode.h>

/*
 * The Name Registry proper.  PEAudioProbe declares these by hand because
 * Retro68's multiversal headers do not cover them; this is built against
 * Apple's Universal Interfaces, which do.
 */
#include <NameRegistry.h>

/* The device. */
#define PEAU_ID          0x00
#define PEAU_RING_SIZE   0x14
#define PEAU_RATE        0x18
#define PEAU_FORMAT      0x1c
#define PEAU_CONTROL     0x20
#define PEAU_WRITE_PTR   0x24
#define PEAU_READ_PTR    0x28
#define PEAU_RING_BYTES  0x30

#define PEAU_MAGIC       0x50454155UL
#define PEAU_CTL_RUN     0x00000001UL
#define PEAU_CTL_FLUSH   0x00000002UL

/*
 * A private GetInfo selector that runs the refill once and reports how
 * many frames are queued.  The pull normally happens on a Time Manager
 * task, at interrupt time, the way a real card does it from its DMA
 * interrupt; this lets the audio path be driven from task level instead,
 * so that the ring and the hardware can be proved before anything depends
 * on interrupt-time behaviour.
 */
#define siPERefill       FOUR_CHAR_CODE('PErf')
#define PEAU_FRAME_BYTES 4

#define PE_RATE          44100UL
#define PE_NODE_NAME     "pci1b36,5045"

#define kPESoundSubType       FOUR_CHAR_CODE('PEau')
#define kPESoundManufacturer  FOUR_CHAR_CODE('PEmu')

/* How often the task wakes to refill, and how full it tries to keep the
   ring.  20 ms is short enough that a 371 ms ring never runs dry and long
   enough that the task is not a burden. */
#define PE_TICK_MS       20
#define PE_TARGET_MS     120

/* The most a source is expected to hand over in one pull. */
#define PE_PULL_FRAMES   2048

typedef struct PEGlobals {
    ComponentInstance   self;
    ComponentInstance   source;         /* the mixer above us */
    SoundComponentData  format;
    volatile UInt32    *regs;
    volatile SInt16    *ring;
    UInt32              ringFrames;
    UInt32              writePtr;       /* frames, free-running */
    Boolean             running;
    Boolean             taskInstalled;
    TMTask              task;
    long                hwVolume;       /* siHardwareVolume, 0..0x0200 */
    Boolean             hwMute;
} PEGlobals;

static PEGlobals *gActive;              /* the task has no refcon of its own */

/* ---------------------------------------------------------------- device */

static OSStatus PEFindDevice(PEGlobals *g)
{
    RegEntryIter iter;
    RegEntryID   entry;
    Boolean      done = false;
    OSStatus     err;
    char         path[512];
    UInt32       assigned[10];
    RegPropertyValueSize size;

    err = RegistryEntryIterateCreate(&iter);
    if (err != noErr) {
        return err;
    }
    for (;;) {
        err = RegistryEntryIterate(&iter, kRegIterContinue, &entry, &done);
        if (err != noErr || done) {
            break;
        }
        if (RegistryCStrEntryToPath(&entry, path, sizeof(path)) == noErr &&
            strstr(path, PE_NODE_NAME) != NULL) {
            RegistryEntryIterateDispose(&iter);

            size = sizeof(assigned);
            memset(assigned, 0, sizeof(assigned));
            err = RegistryPropertyGet(&entry, "assigned-addresses",
                                      assigned, &size);
            if (err != noErr || size < 40) {
                return (err != noErr) ? err : (OSStatus)paramErr;
            }
            /* Five words per BAR: BAR 0 is the registers, BAR 1 the ring. */
            g->regs = (volatile UInt32 *)assigned[2];
            g->ring = (volatile SInt16 *)assigned[7];
            if (g->regs == 0 || g->ring == 0) {
                return paramErr;
            }
            if (g->regs[PEAU_ID / 4] != PEAU_MAGIC) {
                return paramErr;
            }
            g->ringFrames = g->regs[PEAU_RING_BYTES / 4] / PEAU_FRAME_BYTES;
            return noErr;
        }
        RegistryEntryIDDispose(&entry);
    }
    RegistryEntryIterateDispose(&iter);
    return nrNotFoundErr;
}

static UInt32 PEFreeFrames(PEGlobals *g)
{
    UInt32 queued = g->writePtr - g->regs[PEAU_READ_PTR / 4];

    if (queued > g->ringFrames) {
        queued = g->ringFrames;         /* the device ran away; resync */
    }
    return g->ringFrames - queued;
}

/*
 * Ask the source for frames until the ring is as full as we want it.
 *
 * Runs from a Time Manager task, which is interrupt time -- the same place
 * a real card would do this from its DMA interrupt.  Nothing here
 * allocates or moves memory, which is what makes that safe.
 */
static void PERefill(PEGlobals *g)
{
    UInt32 target = (PE_RATE * PE_TARGET_MS) / 1000;
    int guard = 32;                     /* never spin here */

    if (!g->running || !g->source) {
        return;
    }
    if (target > g->ringFrames) {
        target = g->ringFrames;
    }

    while (guard-- > 0) {
        SoundComponentDataPtr data = NULL;
        UInt32 queued = g->ringFrames - PEFreeFrames(g);
        long   got, i;

        if (queued >= target) {
            break;
        }
        /*
         * Only ask when there is certainly room for an answer.  The source
         * hands over a whole buffer and considers it delivered, so taking
         * less than it gives loses the rest -- which is what happened when
         * this clamped the count to the free space instead: the ring
         * filled, every further pull was discarded, and the sound stopped
         * part way through with the source's position far ahead of what
         * had actually been played.
         */
        if (PEFreeFrames(g) < PE_PULL_FRAMES) {
            break;
        }
        if (SoundComponentGetSourceData(g->source, &data) != noErr ||
            data == NULL || data->buffer == NULL || data->sampleCount <= 0) {
            break;
        }

        got = data->sampleCount;
        if ((UInt32)got > PEFreeFrames(g)) {
            got = PEFreeFrames(g);      /* should not happen; never overrun */
        }
        for (i = 0; i < got; i++) {
            UInt32 idx = (g->writePtr + i) % g->ringFrames;
            const SInt16 *src = &((const SInt16 *)data->buffer)[i * 2];

            g->ring[idx * 2 + 0] = src[0];
            g->ring[idx * 2 + 1] = src[1];
        }
        g->writePtr += got;
        g->regs[PEAU_WRITE_PTR / 4] = g->writePtr;

        if (got < data->sampleCount) {
            break;                      /* ring is full */
        }
    }
}

static pascal void PETimerProc(TMTaskPtr tmTaskPtr)
{
    PEGlobals *g = gActive;

    if (g && g->running) {
        PERefill(g);
        PrimeTime((QElemPtr)&g->task, PE_TICK_MS);
    }
#pragma unused(tmTaskPtr)
}

static void PEStartHardware(PEGlobals *g)
{
    g->writePtr = 0;
    g->regs[PEAU_RATE / 4]      = PE_RATE;
    g->regs[PEAU_FORMAT / 4]    = 0;
    g->regs[PEAU_RING_SIZE / 4] = g->ringFrames * PEAU_FRAME_BYTES;
    g->regs[PEAU_WRITE_PTR / 4] = 0;
    /*
     * FLUSH as well as RUN, so the device's consumer index is set to ours
     * rather than left where the last user put it.  Without this the
     * driver's startup tone had advanced read_ptr to 0x4000; setting
     * write_ptr back to 0 then made the ring look permanently full --
     * queued came out as 0 - 0x4000, clamped to the whole ring -- and the
     * refill loop decided it had nothing to do and never wrote a frame.
     */
    g->regs[PEAU_CONTROL / 4]   = PEAU_CTL_RUN | PEAU_CTL_FLUSH;
}

static void PEStopHardware(PEGlobals *g)
{
    g->regs[PEAU_CONTROL / 4] = 0;
}

/* ------------------------------------------------------------- selectors */

static pascal ComponentResult PEOpen(PEGlobals *unused, ComponentInstance self)
{
    PEGlobals *g = (PEGlobals *)NewPtrClear(sizeof(PEGlobals));
#pragma unused(unused)

    if (g == NULL) {
        return MemError() ? MemError() : memFullErr;
    }
    g->self = self;
    g->format.flags       = 0;
    g->format.format      = kSoundNotCompressed;
    g->format.numChannels = 2;
    g->format.sampleSize  = 16;
    g->format.sampleRate  = PE_RATE << 16;      /* UnsignedFixed */
    g->format.sampleCount = 0;
    g->format.buffer      = NULL;
    g->hwVolume = 0x01000100;                   /* full, both channels */
    SetComponentInstanceStorage(self, (Handle)g);
    return noErr;
}

static pascal ComponentResult PEClose(PEGlobals *g, ComponentInstance self)
{
#pragma unused(self)
    if (g) {
        if (g->running) {
            g->running = false;
            PEStopHardware(g);
        }
        if (g->taskInstalled) {
            RmvTime((QElemPtr)&g->task);
            g->taskInstalled = false;
        }
        if (gActive == g) {
            gActive = NULL;
        }
        DisposePtr((Ptr)g);
    }
    return noErr;
}

static pascal ComponentResult PERegister(PEGlobals *g)
{
#pragma unused(g)
    return 0;                   /* 0 means "register me" */
}

static pascal ComponentResult PEVersion(PEGlobals *g)
{
#pragma unused(g)
    return 0x00010000;
}

static pascal ComponentResult PEInitOutputDevice(PEGlobals *g, long actions)
{
    OSStatus err;
#pragma unused(actions)

    if (g->regs) {
        return noErr;           /* already found it */
    }
    err = PEFindDevice(g);
    if (err != noErr) {
        return err;
    }

    gActive = g;
    return noErr;
}

static pascal ComponentResult PESetSource(PEGlobals *g, SoundSource sourceID,
                                          ComponentInstance source)
{
#pragma unused(sourceID)
    g->source = source;
    return noErr;
}

static pascal ComponentResult PEGetSource(PEGlobals *g, SoundSource sourceID,
                                          ComponentInstance *source)
{
#pragma unused(sourceID)
    *source = g->source;
    return noErr;
}

static pascal ComponentResult PEGetSourceData(PEGlobals *g,
                                              SoundComponentDataPtr *data)
{
    /* We are the end of the chain; nobody pulls from us. */
#pragma unused(g)
    *data = NULL;
    return badFormat;
}

static pascal ComponentResult PESetOutput(PEGlobals *g,
                                          SoundComponentDataPtr requested,
                                          SoundComponentDataPtr actual)
{
    *actual = g->format;
#pragma unused(requested)
    return noErr;
}

static pascal ComponentResult PEAddSource(PEGlobals *g, SoundSource *sourceID)
{
#pragma unused(g, sourceID)
    return noErr;
}

static pascal ComponentResult PERemoveSource(PEGlobals *g, SoundSource sourceID)
{
#pragma unused(sourceID)
    g->source = NULL;
    return noErr;
}

/*
 * What the Sound Manager asks before it decides how to talk to us.  Every
 * answer here is the one format the device has, so the mixer upstream does
 * all the conversion and this component never has to.
 */
static pascal ComponentResult PEGetInfo(PEGlobals *g, SoundSource sourceID,
                                        OSType selector, void *infoPtr)
{
#pragma unused(sourceID)
    switch (selector) {
    case siSampleRate:
        *(UnsignedFixed *)infoPtr = PE_RATE << 16;
        return noErr;
    case siSampleSize:
        *(short *)infoPtr = 16;
        return noErr;
    case siNumberChannels:
        *(short *)infoPtr = 2;
        return noErr;
    case siHardwareVolume:
    case siVolume:
        *(long *)infoPtr = g->hwVolume;
        return noErr;
    case siHardwareMute:
        *(short *)infoPtr = g->hwMute ? 1 : 0;
        return noErr;
    case siHardwareVolumeSteps:
        *(short *)infoPtr = 128;
        return noErr;
    case siQuality:
        *(long *)infoPtr = 0;
        return noErr;
    case siPERefill:
        PERefill(g);
        *(long *)infoPtr = (long)(g->ringFrames - PEFreeFrames(g));
        return noErr;
    default:
        return siUnknownInfoType;
    }
}

static pascal ComponentResult PESetInfo(PEGlobals *g, SoundSource sourceID,
                                        OSType selector, void *infoPtr)
{
#pragma unused(sourceID)
    switch (selector) {
    case siHardwareVolume:
    case siVolume:
        g->hwVolume = (long)infoPtr;
        return noErr;
    case siHardwareMute:
        g->hwMute = ((long)infoPtr != 0);
        return noErr;
    case siSampleRate:
    case siSampleSize:
    case siNumberChannels:
        return noErr;           /* fixed; the mixer converts */
    default:
        return siUnknownInfoType;
    }
}

static pascal ComponentResult PEStartSource(PEGlobals *g, short count,
                                            SoundSource *sources)
{
#pragma unused(count, sources)
    if (!g->regs) {
        return notOpenErr;
    }
    if (!g->running) {
        g->running = true;
        PEStartHardware(g);
        PERefill(g);
    }
    return noErr;
}

static pascal ComponentResult PEStopSource(PEGlobals *g, short count,
                                           SoundSource *sources)
{
#pragma unused(count, sources)
    if (g->running) {
        g->running = false;
        PEStopHardware(g);
    }
    return noErr;
}

static pascal ComponentResult PEPauseSource(PEGlobals *g, short count,
                                            SoundSource *sources)
{
    return PEStopSource(g, count, sources);
}

static pascal ComponentResult PEPlaySourceBuffer(PEGlobals *g,
                                                 SoundSource sourceID,
                                                 SoundParamBlockPtr pb,
                                                 long actions)
{
#pragma unused(sourceID, pb, actions)
    return PEStartSource(g, 0, NULL);
}

/* ------------------------------------------------------------- dispatcher */

/*
 * CallComponentFunctionWithStorage takes a UPP.  These functions are
 * native PowerPC, and a bare native pointer is not a UPP -- passing one
 * crashed the moment the Component Manager first called in, with a system
 * error 10 on OpenAComponent, while registration and FindNextComponent
 * had both worked because neither of those actually calls the code.
 * CallComponentFunctionWithStorageProcInfo is the variant that takes a
 * plain ProcPtr and is told the shape of the call instead.
 *
 * The procInfo describes the whole call, and these functions are reached
 * with the storage handle as their first argument, so it is parameter one
 * and the component's own parameters start at two.  Leaving it out shifted
 * every argument by one: GetInfo then wrote through whatever it took for
 * infoPtr and the Sound Manager read back 0 Hz, 0 channels, 0 bits.
 *
 * Every parameter is four bytes -- pointers, longs, Handle and
 * SoundSource, which is a pointer -- except the "short count" that
 * StartSource, StopSource and PauseSource take.
 */
#define PE_PROC0  (kPascalStackBased \
    | RESULT_SIZE(SIZE_CODE(sizeof(ComponentResult))))
#define PE_PROC1(a) (PE_PROC0 \
    | STACK_ROUTINE_PARAMETER(1, SIZE_CODE(a)))
#define PE_PROC2(a, b) (PE_PROC1(a) \
    | STACK_ROUTINE_PARAMETER(2, SIZE_CODE(b)))
#define PE_PROC3(a, b, c) (PE_PROC2(a, b) \
    | STACK_ROUTINE_PARAMETER(3, SIZE_CODE(c)))
#define PE_PROC4(a, b, c, d) (PE_PROC3(a, b, c) \
    | STACK_ROUTINE_PARAMETER(4, SIZE_CODE(d)))

#define PE_L  4         /* a long, a pointer, a SoundSource */
#define PE_S  2         /* a short */

#define PE_CALL(fn, procInfo) \
    CallComponentFunctionWithStorageProcInfo(storage, params, \
                                             (ProcPtr)(fn), (procInfo))

pascal ComponentResult PEAudioComponentEntry(ComponentParameters *params,
                                             Handle storage);

pascal ComponentResult PEAudioComponentEntry(ComponentParameters *params,
                                             Handle storage)
{
    switch (params->what) {
    case kComponentOpenSelect:
        return PE_CALL(PEOpen, PE_PROC2(PE_L, PE_L));
    case kComponentCloseSelect:
        return PE_CALL(PEClose, PE_PROC2(PE_L, PE_L));
    case kComponentRegisterSelect:
        return PE_CALL(PERegister, PE_PROC1(PE_L));
    case kComponentVersionSelect:
        return PE_CALL(PEVersion, PE_PROC1(PE_L));
    case kComponentCanDoSelect:
        switch ((short)params->params[0]) {
        case kComponentOpenSelect:
        case kComponentCloseSelect:
        case kComponentRegisterSelect:
        case kComponentVersionSelect:
        case kComponentCanDoSelect:
        case kSoundComponentInitOutputDeviceSelect:
        case kSoundComponentSetSourceSelect:
        case kSoundComponentGetSourceSelect:
        case kSoundComponentGetSourceDataSelect:
        case kSoundComponentSetOutputSelect:
        case kSoundComponentAddSourceSelect:
        case kSoundComponentRemoveSourceSelect:
        case kSoundComponentGetInfoSelect:
        case kSoundComponentSetInfoSelect:
        case kSoundComponentStartSourceSelect:
        case kSoundComponentStopSourceSelect:
        case kSoundComponentPauseSourceSelect:
        case kSoundComponentPlaySourceBufferSelect:
            return 1;
        default:
            return 0;
        }

    case kSoundComponentInitOutputDeviceSelect:
        return PE_CALL(PEInitOutputDevice, PE_PROC2(PE_L, PE_L));
    case kSoundComponentSetSourceSelect:
        return PE_CALL(PESetSource, PE_PROC3(PE_L, PE_L, PE_L));
    case kSoundComponentGetSourceSelect:
        return PE_CALL(PEGetSource, PE_PROC3(PE_L, PE_L, PE_L));
    case kSoundComponentGetSourceDataSelect:
        return PE_CALL(PEGetSourceData, PE_PROC2(PE_L, PE_L));
    case kSoundComponentSetOutputSelect:
        return PE_CALL(PESetOutput, PE_PROC3(PE_L, PE_L, PE_L));
    case kSoundComponentAddSourceSelect:
        return PE_CALL(PEAddSource, PE_PROC2(PE_L, PE_L));
    case kSoundComponentRemoveSourceSelect:
        return PE_CALL(PERemoveSource, PE_PROC2(PE_L, PE_L));
    case kSoundComponentGetInfoSelect:
        return PE_CALL(PEGetInfo, PE_PROC4(PE_L, PE_L, PE_L, PE_L));
    case kSoundComponentSetInfoSelect:
        return PE_CALL(PESetInfo, PE_PROC4(PE_L, PE_L, PE_L, PE_L));
    case kSoundComponentStartSourceSelect:
        return PE_CALL(PEStartSource, PE_PROC3(PE_L, PE_S, PE_L));
    case kSoundComponentStopSourceSelect:
        return PE_CALL(PEStopSource, PE_PROC3(PE_L, PE_S, PE_L));
    case kSoundComponentPauseSourceSelect:
        return PE_CALL(PEPauseSource, PE_PROC3(PE_L, PE_S, PE_L));
    case kSoundComponentPlaySourceBufferSelect:
        return PE_CALL(PEPlaySourceBuffer, PE_PROC4(PE_L, PE_L, PE_L, PE_L));

    default:
        return badComponentSelector;
    }
}
