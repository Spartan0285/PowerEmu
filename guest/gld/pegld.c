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

/*
 * Tracing proxy.
 *
 * Guessing at undocumented struct fields one rebuild at a time is slow and
 * wrong more often than right.  With PEGLD_PROXY=<path to a real GLD> we
 * load Apple's driver alongside ours, forward the calls we are unsure about,
 * and dump exactly what it produces.  That turns "what does CGL want in a
 * pixel format" from inference into a hexdump.
 */
#include <dlfcn.h>

static void *pe_proxy;

static void *pe_proxy_sym(const char *name)
{
    const char *path = getenv("PEGLD_PROXY");

    if (!path) {
        return NULL;
    }
    if (!pe_proxy) {
        pe_proxy = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
        if (!pe_proxy) {
            pe_note("proxy: dlopen failed");
            return NULL;
        }
    }
    return dlsym(pe_proxy, name);
}

static void pe_dump(const char *what, const void *p, int bytes)
{
    const unsigned char *b = p;
    char line[128];
    int i, n = 0;

    if (!pe_log || !b) {
        return;
    }
    fprintf(pe_log, "    %s %d bytes:\n", what, bytes);
    for (i = 0; i < bytes; i++) {
        n += snprintf(line + n, sizeof(line) - n, "%02x", b[i]);
        if ((i & 15) == 15) {
            fprintf(pe_log, "      +%02x %s\n", i & ~15, line);
            n = 0;
        } else if ((i & 3) == 3) {
            n += snprintf(line + n, sizeof(line) - n, " ");
        }
    }
    if (n) {
        fprintf(pe_log, "      +%02x %s\n", i & ~15, line);
    }
}

/*
 * Every entry point we have not implemented yet.
 *
 * With PEGLD_PROXY set these forward to a real driver, which makes this
 * bundle a complete tracing shim: OpenGL works normally, through Apple's
 * renderer, while we record the exact call sequence a real workload
 * produces.  That trace is what tells us which of the 63 entry points
 * actually matter and in what order -- far better evidence than reasoning
 * about which ones ought to.
 *
 * The uniform seven arguments are deliberate.  PowerPC passes the first
 * eight integer/pointer arguments in r3..r10 and the callee simply ignores
 * registers it does not read, so forwarding seven works for any of these
 * functions without knowing its true arity.
 */
