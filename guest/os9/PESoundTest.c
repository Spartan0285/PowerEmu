/*
 * PESoundTest -- register the sound output component and play through it.
 *
 * RegisterComponent with global set installs the component for the whole
 * session without a file in Extensions, which is what makes this testable
 * at all: the guest's volume is HFS+ inside an HFS wrapper and hfsutils,
 * which is the only way this Mac can write an HFS volume at all, can only
 * see the wrapper.  Packaging a 'thng' comes after the component works.
 *
 * The component's code lives in this application, so the application has
 * to stay running for it to exist.  It registers, reports, plays, and then
 * waits for a keypress.
 */

#include <stdio.h>
#include <string.h>
#include <MacTypes.h>
#include <Components.h>
#include <Sound.h>
#include <MixedMode.h>
#include <Resources.h>
#include <Timer.h>

#define kPESoundSubType       FOUR_CHAR_CODE('PEau')
#define kPESoundManufacturer  FOUR_CHAR_CODE('PEmu')

extern pascal ComponentResult PEAudioComponentEntry(ComponentParameters *params,
                                                    Handle storage);

/*
 * A source for the output device to pull from.
 *
 * The Sound Manager normally puts its mixer here, and reaching the mixer
 * means being the machine's selected output device, which needs the
 * component installed in Extensions so the Sound control panel sees it at
 * startup.  This stands in for the mixer so the output device's real path
 * -- the Time Manager task, the pull loop, the ring, the hardware -- can
 * be exercised now.  It is test scaffolding, not part of the design.
 */
#define kTestSourceType     FOUR_CHAR_CODE('sdev')
#define kTestSourceSubType  FOUR_CHAR_CODE('PEts')

static SInt16 *gPCM;            /* 16-bit stereo, 44100 */
static long    gPCMFrames;
static long    gPCMPos;
static SoundComponentData gSrcFmt;

#define PE_TEST_RATE 44100L

/*
 * The sound to play: the first 'snd ' resource the Resource Manager can
 * find, which on a stock system is one of the alert sounds in the System
 * file.  Classic 'snd ' samples are 8-bit unsigned mono at about 22 kHz,
 * so they are converted up to the 16-bit stereo 44100 the device wants --
 * nearest neighbour, which is crude but adds no risk and is inaudible on
 * a sound this short.  If there is no resource to be had, a rising
 * three-note arpeggio stands in, so the test always makes a noise it is
 * possible to recognise.
 */
static void BuildArpeggio(void)
{
    static const long freq[3] = { 440, 554, 659 };   /* A, C#, E */
    long noteFrames = PE_TEST_RATE / 4;              /* 250 ms each */
    long i, n;

    gPCMFrames = noteFrames * 3;
    gPCM = (SInt16 *)NewPtr(gPCMFrames * 4);
    if (gPCM == NULL) { gPCMFrames = 0; return; }

    for (n = 0; n < 3; n++) {
        long half = PE_TEST_RATE / (freq[n] * 2);
        for (i = 0; i < noteFrames; i++) {
            long  f = n * noteFrames + i;
            SInt16 v = ((i / half) & 1) ? (SInt16)-7000 : (SInt16)7000;
            gPCM[f * 2 + 0] = v;
            gPCM[f * 2 + 1] = v;
        }
    }
}

static Boolean BuildFromSndResource(void)
{
    Handle             h;
    SoundComponentData hdr;
    long               frames = 0, offset = 0;
    unsigned char     *samples;
    long               i, rate;

    h = GetIndResource(FOUR_CHAR_CODE('snd '), 1);
    if (h == NULL) {
        return false;
    }
    HLock(h);
    memset(&hdr, 0, sizeof(hdr));
    if (ParseSndHeader((SndListHandle)h, &hdr, &frames, &offset) != noErr ||
        frames <= 0 || hdr.sampleSize != 8 || hdr.numChannels != 1) {
        HUnlock(h);
        return false;                   /* not a shape we convert */
    }
    rate = (long)(hdr.sampleRate >> 16);
    if (rate < 4000 || rate > PE_TEST_RATE) {
        HUnlock(h);
        return false;
    }
    samples = (unsigned char *)(*h) + offset;

    gPCMFrames = (frames * PE_TEST_RATE) / rate;
    gPCM = (SInt16 *)NewPtr(gPCMFrames * 4);
    if (gPCM == NULL) { gPCMFrames = 0; HUnlock(h); return false; }

    for (i = 0; i < gPCMFrames; i++) {
        long   src = (i * rate) / PE_TEST_RATE;
        SInt16 v;

        if (src >= frames) src = frames - 1;
        v = (SInt16)(((long)samples[src] - 128) << 8);
        gPCM[i * 2 + 0] = v;
        gPCM[i * 2 + 1] = v;
    }
    HUnlock(h);
    printf("   using a 'snd ' resource: %ld frames at %ld Hz -> %ld at %ld\n",
           frames, rate, gPCMFrames, PE_TEST_RATE);
    return true;
}

