/*
 * PEAudioNDRV -- a native driver that proves poweremu-audio is reachable.
 *
 * The probe application found the device-tree node and read AAPL,address
 * correctly, but a load from that address never reached the device: an
 * application's address space does not map hardware.  A native driver runs
 * in the system context, where that address is the one the hardware is at,
 * which is how the real sound driver reaches the real codec.
 *
 * So this is the same three questions as PEAudioProbe, asked from the place
 * that can actually answer them -- and it needs no window and no console,
 * because the device itself is the output channel.  On initialise it reads
 * ID, VERSION and CAPS and then writes a signature to WRITE_PTR.  Running
 * the emulator with PEAU_TRACE=1 shows the whole conversation:
 *
 *     PEAU RD 0x00 = 0x50454155      <- ID, 'PEAU'
 *     PEAU RD 0x04 = 0x00000001      <- VERSION
 *     PEAU RD 0x08 = 0x00100001      <- CAPS
 *     PEAU WR 0x24 = 0x0DEFACED      <- we got here
 *
 * Nothing in that sequence can happen by accident, so seeing it is proof.
 *
 * Build: see BUILDING.md.  It wants Apple's Universal Interfaces 3.4.1 for
 * DriverServices.h -- Retro68's multiversal headers do not cover the native
 * driver interfaces.
 */

#include <Types.h>
#include <Devices.h>
#include <DriverServices.h>
#include <NameRegistry.h>

#define PEAU_ID         0x00
#define PEAU_VERSION    0x04
#define PEAU_CAPS       0x08
#define PEAU_RING_BASE  0x10
#define PEAU_RING_SIZE  0x14
#define PEAU_RATE       0x18
#define PEAU_FORMAT     0x1c
#define PEAU_CONTROL    0x20
#define PEAU_WRITE_PTR  0x24
#define PEAU_READ_PTR   0x28
#define PEAU_STATUS     0x2c
#define PEAU_RING_BYTES 0x30

#define PEAU_CTL_RUN    0x00000001UL

#define PEAU_FRAME_BYTES 4              /* 16-bit signed stereo */
#define PEAU_TONE_RATE   44100UL

#define PEAU_MAGIC      0x50454155UL        /* 'PEAU' */
#define PEAU_HELLO      0x0DEFACEDUL        /* nothing writes this by chance */

/*
 * What the Expansion Bus Manager matches against.  nameInfoStr is a Pascal
 * string naming the device-tree node: PCI enumeration names ours after its
 * IDs, pci1b36,5045 -- twelve characters, hence \x0c.
 *
 * It was a macio child first, matched on a "poweremu,audio" compatible
 * property, and Mac OS never loaded the driver: that property is read for
 * devices PCI enumeration discovers, and an on-board device is not one.
 * The loader that installs this driver also finds it by searching the
 * blob for "mtej\0\0\0\0\x0cpci1b36," -- so the old name did not merely
 * fail to match in the guest, it stopped the driver being installed at
 * all, and the loader printed an empty name to say so.
 *
 * kDriverIsLoadedUponDiscovery gets us loaded as soon as the node is seen,
 * and kDriverIsOpenedUponLoad opens us straight after, so Initialize runs
 * without anybody having to ask for it.
 *
 * The service is declared generic rather than 'sond': claiming to be a
 * sound driver invites Mac OS to treat this as the machine's sound
 * hardware, which it is not yet.
 */
DriverDescription TheDriverDescription = {
    kTheDescriptionSignature,
    kInitialDriverDescriptor,
    { "\x0cpci1b36,5045", { 0x00, 0x10, 0x80, 0x00 } },
    { kDriverIsLoadedUponDiscovery | kDriverIsOpenedUponLoad,
      /*
       * The driver's unit-table name, and the length byte must be right:
       * ".PEAudio" is eight characters.  It said \x0a here, and Mac OS
       * installs the driver in the unit table under this name *before* it
       * issues kInitializeCommand -- so a bad name meant Initialize was
       * never reached and the device saw nothing at all.
       */
      "\x08.PEAudio" },
    { 1,
      { { kServiceCategoryNdrvDriver, kNdrvTypeIsGeneric,
          { 0x00, 0x10, 0x80, 0x00 } } } }
};

static volatile UInt32 *gRegs;
static volatile SInt16 *gRing;

/*
 * The node's address, patched in by the loader.
 *
 * This looked it up with RegistryPropertyGet, which is the documented way
 * and works perfectly from an application -- and makes the driver never
 * run at all.  A driver flagged kDriverIsLoadedUponDiscovery is prepared
 * during PCI enumeration, before the file system is up, so CFM can only
 * connect it to libraries that live in ROM.  DriverServicesLib is one;
 * NameRegistryLib and PCILib are disk-based and are not, and an import it
 * cannot resolve makes CFM decline the fragment.  Nothing reports this:
 * the node still gets driver-ptr, because the code was read, but never
 * driver-ref, and DoDriverIO is never called.
 *
 * So the address cannot be looked up from in here.  The loader is an Open
 * Firmware client program that already walks to this node to install the
 * driver, and Open Firmware can read assigned-addresses perfectly well, so
 * it resolves the BAR and writes it into the tag below before handing the
 * image to Mac OS.  gBarTag[2] is the address; the two words before it are
 * what the loader searches for.
 */
