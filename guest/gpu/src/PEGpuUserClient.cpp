/*
 * PEGpuUserClient: the connection the OpenGL renderer plugin opens.
 *
 * What the client gets
 * --------------------
 * Two mappings and nothing else: the 4 KB control page and the 33 MB ring
 * plus data area.  It writes packets into the ring, bumps the ring head in
 * the control page, and polls the fence word.  There is no submit call in
 * the hot path.
 *
 * Why the doorbell is a store and not a method
 * --------------------------------------------
 * A method call would be a Mach trap: hundreds of emulated guest
 * instructions through the trap vector and IOUserClient's dispatch, ending
 * in the same single store to the control page.  Storing to the mapped page
 * from user space is that store and nothing else -- one QEMU MMIO exit,
 * with no guest kernel in the path.  Since the device exists precisely to
 * stop the guest kernel from being in the path, routing its one remaining
 * trap back through the kernel would undo part of the win for no safety we
 * do not already have (the host validates the head, every packet and every
 * offset before it dereferences anything).  It also matches the interface
 * Apple's own renderer uses: ATIRadeon8500GLDriver.bundle's only IOKit
 * calls are IOServiceOpen, IOConnectAddClient, IOConnectMapMemory and
 * IOServiceClose, with no method-call verb anywhere -- whatever it submits
 * through, it submits through a mapping.
 *
 * kPEGpuMethodDoorbell survives as an escape hatch, not as the design: if
 * user-space stores to device memory turn out to behave badly on 10.4 PPC,
 * having the method already in the kext saves a full build-and-install
 * round trip to find that out.
 *
 * What a malicious or buggy client can do
 * ---------------------------------------
 * It has the ring and the data area mapped read-write, so it can scribble
 * anywhere in them: over its own render target, over the texture data, over
 * packets it already queued.  That is the entire blast radius and it is the
 * device's own memory.  It cannot reach guest kernel memory, another
 * process's memory, or host memory, because clientMemoryForType() returns
 * sub-ranges of BAR 0 and refuses every type it does not recognise -- it
 * never falls through to a default.
 *
 * It also has the control page mapped, so it can set or clear ENABLE and
 * take the guest's scanout with it.  Accepted: it already owns the ring
 * exclusively, so the worst it can do is blank a display it was entitled to
 * drive, and closing the connection puts it back.
 *
 * It can ring the doorbell with a head pointing at garbage.  The host
 * refuses the batch, latches an error, and resets its tail; it never
 * dereferences a guest offset that has not been range-checked against the
 * data area.  It can also ring the doorbell in a tight loop, which is a
 * denial of service against the host's BQL -- nothing in the guest can
 * prevent that, and the host is where any rate limit would have to live.
 *
 * What it cannot do is make *this kext* misbehave.  The kext reads two
 * words of the control page at attach and writes two afterwards; it never
 * reads the ring, never follows a guest-supplied offset, and holds no
 * guest-controlled length.  There is no code path here for a malformed
 * packet to reach, which is the property worth having in a guest where a
 * kernel bug is a panic and a reboot.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <IOKit/IOLib.h>

#include "PEGpuUserClient.h"

#define super IOUserClient
OSDefineMetaClassAndStructors(PEGpuUserClient, IOUserClient)

/*
 * On this 32-bit PowerPC kernel a scalar argument is passed in a register
 * and UInt32 is the right parameter type for the method it dispatches to.
 * Nothing here is 64-bit clean and nothing needs to be: 10.4 PPC is the
 * only target this kext has.
 */
static IOExternalMethod sPEGpuMethods[kPEGpuMethodCount] = {
    {   /* kPEGpuMethodDoorbell */
        NULL,
        (IOMethod)&PEGpuUserClient::doorbell,
        kIOUCScalarIScalarO, 1, 0
    }
};

bool PEGpuUserClient::initWithTask(task_t owningTask, void *securityID,
                                   UInt32 type)
{
    if (!owningTask) {
        return false;
    }
#if PEGPU_REQUIRE_ADMIN
    if (clientHasPrivilege(securityID, kIOClientPrivilegeAdministrator) !=
        kIOReturnSuccess) {
        return false;
    }
#endif
    if (!super::initWithTask(owningTask, securityID, type)) {
        return false;
    }
    fTask = owningTask;
    return true;
}

bool PEGpuUserClient::start(IOService *provider)
{
    fOwner = OSDynamicCast(PEGpuAccelerator, provider);
    if (!fOwner) {
        return false;
    }
    if (!super::start(provider)) {
        return false;
    }

    if (!fOwner->claimRing()) {
        IOLog("PEGpu: the ring already has an owner, refusing this open\n");
        return false;
    }
    fOwnsRing = true;

    /* Nothing the client writes is executed until the device is enabled. */
    fOwner->setEnable(true);
    return true;
}

/*
 * Idempotent, because clientClose() and stop() can both reach it and either
 * may come first depending on whether the client closed or was terminated.
 */
void PEGpuUserClient::giveUpRing(void)
{
    if (fOwner && fOwnsRing) {
        /*
         * Disable before releasing the claim: a client that crashed mid
         * batch would otherwise leave the host scanning out of a ring
         * nobody is feeding, and the next client would inherit it.
         */
        fOwner->setEnable(false);
        fOwner->releaseRing();
        fOwnsRing = false;
    }
}

IOReturn PEGpuUserClient::clientClose(void)
{
    giveUpRing();
    if (!isInactive()) {
        terminate();
    }
    return kIOReturnSuccess;
}

void PEGpuUserClient::stop(IOService *provider)
{
    giveUpRing();
    super::stop(provider);
}

IOReturn PEGpuUserClient::clientMemoryForType(UInt32 type,
                                              IOOptionBits *options,
                                              IOMemoryDescriptor **memory)
{
    IOMemoryDescriptor *md;

    if (!fOwner || isInactive()) {
        return kIOReturnNotAttached;
    }

    md = fOwner->copyMemoryForType(type);
    if (!md) {
        return kIOReturnBadArgument;
    }

    /*
     * No options: the descriptor is device memory, so the mapping comes out
     * cache-inhibited and guarded, and PowerPC then orders the client's
     * ring stores ahead of the doorbell store that follows them without the
     * client having to do anything.  Under QEMU that ordering is free --
     * the ring and data area resolve to plain host RAM and never trap -- but
     * asking for a cached mapping to make it "faster" would be buying
     * nothing in exchange for an ordering problem.
     *
     * The descriptor is returned retained; IOUserClient releases it.
     */
    *options = 0;
    *memory = md;
    return kIOReturnSuccess;
}

IOReturn PEGpuUserClient::connectClient(IOUserClient *client)
{
    /*
     * Apple's renderer plugins call IOConnectAddClient straight after
     * opening -- on real hardware it is how a GL context is tied to the 2D
     * context that owns the surface.  We have one ring and nothing to tie,
     * but IOUserClient's default returns kIOReturnUnsupported, and a plugin
     * written against Apple's drivers may well treat that as fatal.
     */
    return kIOReturnSuccess;
}

IOExternalMethod *PEGpuUserClient::getTargetAndMethodForIndex(IOService **target,
                                                              UInt32 index)
{
    if (index >= (UInt32)kPEGpuMethodCount) {
        return NULL;
    }
    *target = this;
    return &sPEGpuMethods[index];
}

IOReturn PEGpuUserClient::doorbell(UInt32 head)
{
    if (!fOwner || !fOwnsRing) {
        return kIOReturnNotAttached;
    }
    return fOwner->ringDoorbell(head);
}
