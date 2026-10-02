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
UInt32 gBarTag[3] = { 0x50454155UL,      /* 'PEAU' */
                      0x42415230UL,      /* 'BAR0' */
                      0xBAADF00DUL };    /* <- the loader overwrites this */

static OSStatus FindRegisters(RegEntryID *entry)
{
    (void)entry;

    if (gBarTag[2] == 0xBAADF00DUL || gBarTag[2] == 0) {
        return paramErr;        /* the loader did not patch us */
    }
    gRegs = (volatile UInt32 *)gBarTag[2];
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
