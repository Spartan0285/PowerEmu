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
#define PEAU_WRITE_PTR  0x24

#define PEAU_MAGIC      0x50454155UL        /* 'PEAU' */
#define PEAU_HELLO      0x0DEFACEDUL        /* nothing writes this by chance */

/*
 * What the Expansion Bus Manager matches against.  nameInfoStr is a Pascal
 * string and must equal the node's "compatible" property, which PowerEmu
 * publishes as "poweremu,audio" -- fourteen characters, hence \x0e.
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
    { "\x0epoweremu,audio", { 0x00, 0x10, 0x80, 0x00 } },
    { kDriverIsLoadedUponDiscovery | kDriverIsOpenedUponLoad,
      "\x0a.PEAudio" },
    { 1,
      { { kServiceCategoryNdrvDriver, kNdrvTypeIsGeneric,
          { 0x00, 0x10, 0x80, 0x00 } } } }
};

static volatile UInt32 *gRegs;

/*
 * The node's address, from the Name Registry rather than hardcoded: the
 * probe already showed Mac OS computes AAPL,address from reg and the
 * parent's ranges, so this is the OS's own answer rather than our guess.
 */
static OSStatus FindRegisters(RegEntryID *entry)
{
    RegPropertyValueSize size = sizeof(UInt32);
    UInt32 base = 0;
    OSStatus err;

    err = RegistryPropertyGet(entry, "AAPL,address", &base, &size);
    if (err != noErr) {
        return err;
    }
    if (base == 0) {
        return paramErr;
    }
    gRegs = (volatile UInt32 *)base;
    return noErr;
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

    /* Then a write nothing else would make, so the trace is unambiguous. */
    gRegs[PEAU_WRITE_PTR / 4] = PEAU_HELLO;

    if (gRegs[PEAU_ID / 4] != PEAU_MAGIC) {
        return paramErr;        /* reached something, but not us */
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

    return IOCommandIsComplete(cmdID, err);
}