#define PE_STUB(name)                                                   \
    long name(void *a1, void *a2, void *a3, void *a4,                   \
              void *a5, void *a6, void *a7)                             \
    {                                                                   \
        long (*real)(void *, void *, void *, void *, void *, void *,    \
                     void *) = pe_proxy_sym(#name);                     \
                                                                        \
        pe_note(#name);                                                 \
        if (real) {                                                     \
            return real(a1, a2, a3, a4, a5, a6, a7);                    \
        }                                                               \
        return 0;                                                       \
    }

/*
 * The two GLEngine looks up by name before anything else.  A renderer that
 * fails initialisation is dropped, so this one succeeds and does nothing.
 */
long gldInitializeLibrary(void *services, void *a2, unsigned int display_mask,
                          void *a4, void *callback)
{
    long (*real)(void *, void *, unsigned int, void *, void *);

    pe_note("gldInitializeLibrary");
    real = pe_proxy_sym("gldInitializeLibrary");
    if (real) {
        long r = real(services, a2, display_mask, a4, callback);

        if (pe_log) {
            fprintf(pe_log, "    proxy gldInitializeLibrary -> %ld (mask %08x)\n",
                    r, display_mask);
        }
        return r;
    }
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

/*
 * CGL asks which pixel formats we can offer for a set of attributes, and
 * takes a malloc'd singly-linked list back: 0x34 bytes per entry, chained
 * through the word at +0x00, with the display mask at +0x30 (both recovered
 * from Apple's driver -- see abi/gld_abi.h).  One format is enough to get a
 * context created, which is what we are after; refusing everything here is
 * how Apple's own driver implements GL_REJECT_HW.
 */
long gldChoosePixelFormat(void **out_list, const int *attribs)
{
    unsigned char *pf;

    pe_note("gldChoosePixelFormat");
    if (!out_list) {
        return 0;
    }
    {
        long (*real)(void **, const int *) = pe_proxy_sym("gldChoosePixelFormat");

        if (real) {
            void *list = NULL;
            long r = real(&list, attribs);

            if (pe_log) {
                fprintf(pe_log, "    proxy gldChoosePixelFormat -> %ld list=%p\n",
                        r, list);
            }
            if (list) {
                pe_dump("pixelformat", list, 0x34);
                *out_list = list;       /* hand the real one straight through */
                return r;
            }
        }
    }
    if (getenv("PEGLD_NOFORMATS")) {
        *out_list = NULL;               /* offer nothing, like GL_REJECT_HW */
        return 0;
    }
    /*
     * Shape copied from what Apple's driver actually returns (captured with
     * PEGLD_PROXY -- see abi/NOTES.md and the log dump):
     *
     *   +00 next  +04 rendererID  +08 buffer modes  +10 colour mode
     *   +18 depth mode  +1c stencil mode  +30 display mask
     *
     * The important correction over the earlier guess: each entry describes
     * ONE concrete configuration and they are chained, rather than one entry
     * advertising every capability mask at once.  CGL hands an application a
     * single entry, so a format claiming everything is not usable and gets
     * dropped.
     */
    pf = calloc(1, 0x34);
    if (!pf) {
        *out_list = NULL;
        return 0;
    }
    {
        const char *env = getenv("PEGLD_ID");
        unsigned int id = env ? (unsigned int)strtoul(env, NULL, 0) : 0x2000;

        *(void **)(pf + 0x00) = NULL;                 /* single entry      */
        *(unsigned int *)(pf + 0x04) = id;            /* renderer ID       */
        *(unsigned int *)(pf + 0x08) = 0x511;         /* buffer modes      */
        *(unsigned int *)(pf + 0x0c) = 0;
        *(unsigned int *)(pf + 0x10) = 0x400;         /* one colour mode   */
        *(unsigned int *)(pf + 0x14) = 0;             /* no accum          */
        *(unsigned int *)(pf + 0x18) = 1;             /* one depth mode    */
        *(unsigned int *)(pf + 0x1c) = 1;             /* one stencil mode  */
        *(unsigned int *)(pf + 0x30) = 1;             /* display 1         */
    }
    *out_list = pf;
    return 0;
}

long gldDestroyPixelFormat(void *pf)
{
    long (*real)(void *) = pe_proxy_sym("gldDestroyPixelFormat");

    pe_note("gldDestroyPixelFormat");
    if (real) {
        return real(pf);
    }
    free(pf);
    return 0;
}

/*
 * GLEngine hands us a caller-allocated block (at least 0x38 bytes per the
 * disassembly of Apple's driver) and publishes what we put in it through
 * CGLDescribeRenderer.  The field layout is not documented and Apple's
 * driver fills it from a kext selector we do not have, so recover the
 * mapping the direct way: write a distinct marker into every word and see
 * which CGL property reports which marker back.  PEGLD_PROBE=1 turns that
 * on; otherwise report something honest and modest.
 */
long gldGetRendererInfo(void *out, unsigned int display_mask)
{
    unsigned int *w = out;
    int i;

    pe_note("gldGetRendererInfo");
    if (!w) {
        return 0;
    }
    {
        long (*real)(void *, unsigned int) = pe_proxy_sym("gldGetRendererInfo");

        if (real) {
            long r = real(out, display_mask);

            if (pe_log) {
                fprintf(pe_log, "    proxy gldGetRendererInfo -> %ld\n", r);
            }
            pe_dump("rendererinfo", out, 0x38);
            return r;
        }
    }
    if (getenv("PEGLD_PROBE")) {
        for (i = 0; i < 16; i++) {
            w[i] = 0xA0000000u | i;     /* word index, recoverable in CGL */
        }
        return 0;
    }
    /*
     * Field offsets recovered by probing: each word was filled with its own
     * index and read back through CGLDescribeRenderer (PEGLD_PROBE=1 still
     * does this).  Words 8-10 pack two 16-bit counts each, which is why the
     * probe made them look like nonsense.
     */
    for (i = 0; i < 16; i++) {
        w[i] = 0;
    }
    /*
     * Word 1 is what CGL reports as the renderer ID (probe: it echoed the
     * marker there straight back through kCGLRPRendererID).  Give ourselves
     * a distinct one so an application can ask for this renderer by name
     * rather than being handed whichever CGL ranks highest.
     */
    {
        const char *env = getenv("PEGLD_ID");
        w[1] = env ? (unsigned int)strtoul(env, NULL, 0) : 0x2000;
    }
    w[3]  = 0x0d;               /* BufferModes: double | accelerated bits   */
    w[4]  = 0xca00;             /* ColorModes: the modes the R200 path has  */
    w[5]  = 0x00c0c000;         /* AccumModes                               */
    w[6]  = 0x1401;             /* DepthModes: 16 and 24/32 bit             */
    w[7]  = 0x81;               /* StencilModes: none and 8 bit             */
    w[12] = 128u << 20;         /* VideoMemory                              */
    w[13] = 128u << 20;         /* TextureMemory                            */
    return 0;
}
PE_STUB(gldCreateShared)
PE_STUB(gldDestroyShared)
/*
 * Seven arguments, per the disassembly of Apple's driver: the context out
 * parameter, the pixel format, the shared object, two we have not yet
 * identified, the GL object state block, and one more.  Apple's context is
 * malloc(0xFB8); ours only has to be something CGL can hold onto and hand
 * back to us, but keeping the same size costs nothing and leaves room to
 * grow into the same layout if that turns out to matter.
 *
 * Returning success without storing a context is what made CGL dereference
 * garbage before this existed.
 */
long gldCreateContext(void **ctx_out, void *pf, void *shared, void *a4,
                      void *a5, void *gl_state, void *a7)
{
    long (*real)(void **, void *, void *, void *, void *, void *, void *) =
        pe_proxy_sym("gldCreateContext");

    pe_note("gldCreateContext");
    if (real) {
        long r = real(ctx_out, pf, shared, a4, a5, gl_state, a7);

        if (pe_log) {
            fprintf(pe_log, "    proxy gldCreateContext -> %ld ctx=%p\n",
                    r, ctx_out ? *ctx_out : NULL);
        }
        return r;
    }
    if (!ctx_out) {
        return 10000;                   /* kGLDBadAddress */
    }
    *ctx_out = calloc(1, 0xFB8);
    return *ctx_out ? 0 : 10004;        /* kGLDBadAlloc */
}

long gldDestroyContext(void *ctx)
{
    long (*real)(void *) = pe_proxy_sym("gldDestroyContext");

    pe_note("gldDestroyContext");
    if (real) {
        return real(ctx);
    }
    free(ctx);
    return 0;
}
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
