/*
 * Attach the renderer to the paravirtual GPU.
 *
 * This is the whole of the plugin's dealings with the kernel: find the
 * service, open it, map its two regions, and check the host is who it says
 * it is.  Everything after that happens through the mappings -- packets are
 * plain stores into shared memory and the doorbell is one store to the
 * control page -- so nothing below is on a hot path and all of it can
 * afford to be careful.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "peconn.h"

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>

/*
 * The control page is device memory: cache-inhibited and guarded, so these
 * are real accesses to the emulated device in program order and must not be
 * hoisted, folded or reordered by the compiler.  volatile is what says so.
 */
static volatile unsigned int *pe_ctrl(PEConn *c)
{
    return (volatile unsigned int *)c->ctrl;
}

static void pe_conn_doorbell(void *arg, unsigned int head)
{
    PEConn *c = (PEConn *)arg;

    /*
     * The ring stores above must be visible to the host before the doorbell
     * store that publishes them.  The mapping being guarded gives us that
     * ordering on PowerPC without an explicit barrier, but eieio() is free
     * here (one doorbell per batch) and states the requirement rather than
     * relying on a property of the mapping that a later change could lose.
     */
    __asm__ __volatile__("eieio" ::: "memory");
    pe_ctrl(c)[kPEGpuRegDoorbell] = head;
}

unsigned int pe_conn_fence(PEConn *c)
{
    return pe_ctrl(c)[kPEGpuRegFence];
}

unsigned int pe_conn_error(PEConn *c)
{
    return pe_ctrl(c)[kPEGpuRegError];
}

void pe_conn_clear_error(PEConn *c)
{
    pe_ctrl(c)[kPEGpuRegError] = 0;
}

void pe_conn_enable(PEConn *c, int on)
{
    pe_ctrl(c)[kPEGpuRegEnable] = on ? 1u : 0u;
}

/*
 * Wait for the host to reach `fence`.  Spinning is right for the numbers
 * involved: the host consumes a batch inside the store that rang the
 * doorbell, so by the time the guest looks the fence has almost always
 * already passed, and a sleeping wait would cost a Mach trap to discover
 * work that was finished before it started.  The bound is there so a host
 * that died cannot wedge the guest's window server behind us.
 */
int pe_conn_wait(PEConn *c, unsigned int fence, unsigned int spins)
{
    unsigned int i;

    for (i = 0; i < spins; i++) {
        /* Wrap-safe: the difference stays small, the absolute values do not. */
        if ((int)(pe_conn_fence(c) - fence) >= 0) {
            return 0;
        }
    }
    return -1;
}

static int pe_conn_map(PEConn *c, io_connect_t conn, unsigned int type,
                       void **addr_out, unsigned int want)
{
    vm_address_t addr = 0;
    vm_size_t size = 0;

    if (IOConnectMapMemory(conn, type, mach_task_self(), &addr, &size,
                           kIOMapAnywhere) != KERN_SUCCESS) {
        return -1;
    }
    /*
     * A short mapping is not something to work around by clamping: every
     * offset the plugin computes is validated by the host against the full
     * region, so a guest that mapped less would build batches that look
     * correct here and are rejected there, which is the hardest kind of
     * disagreement to find.  Refuse instead.
     */
    if (size < want) {
        IOConnectUnmapMemory(conn, type, mach_task_self(), addr);
        return -1;
    }
    *addr_out = (void *)addr;
    return 0;
}

int pe_conn_open(PEConn *c)
{
    io_service_t svc;
    io_connect_t conn = 0;
    unsigned int magic, version;

    memset(c, 0, sizeof(*c));

    /*
     * IOServiceGetMatchingService consumes the dictionary, including on the
     * failure path, so there is nothing to release here either way.
     */
    svc = IOServiceGetMatchingService(kIOMasterPortDefault,
                                      IOServiceMatching(kPEGpuServiceClass));
    if (!svc) {
        return PE_CONN_NO_DEVICE;
    }
    if (IOServiceOpen(svc, mach_task_self(), 0, &conn) != KERN_SUCCESS) {
        IOObjectRelease(svc);
        return PE_CONN_NO_DEVICE;
    }
    IOObjectRelease(svc);

    if (pe_conn_map(c, conn, kPEGpuMemoryControl, &c->ctrl, kPEGpuCtrlSize) ||
        pe_conn_map(c, conn, kPEGpuMemoryShared, &c->shared,
                    kPEGpuSharedBytes)) {
        IOServiceClose(conn);
        return PE_CONN_NO_MAP;
    }
    c->conn = conn;

    /*
     * Checked before anything is written: the kext matches on PCI ID, so a
     * mismatch here means the device is not the one this plugin's protocol
     * describes, and writing a batch into it would be writing into whatever
     * it actually is.
     */
    magic = pe_ctrl(c)[kPEGpuRegMagic];
    version = pe_ctrl(c)[kPEGpuRegVersion];
    if (magic != kPEGpuMagic || version != kPEGpuVersion) {
        pe_conn_close(c);
        return PE_CONN_BAD_VERSION;
    }
    c->features = pe_ctrl(c)[kPEGpuRegFeatures];

    /*
     * The host validates every offset against the shared region, whose base
     * is protocol offset zero -- so the ring is handed exactly the mapping,
     * with no bias, and the two agree on what an offset means by
     * construction rather than by arithmetic either side has to get right.
     */
    pe_ring_init(&c->ring, c->shared, kPEGpuSharedBytes);
    c->ring.doorbell = pe_conn_doorbell;
    c->ring.doorbell_arg = c;
    return PE_CONN_OK;
}

void pe_conn_close(PEConn *c)
{
    if (!c->conn) {
        return;
    }
    if (c->ctrl) {
        IOConnectUnmapMemory(c->conn, kPEGpuMemoryControl, mach_task_self(),
                             (vm_address_t)c->ctrl);
    }
    if (c->shared) {
        IOConnectUnmapMemory(c->conn, kPEGpuMemoryShared, mach_task_self(),
                             (vm_address_t)c->shared);
    }
    IOServiceClose(c->conn);
    memset(c, 0, sizeof(*c));
}

const char *pe_conn_strerror(int rc)
{
    switch (rc) {
    case PE_CONN_OK:          return "ok";
    case PE_CONN_NO_DEVICE:   return "no PEGpuAccelerator service (kext not loaded?)";
    case PE_CONN_NO_MAP:      return "the device's memory could not be mapped";
    case PE_CONN_BAD_VERSION: return "the device speaks a protocol this build does not";
    default:                  return "unknown error";
    }
}