static pascal ComponentResult TSOpen(Handle storage, ComponentInstance self)
{
#pragma unused(storage)
    SetComponentInstanceStorage(self, (Handle)1);   /* non-NULL marker */
    return noErr;
}

static pascal ComponentResult TSClose(Handle storage, ComponentInstance self)
{
#pragma unused(storage, self)
    return noErr;
}

static pascal ComponentResult TSGetSourceData(Handle storage,
                                              SoundComponentDataPtr *data)
{
    long left = gPCMFrames - gPCMPos;
    long chunk = 1024;
#pragma unused(storage)

    if (left <= 0) {
        gSrcFmt.sampleCount = 0;
        gSrcFmt.buffer = NULL;
        *data = &gSrcFmt;
        return noErr;                   /* done; the ring drains to silence */
    }
    if (chunk > left) chunk = left;

    gSrcFmt.flags       = 0;
    gSrcFmt.format      = kSoundNotCompressed;
    gSrcFmt.numChannels = 2;
    gSrcFmt.sampleSize  = 16;
    gSrcFmt.sampleRate  = PE_TEST_RATE << 16;
    gSrcFmt.sampleCount = chunk;
    gSrcFmt.buffer      = (Byte *)&gPCM[gPCMPos * 2];
    gSrcFmt.reserved    = 0;
    gPCMPos += chunk;
    *data = &gSrcFmt;
    return noErr;
}

static pascal ComponentResult TSVersion(Handle storage)
{
#pragma unused(storage)
    return 0x00010000;
}

#define TS_PROC0  (kPascalStackBased \
    | RESULT_SIZE(SIZE_CODE(sizeof(ComponentResult))))
#define TS_PROC1  (TS_PROC0 | STACK_ROUTINE_PARAMETER(1, SIZE_CODE(4)))
#define TS_PROC2  (TS_PROC1 | STACK_ROUTINE_PARAMETER(2, SIZE_CODE(4)))

static pascal ComponentResult TestSourceEntry(ComponentParameters *params,
                                              Handle storage)
{
    switch (params->what) {
    case kComponentOpenSelect:
        return CallComponentFunctionWithStorageProcInfo(storage, params,
                   (ProcPtr)TSOpen, TS_PROC2);
    case kComponentCloseSelect:
        return CallComponentFunctionWithStorageProcInfo(storage, params,
                   (ProcPtr)TSClose, TS_PROC2);
    case kComponentVersionSelect:
        return CallComponentFunctionWithStorageProcInfo(storage, params,
                   (ProcPtr)TSVersion, TS_PROC1);
    case kComponentCanDoSelect:
        return 1;
    case kSoundComponentGetSourceDataSelect:
        return CallComponentFunctionWithStorageProcInfo(storage, params,
                   (ProcPtr)TSGetSourceData, TS_PROC2);
    default:
        return badComponentSelector;
    }
}

