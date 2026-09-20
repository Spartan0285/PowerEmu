/*
 * PEGpuAccelerator: the IOService that owns the PowerEmu GPU's BAR.
 *
 * This driver accelerates nothing.  All the drawing happens on the host,
 * from packets the OpenGL renderer plugin writes into shared memory, so the
 * kernel's whole job is to (a) exist, so that Apple's OpenGL has an IOKit
 * service to read IOGLBundleName from, and (b) hand that plugin a mapping
 * of the BAR.  Everything it does not do is deliberate: it never parses a
 * packet, never follows a guest offset, and never touches the ring.  The
 * host already validates all of that (pe_gpu_data_ok() and friends in
 * hw/display/poweremu-gpu.c), and a second implementation in the guest
 * kernel could only be a second thing to get wrong -- in the one place
 * where getting it wrong panics the guest.
 *
 * Why the emulated R200 stays
 * ---------------------------
 * This device is class DISPLAY_OTHER and has no framebuffer.  Open Firmware
 * never looks at it, the guest boots on the emulated R200 as before, and
 * this kext only ever binds through PCI matching.  That is what keeps the
 * normal path working when the plugin is absent or refuses to load.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <IOKit/IOLib.h>
#include <libkern/OSAtomic.h>
#include <libkern/OSBase.h>

#include "PEGpuAccelerator.h"

#define super IOService
OSDefineMetaClassAndStructors(PEGpuAccelerator, IOService)

bool PEGpuAccelerator::start(IOService *provider)
{
    IODeviceMemory *ctrl;

    if (!super::start(provider)) {
        return false;
    }

    fPci = OSDynamicCast(IOPCIDevice, provider);
    if (!fPci) {
        return false;
    }

    /*
     * QEMU only decodes the BAR once PCI_COMMAND_MEMORY is set, and nothing
     * has set it: Open Firmware assigns this device an address but never
     * drives it, because it is not the boot display.
     */
    fPci->setMemoryEnable(true);

    fBar = OSDynamicCast(IODeviceMemory,
                         fPci->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0));
    if (!fBar) {
        IOLog("PEGpu: no BAR 0\n");
        return false;
    }
    fBar->retain();     /* getDeviceMemoryWithRegister() does not */

    /*
     * A short BAR means the device model and this driver disagree about the
     * layout, which would show up later as mappings that silently stop
     * short of the data area.  Refuse now, while the message is readable.
     */
    if (fBar->getLength() < kPEGpuBarBytes) {
        IOLog("PEGpu: BAR is %u bytes, need %u\n",
              (unsigned int)fBar->getLength(), (unsigned int)kPEGpuBarBytes);
        return false;
    }

    ctrl = IODeviceMemory::withSubRange(fBar, kPEGpuCtrlOffset, kPEGpuCtrlSize);
    if (!ctrl) {
        return false;
    }
    fCtrlMap = ctrl->map(kIOMapInhibitCache);
    ctrl->release();
    if (!fCtrlMap) {
        IOLog("PEGpu: cannot map the control page\n");
        return false;
    }
    fCtrl = (volatile UInt32 *)fCtrlMap->getVirtualAddress();

    /*
     * Native big-endian loads; see PEGpuShared.h.  Matching on the PCI ID
     * alone is not enough to attach: a version we do not understand would
     * let us hand a plugin a mapping whose layout has moved underneath it.
     */
    if (fCtrl[kPEGpuRegMagic] != kPEGpuMagic ||
        fCtrl[kPEGpuRegVersion] != kPEGpuVersion) {
        IOLog("PEGpu: magic %08x version %u, refusing to attach\n",
              (unsigned int)fCtrl[kPEGpuRegMagic],
              (unsigned int)fCtrl[kPEGpuRegVersion]);
        return false;
    }

    /*
     * Also in the Info.plist personality, which is where anything that
     * inspects the driver before it starts will look; setting it here as
     * well means the property is present even if the personality is edited
     * and this one is missed.
     */
    setProperty(kPEGpuGLBundleNameKey, kPEGpuGLBundleName);
    setProperty("PEGpuFeatures",
                (unsigned long long)fCtrl[kPEGpuRegFeatures], 32);

    IOLog("PEGpu: attached, features %08x, GL bundle %s\n",
          (unsigned int)fCtrl[kPEGpuRegFeatures], kPEGpuGLBundleName);

    registerService();
    return true;
}

void PEGpuAccelerator::stop(IOService *provider)
{
    /*
     * The host scans out of the ring only while enabled.  Leaving it set
     * with the driver gone would freeze the guest's display on whatever the
     * last PRESENT pointed at.
     */
    if (fCtrl) {
        setEnable(false);
    }
    super::stop(provider);
}

/*
 * Cleanup lives here rather than in stop() because IOKit does not call
 * stop() when start() returns false, and several of start()'s failure
 * paths run after the BAR has been retained and mapped.
 */
void PEGpuAccelerator::free(void)
{
    if (fCtrlMap) {
        fCtrlMap->release();
        fCtrlMap = NULL;
    }
    fCtrl = NULL;
    if (fBar) {
        fBar->release();
        fBar = NULL;
    }
    super::free();
}

/*
 * The only two mappings this driver will ever produce.  Anything else
 * returns NULL and the user client turns that into kIOReturnBadArgument;
 * in particular it never falls through to a default that could hand out
 * memory belonging to something other than this device's BAR.
 */
IOMemoryDescriptor *PEGpuAccelerator::copyMemoryForType(UInt32 type)
{
    if (!fBar) {
        return NULL;
    }

    switch (type) {
    case kPEGpuMemoryControl:
        return IODeviceMemory::withSubRange(fBar, kPEGpuCtrlOffset,
                                            kPEGpuCtrlSize);
    case kPEGpuMemoryShared:
        return IODeviceMemory::withSubRange(fBar, kPEGpuRingOffset,
                                            kPEGpuSharedBytes);
    default:
        return NULL;
    }
}

/*
 * The ring, the tail pointer and the 64-entry texture table are each a
 * singleton in the protocol, so two submitters would corrupt each other
 * with no way for either to notice.  Refusing the second open in the kernel
 * turns that into an error the second client can report.
 */
bool PEGpuAccelerator::claimRing(void)
{
    return OSCompareAndSwap(0, 1, (UInt32 *)&fClaimed);
}

void PEGpuAccelerator::releaseRing(void)
{
    OSCompareAndSwap(1, 0, (UInt32 *)&fClaimed);
}

void PEGpuAccelerator::setEnable(bool on)
{
    if (fCtrl) {
        fCtrl[kPEGpuRegEnable] = on ? 1 : 0;
    }
}

IOReturn PEGpuAccelerator::ringDoorbell(UInt32 head)
{
    if (!fCtrl) {
        return kIOReturnNotAttached;
    }

    /*
     * The host range-checks this too, and latches PE_GPU_ERR_PACKET when it
     * fails.  Checking here as well is not redundant: an error the client
     * has to acknowledge before the next batch runs is a much worse failure
     * mode than a method that simply returns an error.
     */
    if (head > kPEGpuRingBytes || (head & 7)) {
        return kIOReturnBadArgument;
    }

    /*
     * The ring stores must be visible to the host before the doorbell is.
     * The mapping is cache-inhibited and guarded, so PowerPC already
     * orders them; the eieio makes that a property of this code rather
     * than of how QEMU happens to schedule the stores.
     */
    OSSynchronizeIO();
    fCtrl[kPEGpuRegDoorbell] = head;
    return kIOReturnSuccess;
}