UInt32 gBarTag[4] = { 0x50454155UL,      /* 'PEAU' */
                      0x42415230UL,      /* 'BAR0' */
                      0xBAADF00DUL,      /* <- BAR 0, the registers       */
                      0xBAADF00DUL };    /* <- BAR 1, the ring            */

static OSStatus FindRegisters(RegEntryID *entry)
{
    (void)entry;

    if (gBarTag[2] == 0xBAADF00DUL || gBarTag[2] == 0) {
        return paramErr;        /* the loader did not patch us */
    }
    gRegs = (volatile UInt32 *)gBarTag[2];
    gRing = (volatile SInt16 *)gBarTag[3];
    return noErr;
}

/*
 * A tone, so that the first thing this driver does is something you can
 * hear.  The ring is the device's own BAR, so filling it is a plain store
 * loop -- no buffer to allocate and no physical address to resolve, which
 * matters because neither is available to a driver this early.
 *
 * A square wave rather than a sine: it needs no math library, and a
 * driver that cannot call outside ROM cannot have one.  440 Hz, a quarter
 * of full scale so it is audible without being unpleasant, and only the
 * first part of the ring -- the rest is silence, so the tone sounds once
 * and stops rather than looping forever.
 */
static void FillTone(UInt32 ringBytes)
{
    UInt32 frames = ringBytes / PEAU_FRAME_BYTES;
    UInt32 halfPeriod = PEAU_TONE_RATE / (440UL * 2UL);
    UInt32 toneFrames = frames / 2;
    UInt32 i;

    for (i = 0; i < frames; i++) {
        SInt16 v = 0;

        if (i < toneFrames) {
            v = ((i / halfPeriod) & 1) ? (SInt16)-8000 : (SInt16)8000;
        }
        gRing[i * 2 + 0] = v;           /* left  */
        gRing[i * 2 + 1] = v;           /* right */
    }
}

static OSStatus Initialize(RegEntryID *entry)
{
    OSStatus err = FindRegisters(entry);

    if (err != noErr) {
        return err;
    }

    /* Reads first, so the trace shows what the device answered. */
    (void)gRegs[PEAU_ID / 4];
    (void)gRegs[PEAU_VERSION / 4];
    (void)gRegs[PEAU_CAPS / 4];

    if (gRegs[PEAU_ID / 4] != PEAU_MAGIC) {
        return paramErr;        /* reached something, but not us */
    }

    /* Start the device and sound the tone. */
    {
        UInt32 ringBytes = gRegs[PEAU_RING_BYTES / 4];

        if (ringBytes == 0 || gRing == 0 ||
            gBarTag[3] == 0xBAADF00DUL) {
            return paramErr;    /* no ring: the loader did not patch BAR 1 */
        }
        FillTone(ringBytes);

        gRegs[PEAU_RATE / 4]      = PEAU_TONE_RATE;
        gRegs[PEAU_FORMAT / 4]    = 0;
        gRegs[PEAU_RING_SIZE / 4] = ringBytes;
        gRegs[PEAU_WRITE_PTR / 4] = ringBytes / PEAU_FRAME_BYTES;
        gRegs[PEAU_CONTROL / 4]   = PEAU_CTL_RUN;
    }
    return noErr;
}

OSErr DoDriverIO(AddressSpaceID spaceID, IOCommandID cmdID,
                 IOCommandContents contents, IOCommandCode code,
                 IOCommandKind kind)
{
    OSStatus err = noErr;

    switch (code) {
    case kInitializeCommand:
    case kReplaceCommand:
        err = Initialize(&contents.initialInfo->deviceEntry);
        break;
    case kFinalizeCommand:
    case kSupersededCommand:
        break;
    case kOpenCommand:
    case kCloseCommand:
        break;
    default:
        err = paramErr;
        break;
    }

    /*
     * An immediate command returns its result directly; only queued ones
     * are completed through IOCommandIsComplete.  This called it for every
     * command, and Mac OS 9 issues kInitializeCommand with kind
     * kImmediateIOCommandKind -- measured, by having the driver report
     * code and kind through the device: 0xC0DE0704, code 7 kind 4.  The
     * effect was that Initialize ran and succeeded, the completion looked
     * wrong, and Mac OS finalized the driver instead of opening it
     * (0xC0DE0804 right behind it) -- so driver-ref was never created and
     * the driver never reached the unit table.
     */
    if (kind & kImmediateIOCommandKind) {
        return err;
    }
    return IOCommandIsComplete(cmdID, err);
}