int main(void)
{
    ComponentDescription cd;
    Component            c;
    ComponentInstance    ci = NULL;
    Handle               name;
    OSErr                err;
    long                 vol;

    printf("PESoundTest\n\n");

    memset(&cd, 0, sizeof(cd));
    cd.componentType         = kSoundOutputDeviceType;   /* 'sdev' */
    cd.componentSubType      = kPESoundSubType;
    cd.componentManufacturer = kPESoundManufacturer;

    name = NewHandle(16);
    if (name) {
        BlockMoveData("\014PowerEmu Audio", *name, 15);
    }

    printf("1. registering the 'sdev' component\n");
    c = RegisterComponent(&cd, NewComponentRoutineUPP(PEAudioComponentEntry),
                          1 /* global */, name, NULL, NULL);
    if (c == NULL) {
        printf("   FAILED -- RegisterComponent returned NULL\n");
        printf("\nDone.  Press return.\n"); getchar(); return 1;
    }
    printf("   registered, Component = %p\n", (void *)c);

    printf("\n2. how many 'sdev' components Mac OS now sees\n");
    {
        ComponentDescription any;
        Component            iter = NULL;
        int                  n = 0;

        memset(&any, 0, sizeof(any));
        any.componentType = kSoundOutputDeviceType;
        while ((iter = FindNextComponent(iter, &any)) != NULL) {
            ComponentDescription got;
            Handle nm = NewHandle(0);

            n++;
            if (GetComponentInfo(iter, &got, nm, NULL, NULL) == noErr) {
                char buf[64];
                unsigned char len = (*nm && GetHandleSize(nm) > 0)
                                    ? (unsigned char)(*nm)[0] : 0;
                if (len > 62) len = 62;
                memcpy(buf, (*nm) + 1, len); buf[len] = 0;
                printf("   %d: '%.4s' sub '%.4s' manu '%.4s'  %s\n", n,
                       (char *)&got.componentType,
                       (char *)&got.componentSubType,
                       (char *)&got.componentManufacturer, buf);
            }
            DisposeHandle(nm);
        }
        printf("   total: %d\n", n);
    }

    printf("\n3. opening our component directly\n");
    err = OpenAComponent(c, &ci);
    printf("   OpenAComponent = %d, instance %p\n", (int)err, (void *)ci);
    if (ci) {
        err = SoundComponentInitOutputDevice(ci, 0);
        printf("   InitOutputDevice = %d  <- finds the PCI device\n", (int)err);
        if (err == noErr) {
            UnsignedFixed rate = 0; short ch = 0, sz = 0;
            SoundComponentGetInfo(ci, 0, siSampleRate, &rate);
            SoundComponentGetInfo(ci, 0, siNumberChannels, &ch);
            SoundComponentGetInfo(ci, 0, siSampleSize, &sz);
            printf("   format: %lu Hz, %d ch, %d bit\n",
                   (unsigned long)(rate >> 16), (int)ch, (int)sz);
        }
    }

    printf("\n4. building the audio to play\n");
    if (!BuildFromSndResource()) {
        printf("   no usable 'snd ' resource; using an arpeggio\n");
        BuildArpeggio();
    }
    printf("   %ld frames ready\n", gPCMFrames);

    printf("\n5. wiring a source to the output device and starting it\n");
    if (ci && gPCMFrames > 0) {
        ComponentDescription scd;
        Component            sc;
        ComponentInstance    si = NULL;

        memset(&scd, 0, sizeof(scd));
        scd.componentType         = kTestSourceType;
        scd.componentSubType      = kTestSourceSubType;
        scd.componentManufacturer = kPESoundManufacturer;
        sc = RegisterComponent(&scd, NewComponentRoutineUPP(TestSourceEntry),
                               1, NULL, NULL, NULL);
        printf("   source component = %p\n", (void *)sc);
        if (sc && OpenAComponent(sc, &si) == noErr) {
            err = SoundComponentSetSource(ci, (SoundSource)1, si);
            printf("   SetSource = %d\n", (int)err);
            err = SoundComponentStartSource(ci, 1, NULL);
            printf("   StartSource = %d\n", (int)err);

            /* Drive the refill from here, at task level. */
            {
                long ticks = TickCount() + 60 * 15;
                long queued = 0;

                while (TickCount() < ticks) {
                    if (SoundComponentGetInfo(ci, (SoundSource)1,
                                              FOUR_CHAR_CODE('PErf'),
                                              &queued) != noErr) {
                        break;
                    }
                    if (gPCMPos >= gPCMFrames && queued == 0) {
                        break;
                    }
                }
            }
            printf("   played %ld of %ld frames\n", gPCMPos, gPCMFrames);
            SoundComponentStopSource(ci, 1, NULL);
        }
    }

    GetDefaultOutputVolume(&vol);
    printf("\n   default output volume = 0x%08lX\n", (unsigned long)vol);

    printf("\nDone.  Press return.\n");
    getchar();
    if (ci) CloseComponent(ci);
    return 0;
}
