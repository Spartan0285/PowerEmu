/*
 * PowerEmu paravirtual OpenGL renderer for Mac OS X 10.4 (PowerPC).
 *
 * Mac OS X loads OpenGL in two plug-in layers: the OpenGL framework loads
 * GLEngine.bundle, and GLEngine loads a *renderer* bundle and binds a fixed,
 * ordered list of gld* entry points out of it.  GLEngine finds that bundle
 * one of two ways:
 *
 *   - hardware: it reads the IOKit property IOGLBundleName from the
 *     accelerator and loads /System/Library/Extensions/<name>.bundle, or
 *   - software: it scans $GL_RESOURCES (default the OpenGL framework's own
 *     Resources directory) for bundles whose name starts with "GLDriver" or
 *     "GLRendererFloat".
 *
 * The second path needs no kernel code and no root, which is why this file
 * exists before the kext does: it lets the renderer, the command protocol
 * and the host be brought up and debugged on a real guest, per process,
 * with nothing installed.  Quartz Extreme will not composite through a
 * renderer found this way -- that decision is made in CoreGraphics from
 * IOKit properties -- but games that just want an accelerated context will.
 *
 * Every entry point GLEngine looks up must exist or it unlinks the module
 * and silently falls back to Apple's software renderer.  The list below is
 * exactly what GLEngine 10.4.11 asks for, in its own order (see
 * entrypoints.txt, extracted from the guest's GLEngine).
 *
 * This is a skeleton: it proves the load path and records what GLEngine
 * asks of it.  The signatures are not yet known -- recovering them from
 * ATIRadeon8500GLDriver is in progress -- so every stub takes no declared
 * arguments and returns 0.  That is safe on PowerPC: arguments arrive in
 * r3..r10 and are simply ignored, and the caller cleans up nothing.  What
 * it is NOT is a working renderer; anything that actually gets drawn
 * through it would be wrong.  The log tells us the call order to implement.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

static FILE *pe_log;
static int pe_calls;

static void pe_open_log(void)
{
    const char *path = getenv("PEGLD_LOG");

    if (!path) {
        path = "/tmp/pegld.log";
    }
    pe_log = fopen(path, "a");
    if (pe_log) {
        setvbuf(pe_log, NULL, _IOLBF, 0);   /* survive a crash mid-call */
    }
}

/*
 * Record that GLEngine called us.  The order and the count are the point:
 * they say which entry points a real renderer has to implement first, and
 * in what sequence a context is built up.
 */
static void pe_note(const char *fn)
{
    struct timeval tv;

    if (!pe_log) {
        pe_open_log();
        if (!pe_log) {
            return;
        }
        fprintf(pe_log, "--- PowerEmu GLD loaded, pid %d\n", (int)getpid());
    }
    gettimeofday(&tv, NULL);
    fprintf(pe_log, "%3d %ld.%06d %s\n", ++pe_calls, (long)tv.tv_sec,
            (int)tv.tv_usec, fn);
}

#define PE_STUB(name)                       \
    long name(void)                         \
    {                                       \
        pe_note(#name);                     \
        return 0;                           \
    }

/*
 * The two GLEngine looks up by name before anything else.  A renderer that
 * fails initialisation is dropped, so this one succeeds and does nothing.
 */
long gldInitializeLibrary(void)
{
    pe_note("gldInitializeLibrary");
    return 1;
}

PE_STUB(gldTerminateLibrary)

/*
 * GLEngine reads the renderer's identity from here.  The four words are
 * (interface major, interface minor, interface patch, renderer id); Apple's
 * bundles all report 2.4.11 on Tiger and differ only in the last word,
 * which is the low half of the CGLRenderers.h renderer ID.  Claiming an ID
 * Apple has assigned to a real card would be a lie that CGL propagates to
 * applications, so use the one slot Apple never shipped a driver for.
 */
long gldGetVersion(unsigned int *iface_major, unsigned int *iface_minor,
                   unsigned int *iface_patch, unsigned int *renderer_id)
{
    char note[64];
    const char *idenv = getenv("PEGLD_ID");

    snprintf(note, sizeof(note), "gldGetVersion id=%s", idenv ? idenv : "0x1602");
    pe_note(note);
    if (iface_major) {
        *iface_major = 2;
    }
    if (iface_minor) {
        *iface_minor = 4;
    }
    if (iface_patch) {
        *iface_patch = 11;
    }
    if (renderer_id) {
        /*
         * GLEngine validates what we claim here and drops the renderer if
         * it does not like it, so the value is settable while we find out
         * empirically which ones it accepts.
         */
        const char *env = getenv("PEGLD_ID");
        *renderer_id = env ? (unsigned int)strtoul(env, NULL, 0) : 0x1602;
    }
    return 1;
}

PE_STUB(gldChoosePixelFormat)
PE_STUB(gldDestroyPixelFormat)
PE_STUB(gldGetRendererInfo)
PE_STUB(gldCreateShared)
PE_STUB(gldDestroyShared)
PE_STUB(gldCreateContext)
PE_STUB(gldDestroyContext)
PE_STUB(gldReclaimContext)
PE_STUB(gldAttachDrawable)
PE_STUB(gldGetInteger)
PE_STUB(gldSetInteger)
PE_STUB(gldInitDispatch)
PE_STUB(gldUpdateDispatch)
PE_STUB(gldCreateTexture)
PE_STUB(gldCreateTextureLevel)
PE_STUB(gldModifyTexture)
PE_STUB(gldModifyTextureLevel)
PE_STUB(gldGetTextureLevelInfo)
PE_STUB(gldGetTextureLevel)
PE_STUB(gldDeleteTextureLevel)
PE_STUB(gldDeleteTexture)
PE_STUB(gldIsTextureResident)
PE_STUB(gldReclaimTexture)
PE_STUB(gldFlush)
PE_STUB(gldFinish)
PE_STUB(gldGetString)
PE_STUB(gldGetError)
PE_STUB(gldAllocVertexBuffer)
PE_STUB(gldCompleteVertexBuffer)
PE_STUB(gldFreeVertexBuffer)
PE_STUB(gldCreatePipelineProgram)
PE_STUB(gldModifyPipelineProgram)
PE_STUB(gldRelatePipelineProgram)
PE_STUB(gldGetPipelineProgramInfo)
PE_STUB(gldDestroyPipelineProgram)
PE_STUB(gldCreateVertexArray)
PE_STUB(gldModifyVertexArray)
PE_STUB(gldFlushVertexArray)
PE_STUB(gldDestroyVertexArray)
PE_STUB(gldReclaimVertexArray)
PE_STUB(gldCreateFence)
PE_STUB(gldDestroyFence)
PE_STUB(gldTestObject)
PE_STUB(gldFinishObject)
PE_STUB(gldCreateQuery)
PE_STUB(gldDestroyQuery)
PE_STUB(gldGetQueryInfo)
PE_STUB(gldCreateBuffer)
PE_STUB(gldDestroyBuffer)
PE_STUB(gldFlushBuffer)
PE_STUB(gldReclaimBuffer)
PE_STUB(gldPageoffBuffer)
PE_STUB(gldGetMemoryPluginData)
PE_STUB(gldSetMemoryPluginData)
PE_STUB(gldFinishMemoryPluginData)
PE_STUB(gldTestMemoryPluginData)
PE_STUB(gldDestroyMemoryPluginData)
PE_STUB(gldCreateFramebuffer)
PE_STUB(gldReclaimFramebuffer)
PE_STUB(gldDestroyFramebuffer)
