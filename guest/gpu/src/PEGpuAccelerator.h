/*
 * PEGpuAccelerator: the IOService that owns the PowerEmu GPU's BAR.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef PEGPU_ACCELERATOR_H
#define PEGPU_ACCELERATOR_H

#include <IOKit/IOService.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IODeviceMemory.h>
#include <IOKit/pci/IOPCIDevice.h>

#include "PEGpuShared.h"

class PEGpuAccelerator : public IOService
{
    OSDeclareDefaultStructors(PEGpuAccelerator)

public:
    virtual bool start(IOService *provider);
    virtual void stop(IOService *provider);
    virtual void free(void);

    /*
     * Everything below is for PEGpuUserClient.  None of it is called from
     * anywhere else, and none of it takes a guest-supplied pointer: the
     * only guest value that reaches the hardware through this class is the
     * doorbell's ring head, and ringDoorbell() range-checks it.
     */
    IOMemoryDescriptor *copyMemoryForType(UInt32 type);
    bool claimRing(void);
    void releaseRing(void);
    void setEnable(bool on);
    IOReturn ringDoorbell(UInt32 head);

private:
    IOPCIDevice     *fPci;
    IODeviceMemory  *fBar;
    IOMemoryMap     *fCtrlMap;
    volatile UInt32 *fCtrl;     /* the control page, mapped into the kernel */
    UInt32           fClaimed;  /* 0 or 1: the ring has exactly one owner */
};

#endif /* PEGPU_ACCELERATOR_H */
