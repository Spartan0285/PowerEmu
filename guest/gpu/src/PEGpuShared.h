/*
 * The ABI between the PowerEmu GPU kext and the OpenGL renderer plugin.
 *
 * poweremu-qemu's include/hw/display/poweremu_gpu_ring.h is the source of
 * truth for the packet protocol, and the plugin should include it directly.
 * Repeated here is only the part the *kernel* side touches -- the BAR
 * layout, the control registers, and the two mapping types -- because the
 * less of that protocol is duplicated, the less of it can drift.
 *
 * Byte order
 * ----------
 * Every multi-byte field in the control page is big-endian, and this guest
 * is big-endian PowerPC, so a plain volatile UInt32 load or store already
 * holds the value the host expects.  There are no swaps anywhere in this
 * driver and none are missing: if this code is ever built for a
 * little-endian guest, every access to fCtrl becomes wrong at once, which
 * is preferable to scattering conditional swaps through it now.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef PEGPU_SHARED_H
#define PEGPU_SHARED_H

#define kPEGpuServiceClass      "PEGpuAccelerator"
#define kPEGpuUserClientClass   "PEGpuUserClient"
#define kPEGpuBundleIdentifier  "com.spartan0285.poweremu.gpu"

/*
 * The property Apple's OpenGL reads to decide which renderer plugin to
 * load, and the value we publish for it.  OpenGL then opens
 * /System/Library/Extensions/PowerEmuGPUGLDriver.bundle, exactly the way
 * ATIRadeon8500.kext's "ATIRadeon8500GLDriver" makes it open
 * ATIRadeon8500GLDriver.bundle.
 */
#define kPEGpuGLBundleNameKey   "IOGLBundleName"
#define kPEGpuGLBundleName      "PowerEmuGPUGLDriver"

/*
 * Mapping types for IOConnectMapMemory().
 *
 * There is deliberately no "whole BAR" type.  Every offset a packet carries
 * is relative to the ring base (see poweremu_gpu_ring.h), so the shared
 * mapping's base address and the protocol's offset zero are the same place;
 * a whole-BAR mapping would put a 0x1000 bias in front of every offset the
 * plugin computes, and that bias would be invisible until the host rejected
 * something for being out of bounds.
 */
enum {
    kPEGpuMemoryControl = 0,        /* the 4 KB trapping control page */
    kPEGpuMemoryShared  = 1         /* ring + data, 33 MB of plain memory */
};

/*
 * External methods.  The plugin does not need these -- it rings the
 * doorbell by storing to the mapped control page, which is one emulator
 * exit with no Mach trap in front of it.  They exist as an escape hatch: if
 * a user-space store to device memory turns out to misbehave on 10.4 PPC,
 * this is the fallback that does not require another trip to the G4.
 */
enum {
    kPEGpuMethodDoorbell = 0,       /* scalar in: new ring head, in bytes */
    kPEGpuMethodCount
};

/* Mirrors PE_GPU_* in poweremu_gpu_ring.h. */
#define kPEGpuMagic         0x50454750u     /* 'PEGP' */
#define kPEGpuVersion       1u

#define kPEGpuCtrlOffset    0x0000u
#define kPEGpuCtrlSize      0x1000u
#define kPEGpuRingOffset    0x1000u
#define kPEGpuRingBytes     (1u << 20)
#define kPEGpuDataBytes     (32u << 20)
#define kPEGpuSharedBytes   (kPEGpuRingBytes + kPEGpuDataBytes)
#define kPEGpuBarBytes      (kPEGpuCtrlSize + kPEGpuSharedBytes)

/*
 * Control registers as UInt32 indices rather than byte offsets: they are
 * eight consecutive naturally aligned words, and indexing a volatile
 * UInt32 * is the only form of access the device accepts (its MemoryRegion
 * declares min and max access size 4).
 */
enum {
    kPEGpuRegMagic = 0,             /* R: kPEGpuMagic */
    kPEGpuRegVersion,               /* R: kPEGpuVersion */
    kPEGpuRegFeatures,              /* R: PE_GPU_FEAT_* */
    kPEGpuRegEnable,                /* W: 1 to take over scanout */
    kPEGpuRegDoorbell,              /* W: new ring head, in bytes */
    kPEGpuRegTail,                  /* R: bytes the host consumed */
    kPEGpuRegFence,                 /* R: last completed fence */
    kPEGpuRegError                  /* R/W: PE_GPU_ERR_*, write to clear */
};

#endif /* PEGPU_SHARED_H */
