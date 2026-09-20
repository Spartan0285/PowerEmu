/*
 * PEGpuUserClient: the connection the OpenGL renderer plugin opens.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef PEGPU_USER_CLIENT_H
#define PEGPU_USER_CLIENT_H

#include <IOKit/IOUserClient.h>

#include "PEGpuAccelerator.h"

/*
 * Set to 1 to require the opening process to be an administrator.  Off by
 * default because it would exclude every ordinary GL application, which is
 * most of the point; see the threat model at the top of PEGpuUserClient.cpp
 * before deciding it should be on.
 */
#ifndef PEGPU_REQUIRE_ADMIN
#define PEGPU_REQUIRE_ADMIN 0
#endif

class PEGpuUserClient : public IOUserClient
{
    OSDeclareDefaultStructors(PEGpuUserClient)

public:
    virtual bool initWithTask(task_t owningTask, void *securityID, UInt32 type);
    virtual bool start(IOService *provider);
    virtual void stop(IOService *provider);
    virtual IOReturn clientClose(void);

    virtual IOReturn clientMemoryForType(UInt32 type, IOOptionBits *options,
                                         IOMemoryDescriptor **memory);
    virtual IOReturn connectClient(IOUserClient *client);
    virtual IOExternalMethod *getTargetAndMethodForIndex(IOService **target,
                                                         UInt32 index);

    /* kPEGpuMethodDoorbell.  Only reached through the escape hatch. */
    IOReturn doorbell(UInt32 head);

private:
    void giveUpRing(void);

    PEGpuAccelerator *fOwner;
    task_t            fTask;
    bool              fOwnsRing;
};

#endif /* PEGPU_USER_CLIENT_H */
