/*
 * gld_abi.h -- Apple "GLD" (OpenGL Driver plugin) ABI, Mac OS X 10.4 / PowerPC
 *
 * Reverse-engineered from /tmp/ATIRadeon8500GLDriver (PPC MH_BUNDLE, 10.4.11,
 * linked 2007-10-04).  See NOTES.md in this directory for the evidence trail.
 *
 * EVERY prototype below is tagged:
 *
 *   [CONFIRMED]  argument count and use are visible in the disassembly
 *   [INFERRED]   plausible from context, NOT proven
 *   [UNKNOWN]    could not be determined -- do not trust the prototype
 *
 * A universal caveat: argument counts were recovered as "highest rN read before
 * it is written" under the 32-bit PowerPC Darwin ABI (r3..r10, then 24(r1)+).
 * That CANNOT see a trailing argument the callee ignores.  Every count here is
 * therefore a LOWER BOUND.
 *
 * Return values are CGLError (long), 0 == success, unless noted.
 */

#ifndef GLD_ABI_H
#define GLD_ABI_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>
#include <OpenGL/gl.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef long GLDReturn;   /* CGLError: 0, or 0x2710 + n.  See table below. */

/* CGLError values actually produced by this plugin. [CONFIRMED] */
enum {
    kGLDNoError           = 0,
    kGLDBadAttribute      = 10000, /* 0x2710 unknown pixel-format attribute   */
    kGLDBadPixelFormat    = 10002, /* 0x2712                                  */
    kGLDBadContext        = 10004, /* 0x2714 NULL context                     */
    kGLDBadDrawable       = 10005, /* 0x2715                                  */
    kGLDBadDisplay        = 10006, /* 0x2716 display mask not supported       */
    kGLDBadState          = 10007, /* 0x2717                                  */
    kGLDBadValue          = 10008, /* 0x2718                                  */
    kGLDBadMatch          = 10009, /* 0x2719                                  */
    kGLDBadEnumeration    = 10010, /* 0x271a unknown param / object type      */
    kGLDBadAddress        = 10014, /* 0x271e NULL out-pointer                 */
    kGLDBadCodeModule     = 10015, /* 0x271f kernel setup failed              */
    kGLDBadAlloc          = 10016, /* 0x2720                                  */
    kGLDBadConnection     = 10018  /* 0x2722                                  */
};

/* Opaque objects.  Known sizes are noted; all are plugin-private. */
typedef struct gld_context      gld_context_t;      /* 0x0FB0 bytes [CONFIRMED] */
typedef struct gld_shared       gld_shared_t;       /* 0x0034 bytes [CONFIRMED] */
typedef struct gld_pixelformat  gld_pixelformat_t;  /* 0x0034 bytes [CONFIRMED] */
typedef struct gld_texture      gld_texture_t;      /* 0x005C bytes [CONFIRMED] */
typedef struct gld_buffer       gld_buffer_t;       /* 0x0024 bytes [CONFIRMED] */
typedef struct gld_vertexarray  gld_vertexarray_t;  /* 0x01C4 bytes [CONFIRMED] */
typedef struct gld_program      gld_program_t;      /* 0x002C bytes [CONFIRMED] */
typedef struct gld_fence        gld_fence_t;        /* 0x0008 bytes [CONFIRMED] */
typedef struct gld_query        gld_query_t;        /* 0x0004 bytes [CONFIRMED] */
typedef struct gld_memplugin    gld_memplugin_t;    /* 0x0008 bytes [CONFIRMED] */

/* The plugin calls this, supplied as gldInitializeLibrary's 5th argument.
 * Reached via `bctrl` from gldAttachDrawable at 0x5820 with 5 arguments.
 * Signature beyond the arity is [UNKNOWN]. */
typedef int (*gld_surface_cb_t)(void *a, void *b, uint32_t surfaceID,
                                void *d, io_service_t service);


/* ===================================================================== */
/* 1.  Library lifecycle                                                 */
/* ===================================================================== */

/* [CONFIRMED] 5 args (r3..r7 read, r8 not), returns void.
 * Fills the module-global device table at 0x25E5A0:
 *   G[0x00]=displayMask  G[0x04]=displayCount  G[0x08]=services
 *   G[0x0c]=a2           G[0x10]=a4            G[0x14]=surfaceCallback
 * displayCount = (index of highest set bit in displayMask) + 1.
 * Evidence: 0x6e58-0x6eac. THE FRAMEWORK SUPPLIES THE io_service_t ARRAY --
 * the plugin never calls IOServiceGetMatchingServices. */
void      gldInitializeLibrary(io_service_t *services,
                               void *a2,
                               uint32_t displayMask,
                               void *a4,
                               gld_surface_cb_t surfaceCallback);

/* [CONFIRMED] 0 args, void.  Zeroes G[0x00..0x14].  Evidence: 0x6ed4-0x6ee8. */
void      gldTerminateLibrary(void);

/* [CONFIRMED] 4 pointer args, all written; returns 0 until the library is
 * initialised, else 1.  Values written: 2, 4, 11, 0x1600.
 * The MEANING of those four values is [UNKNOWN].  Evidence: 0x230f14. */
GLboolean gldGetVersion(GLint *a, GLint *b, GLint *c, GLint *d);

/* [CONFIRMED] name must be in [0x1F00, 0x1F04] (GL_VENDOR..GL_EXTENSIONS + 1),
 * else NULL.  GL_RENDERER picks one of three strings from ctx->0x24, the first
 * capability word returned by user-client selector 3.  Evidence: 0x230f68. */
const char *gldGetString(gld_context_t *ctx, GLenum name);

/* [CONFIRMED] 1 arg.  Body is 4 instructions:
 *   r = ctx->0x110; ctx->0x110 = 0; return r;   Evidence: 0x5c74. */
GLDReturn gldGetError(gld_context_t *ctx);


/* ===================================================================== */
/* 2.  Pixel format / renderer enumeration                               */
/* ===================================================================== */

/* [CONFIRMED] 2 args.  attribs is a 0-terminated int array, max 36 entries.
 * Returns a malloc'd ARRAY of gld_pixelformat_t (0x34 bytes each) chained
 * through field +0x00; *outList is the head.
 * NOTE: getenv("GL_REJECT_HW") != NULL makes it succeed with *outList = NULL --
 * the driver's global hardware-disable switch (0x6408).
 * Errors: kGLDBadAddress (NULL out), kGLDBadAttribute (unknown attr or >36),
 *         kGLDBadAlloc.  Evidence: 0x639c, jump table at 0x6460. */
GLDReturn gldChoosePixelFormat(gld_pixelformat_t **outList, const int *attribs);

/* [CONFIRMED] 1 arg.  free(pf).  NULL -> kGLDBadAddress.  Evidence: 0x6c3c. */
GLDReturn gldDestroyPixelFormat(gld_pixelformat_t *pf);

/* [CONFIRMED] 2 args.  outRendererInfo is >= 0x38 bytes, caller-allocated.
 * Opens USER-CLIENT TYPE 1 (0x6d34) and issues selector 3 (0 scalars in,
 * 3 out) at 0x6d64, then closes.  displayMask must be a non-empty subset of
 * the global mask, else kGLDBadMatch.  Evidence: 0x6c70. */
GLDReturn gldGetRendererInfo(void *outRendererInfo, uint32_t displayMask);


/* ===================================================================== */
/* 3.  Context lifecycle                                                 */
/* ===================================================================== */

/* [CONFIRMED] exactly 7 integer/pointer arguments: r3..r9 are all moved to
 * callee-saved registers at 0x4c5c-0x4c70, r10 is untouched, and there is no
 * load from 24(r1)+.
 *
 *   ctxOut     [CONFIRMED] *ctxOut = 0 at 0x4c84; NULL -> kGLDBadAddress
 *   pf         [CONFIRMED] read-only; pf->0x30 display mask checked at 0x4c9c
 *   shared     [CONFIRMED] stored at ctx+0x0c and passed straight to
 *              pthread_mutex_lock (0xafab8, 0xb0174, 0xb02a4, 0x9654,
 *              0x218c8).  gldCreateShared allocates exactly this.
 *   shareCtx   [INFERRED]  if non-NULL, IOConnectAddClient(newConn,
 *              shareCtx->0x04) at 0x4d74.  Only +0x04 is read; +0x04 of a gld
 *              context is its io_connect_t, hence "another gld context".
 *   engineA    [UNKNOWN type] stored at ctx+0x14; a struct with a uint8 at
 *              +0x26 (0x4004) and a word at +0x120 (0xb0bd8)
 *   engineState[UNKNOWN type] stored at ctx+0x10; >= 0x2DBA bytes, proven by
 *              `lhz r3,0x2db8(r27)` at 0x165a4
 *   objects    [CONFIRMED use] stored at ctx+0x18: the GL object state block.
 *              Its head is the texture binding table indexed [unit*5 + target]
 *              (0x3fbc-0x3fcc, and gldSetInteger param 668); +0x194 is the
 *              current vertex array, whose +0x1a8 is its buffer (param 669).
 *
 * Side effects: malloc(0xFB8); IOServiceOpen(service, mach_task_self_,
 * USER-CLIENT TYPE 1, &ctx->0x04) at 0x4d54; selector 3 -> ctx->0x24..0x2c;
 * four IOConnectMapMemory calls (types 0,1,2,4); links onto a global list.
 * Errors: kGLDBadAddress, kGLDBadDisplay, kGLDBadCodeModule. */
GLDReturn gldCreateContext(gld_context_t **ctxOut,
                           const gld_pixelformat_t *pf,
                           gld_shared_t *shared,
                           gld_context_t *shareCtx,
                           void *engineA,
                           void *engineState,
                           void **objects);

/* [CONFIRMED] 1 arg.  NULL -> kGLDBadContext, else 0.  IOServiceClose,
 * frees ctx->0xe4 (accum buffer), ctx->0x17c (fence bitmap), ctx.  0x541c. */
GLDReturn gldDestroyContext(gld_context_t *ctx);

/* [CONFIRMED] 1 arg, no meaningful return.  Issues user-client selector 0x11
 * with no arguments (0x55e8); if that FAILS, free(ctx).  Evidence: 0x55b8. */
void      gldReclaimContext(gld_context_t *ctx);

/* [CONFIRMED] 1 arg each.  gldCreateShared: malloc(0x34),
 * pthread_mutex_init(obj+0, PTHREAD_MUTEX_RECURSIVE), obj->0x2c = obj->0x30 =
 * &obj->0x2c.  The FIRST MEMBER IS A pthread_mutex_t -- that is how the object
 * can be passed straight to pthread_mutex_lock elsewhere.
 * Errors: kGLDBadAddress / kGLDBadAlloc / kGLDBadContext.  0x54f0, 0x556c. */
GLDReturn gldCreateShared(gld_shared_t **sharedOut);
GLDReturn gldDestroyShared(gld_shared_t *shared);

/* [CONFIRMED] 4 args (r7 never read).
 *   type     one of 0x50, 0x5A (same path), 0x36 (opens USER-CLIENT TYPE 0 at
 *            0x5948), 0x35, or 0 with drawable == NULL (detach).  Anything
 *            else -> kGLDBadEnumeration.  The NAMES of these constants are
 *            [UNKNOWN].
 *   drawable NULL -> kGLDBadDrawable.  Read at +0x00, +0x04 and +0x08;
 *            +0x08 is the surface ID sent to the kernel.
 *   flags    split into two bytes: ctx->0x98 = (flags>>8)&0xFF,
 *            ctx->0x9c = flags&0xFF (0x56f4, 0x56f8, stored 0x5be4).
 * Kernel: selector 6 (1 scalar in / 3 out) at 0x5768; selector 0 with 4
 * scalars {surfaceID, ctx->0x3c & 0xFFFF3FC0, flags>>8 & 0xff, flags & 0xff}
 * at 0x5868; selector 0x0E with ctx->0xd0..0xd8 if ctx->0xe1.  0x56bc. */
GLDReturn gldAttachDrawable(gld_context_t *ctx, GLint type,
                            void *drawable, GLuint flags);


/* ===================================================================== */
/* 4.  Dispatch table                                                    */
/* ===================================================================== */
/*
 * There is NO exported dispatch struct, NO constructor and NO registration
 * function in this bundle -- the framework resolves the gld* names directly
 * (MH_BUNDLE + NSLookupSymbolInModule on 10.4).  Instead it hands the plugin a
 * table to FILL IN.
 *
 * The table is a GLD-private array of function pointers, at least 0x84 bytes
 * (~33 slots).  It is NOT `GLIFunctionDispatch` from <OpenGL/gliDispatch.h>:
 * that struct has 686 fields and puts finish/flush at +0x164/+0x168, whereas
 * this table receives gldFinish at +0x58 and gldFlush at +0x5c.
 *
 * Measured layout (base register r26 == arg2, verified at 0x21a70/0x21a98):
 *   +0x00         accum(ctx, GLenum op, GLfloat value)      [CONFIRMED:
 *                 range-checks op-0x100 <= 4 == GL_ACCUM..GL_ADD, and is gated
 *                 on ctx->0xe4, the software accum buffer]
 *   +0x04..+0x14  set once by gldInitDispatch                [names UNKNOWN]
 *   +0x18..+0x3c  10 slots swapped WHOLESALE between 15 variant families by
 *                 gldUpdateDispatch -- the state-selected fast paths. Each
 *                 member is f(ctx, a, b) forwarding to a shared helper with a
 *                 per-slot constant.                          [names UNKNOWN]
 *   +0x40..+0x48  never written
 *   +0x4c..+0x54  set once by gldInitDispatch                [names UNKNOWN]
 *   +0x58         gldFinish (or internal 0x19280)             [CONFIRMED]
 *   +0x5c         gldFlush  (or internal 0x1986c)             [CONFIRMED]
 *   +0x60         0x1a11c / 0x1986c / 0x19cc4                 [name UNKNOWN]
 *   +0x64..+0x80  set once by gldInitDispatch                [names UNKNOWN]
 */

/* [CONFIRMED] 3 args.  Copies ctx->0xf4..0x108 (6 words) into maskOut[0..5],
 * stores `disp` at ctx->0x1c, writes 17 function pointers, then tail-calls
 * gldUpdateDispatch with a DIFFERENT 5-word mask copied from a __const
 * template at 0x257F60.  Returns void.  Evidence: 0x21608. */
void gldInitDispatch(gld_context_t *ctx, void *disp, uint32_t maskOut[6]);

/* [CONFIRMED] 3 args.  Re-selects the state-dependent slots and sets bits in
 * mask[0..4] to tell the caller what changed.  Returns void.  0x21780. */
void gldUpdateDispatch(gld_context_t *ctx, void *disp, uint32_t mask[5]);


/* ===================================================================== */
/* 5.  Framebuffer -- STUBS, arity unknowable                            */
/* ===================================================================== */
/* [UNKNOWN] All three read NO argument register:
 *     0x6104: li r3,0 ; blr        0x610c: blr        0x6110: li r3,0 ; blr
 * EXT_framebuffer_object is not implemented by this driver.  The prototypes
 * below are guesses by analogy ONLY -- do not rely on them. */
GLDReturn gldCreateFramebuffer(gld_context_t *ctx, void **outFB);   /* GUESS */
void      gldReclaimFramebuffer(gld_context_t *ctx, void *fb);      /* GUESS */
GLDReturn gldDestroyFramebuffer(gld_context_t *ctx, void *fb);      /* GUESS */


/* ===================================================================== */
/* 6.  Texture                                                           */
/* ===================================================================== */

/* [CONFIRMED] 3 args; r3 is clobbered at 0x7208 before any read, so the
 * context argument is UNUSED.  calloc(1,0x5c); tex->0x30 = glTexRec. 0x71f0 */
GLDReturn gldCreateTexture(gld_context_t *ctx, gld_texture_t **out,
                           void *glTexRec);

/* [CONFIRMED] 5 args, leaf.  Note the asymmetry with Modify/Delete below:
 * THIS one has flags in r5, so face/level are r6/r7.
 * flags is OR'd into tex->0x39; flags&1 forces tex->0x38 = 0xFF (recompute
 * hardware format); flags&7 sets bit (1<<level) in tex->0x24[face].  0x72d4 */
GLDReturn gldCreateTextureLevel(gld_context_t *ctx, gld_texture_t *tex,
                                uint32_t flags, uint32_t face, uint32_t level);

/* [CONFIRMED] 3 args.  Four instructions: tex->0x39 |= flags; return 0. 0x7320 */
GLDReturn gldModifyTexture(gld_context_t *ctx, gld_texture_t *tex,
                           uint32_t flags);

/* [CONFIRMED] args 1-4.  r7 is NEVER READ -- if a 5th argument exists it is
 * invisible here; UNRESOLVED.  level == -1 means "all levels" (cmpwi r6,0xffff
 * sign-extended at 0x7334).  0x7334 */
GLDReturn gldModifyTextureLevel(gld_context_t *ctx, gld_texture_t *tex,
                                uint32_t face, int32_t level);

/* [CONFIRMED] 2 args.  gldReclaimTexture then free(tex).  0x717c */
GLDReturn gldDeleteTexture(gld_context_t *ctx, gld_texture_t *tex);

/* [CONFIRMED] 4 args.  level == -1 == all levels.  May drop the texture's
 * memory object via user-client selector 0x0B.  0x6f00 */
GLDReturn gldDeleteTextureLevel(gld_context_t *ctx, gld_texture_t *tex,
                                uint32_t face, int32_t level);

/* [CONFIRMED] 2 args, returns VOID -- no `li r3` on any return path (0x7164).
 * Unbinds from ctx->0x124..0x138, releases the memory object, drains the
 * allocation list at tex+0x18.  0x6ff4 */
void      gldReclaimTexture(gld_context_t *ctx, gld_texture_t *tex);

/* [CONFIRMED] 2 args, r3 never read.  Whole body:
 *   lwz r0,0x34(r4); addic r2,r0,-1; subfe r3,r2,r0; blr
 * i.e. return tex->0x34 != NULL.  0x6ef0 */
GLboolean gldIsTextureResident(gld_context_t *ctx, gld_texture_t *tex);

/* [CONFIRMED] 6 args.  pname -> offset into a 0x28-byte descriptor built by
 * 0x22c584: GL_TEXTURE_INTERNAL_FORMAT(+0), RED/GREEN/BLUE/ALPHA_SIZE
 * (+4/8/c/10), LUMINANCE/INTENSITY_SIZE(+14/18), GL_TEXTURE_DEPTH_SIZE(+1c),
 * GL_TEXTURE_COMPRESSED_IMAGE_SIZE(+20), GL_TEXTURE_COMPRESSED(+24, byte).
 * An unknown pname leaves *params untouched and STILL RETURNS 0.
 * Proxy textures return kGLDBadAlloc if the total would exceed ctx->0x28.  0x73ec */
GLDReturn gldGetTextureLevelInfo(gld_context_t *ctx, gld_texture_t *tex,
                                 uint32_t face, uint32_t level,
                                 GLenum pname, GLint *params);

/* [CONFIRMED] 5 args.  glGetTexImage read-back into dstPixels (r7 -> the
 * glgProcessPixels dst field at 0x22cc64).  There is NO caller-supplied
 * format/type/packing: they come from the texture's own stored level
 * descriptor.  kGLDBadState if the texture is not CPU-mappable.  0x22c96c */
GLDReturn gldGetTextureLevel(gld_context_t *ctx, gld_texture_t *tex,
                             uint32_t face, uint32_t level, void *dstPixels);


/* ===================================================================== */
/* 7.  Buffer objects and "memory plugin data"                           */
/* ===================================================================== */

/* [CONFIRMED] 4 args; r3 never read (clobbered by `li r3,0x24` at 0x431c).
 * malloc(0x24); b->0x00 = opaque; b->0x04 = engineFlags.  0x4310 */
GLDReturn gldCreateBuffer(gld_context_t *ctx, gld_buffer_t **out,
                          void *opaque, uint32_t *engineFlags);

/* [CONFIRMED] 4 args, void.  NOTE THE OPERAND ORDER: address in r5, length in
 * r6 -- the OPPOSITE of gldFlushVertexArray.  Verified, not assumed.
 * Calls the dcbst/dcbf helper 0x8b18, then *(b->0x04) &= ~3.  0x4508 */
void      gldFlushBuffer(gld_context_t *ctx, gld_buffer_t *b,
                         void *addr, size_t len);

/* [CONFIRMED] 2 args.  gldReclaimBuffer then free(b); returns 0.  0x45a0 */
GLDReturn gldDestroyBuffer(gld_context_t *ctx, gld_buffer_t *b);

/* [CONFIRMED] 2 args, void.  Atomically drops the 0x10000 refcount unit in
 * mem->0x10; at zero issues user-client selector 0x0B (free).  0x45d8 */
void      gldReclaimBuffer(gld_context_t *ctx, gld_buffer_t *b);

/* [CONFIRMED] 2 args, void.  No-op unless mem->0x16 == 7 AND
 * (mem->0x28 & ~mem->0x1c) != 0; then selector 0x0D with {mem->0, 1}.  0x1d6e8 */
void      gldPageoffBuffer(gld_context_t *ctx, gld_buffer_t *b);

/* [CONFIRMED] 3 args, void, r3 never read.  DETACHES the allocation:
 *   *outD = b->0x08; b->0x08 = NULL;   0x4930 */
void      gldGetMemoryPluginData(gld_context_t *ctx, gld_buffer_t *b,
                                 gld_memplugin_t **outD);

/* [CONFIRMED] 3 args, void, r3 never read.  Re-attaches: b->0x08 = D.  0x496c */
void      gldSetMemoryPluginData(gld_context_t *ctx, gld_buffer_t *b,
                                 gld_memplugin_t *D);

/* [CONFIRMED] 2 args, void.  Fence test, else BLOCKS via selector 9.  0x49c4 */
void      gldFinishMemoryPluginData(gld_context_t *ctx, gld_memplugin_t *D);

/* [CONFIRMED] 2 args.  Returns 1 if idle/complete (including D == NULL or an
 * unknown allocation type), 0 if still busy.  0x4a98 */
int       gldTestMemoryPluginData(gld_context_t *ctx, gld_memplugin_t *D);

/* [CONFIRMED] 2 args, void.  Finish, drop refcount, selector 0x0B, free(D). 0x4b30 */
void      gldDestroyMemoryPluginData(gld_context_t *ctx, gld_memplugin_t *D);


/* ===================================================================== */
/* 8.  Vertex arrays                                                     */
/* ===================================================================== */

/* [CONFIRMED] 4 args; r3 clobbered at 0x9600 before any read.
 * calloc(1,0x1c4); va->0x00 = a; va->0x04 = b.  0x95e8 */
GLDReturn gldCreateVertexArray(gld_context_t *ctx, gld_vertexarray_t **out,
                               void *a, void *b);

/* [CONFIRMED] 2 args.  Under pthread_mutex_lock(ctx->0x0c), keeps the existing
 * allocation only if the APPLE storage hint (va->0x00->0x312, e.g.
 * GL_STORAGE_CACHED_APPLE 0x85BE) still matches va->0x1b0; else releases it via
 * selector 0x0B.  Returns 0.  0x963c */
GLDReturn gldModifyVertexArray(gld_context_t *ctx, gld_vertexarray_t *va);

/* [CONFIRMED] 5 args.  ***OPERAND ORDER DIFFERS FROM gldFlushBuffer***:
 * here the address is r6 and the length r5.  r4 (va) is NEVER READ.
 * Body: if (doFlush) { dcacheStore(ctx, addr, len); return 1; } return 0;  0x9720 */
int       gldFlushVertexArray(gld_context_t *ctx, gld_vertexarray_t *va,
                              size_t len, void *addr, int doFlush);

/* [CONFIRMED] 2 args, void (return register not set deterministically).
 * Unbinds from ctx->0x144, waits on the fence, releases via selector 0x0B. 0x9758 */
void      gldReclaimVertexArray(gld_context_t *ctx, gld_vertexarray_t *va);

/* [CONFIRMED] 2 args.  gldReclaimVertexArray then free(va); returns 0.  0x9824 */
GLDReturn gldDestroyVertexArray(gld_context_t *ctx, gld_vertexarray_t *va);


/* ===================================================================== */
/* 9.  The vertex-buffer ring                                            */
/* ===================================================================== */
/*
 * NOT an offset-based head/tail ring.  It is a circular singly-linked list of
 * fixed 0x800-byte DMA slots, at most 128 (ctx->0x170 <= 0x7f):
 *
 *   ctx->0x16c   head = last slot handed out
 *   slot->0x0c   token 9/10/11 (from `kind`)
 *   slot->0x10   next slot
 *   slot->0x14   "client released this slot" flag
 *   slot->0x1c   memory object carrying the completion sequence (at its +0x08)
 *   slot + 0x80  the 0x800-byte payload handed to the caller
 *
 * Completion is tested against the GPU scratch register -- see section 11.
 * Back-pressure: grow the ring first; only spin when it is full, and then only
 * a bare lwbrx poll bounded at 10^6 iterations (0x1a874), after which it
 * proceeds anyway.  There is NO usleep on this path.
 */

/* [CONFIRMED] 3 args.  *ioSize is the requested size in and the granted size
 * out (always 0x800).  A request > 0x800 returns NULL (0x1a724 -- note the
 * compare is SIGNED).  kind &= 0x7FFF; jump table at 0x1a75c maps
 * 1 -> token 9, 2 -> 10, 3 -> 11; kinds 0 and 4..6 return NULL.
 * Returns NULL if ctx->0x20 (the acceleration gate) is 0.  0x1a6e8 */
void     *gldAllocVertexBuffer(gld_context_t *ctx, uint32_t kind,
                               uint32_t *ioSize);

/* [CONFIRMED] 2 args, void, r3 never read.  Entire body:
 *   if (p) *(uint32_t *)((char *)p - 0x6c) = 1;
 * and since p == slot + 0x80, that is slot->0x14, the release flag.  This is
 * the only write of -0x6c(rN) in the whole binary.  0x1aac0 */
void      gldFreeVertexBuffer(gld_context_t *ctx, void *p);

/* [CONFIRMED] A SINGLE `blr`.  Takes no arguments it reads and does nothing.
 * The real prototype is [UNKNOWN]; call it with whatever the engine passes. */
void      gldCompleteVertexBuffer(void);


/* ===================================================================== */
/* 10.  Fence / sync / flush                                             */
/* ===================================================================== */

/* [CONFIRMED] 2 args.  malloc(8) -> { uint32_t slotId; uint8_t done; }.
 * Allocates a slot id from the bitmap at ctx->0x17c; the slot itself lives in
 * the memory-type-4 mapping at ctx->0x174 + (id << 3) as
 * { uint32_t stamp; uint32_t pending; }.  A NEW FENCE IS ALREADY COMPLETE
 * (done = 1, pending = 0).  kGLDBadAlloc on failure.  0x5e04 */
GLDReturn gldCreateFence(gld_context_t *ctx, gld_fence_t **outFence);

/* [CONFIRMED] 2 args.  Clears the bitmap bit, free(f), returns 0.  0x5fdc */
GLDReturn gldDestroyFence(gld_context_t *ctx, gld_fence_t *f);

/* [CONFIRMED] 3 args.  objectType: 0 = fence, 1 = texture, 2 = vertex array,
 * 3 = buffer.  ANY OTHER TYPE RETURNS 1 (0x6078).  Returns a boolean.  0x6018 */
int       gldTestObject(gld_context_t *ctx, int objectType, void *obj);

/* [CONFIRMED] 3 args, same type map.  Unknown type -> kGLDBadEnumeration
 * (0x60f0); otherwise blocks and returns 0.  0x608c */
GLDReturn gldFinishObject(gld_context_t *ctx, int objectType, void *obj);

/* [CONFIRMED] 1 arg.  Submits any pending command buffer, then SPINS on
 * user-client selector 8 while it returns kIOReturnTimeout (0xE00002D6),
 * 0x19240-0x19268.  r3 ends up holding the final kern_return_t.  0x190ec */
void      gldFinish(gld_context_t *ctx);

/* [CONFIRMED] 1 arg.  Same submit body; if there is nothing to submit it
 * returns with r3 still holding ctx, so the return value is MEANINGLESS and
 * every internal caller ignores it.  Treat as void.  0x19704 */
void      gldFlush(gld_context_t *ctx);


/* ===================================================================== */
/* 11.  Occlusion query                                                  */
/* ===================================================================== */

/* [CONFIRMED] 2 args.  malloc(4) -> { uint32_t id }; the id comes from the
 * bitmap at ctx->0x188.  kGLDBadAlloc on failure.  0x80b4 */
GLDReturn gldCreateQuery(gld_context_t *ctx, gld_query_t **outQuery);

/* [CONFIRMED] 2 args.  Clears the bitmap bit, free(q), returns 0.  0x8124 */
GLDReturn gldDestroyQuery(gld_context_t *ctx, gld_query_t *q);

/* [CONFIRMED] 4 args (r7+ never read); ALWAYS returns 0 (0x18efc).
 * Result slot = (uint32_t *)((char *)ctx->0x180 + (q->id << 3) + 0x90);
 * 0xFFFFFFFF is the "not yet written" sentinel.
 *   GL_QUERY_RESULT_ARB (0x8866)           spin <= 10000 x usleep(100)
 *   GL_QUERY_RESULT_AVAILABLE_ARB (0x8867) flush once, report availability
 * Any other pname writes NOTHING and still returns 0.  0x18e38 */
GLDReturn gldGetQueryInfo(gld_context_t *ctx, gld_query_t *q,
                          GLenum pname, uint32_t *out);


/* ===================================================================== */
/* 12.  Pipeline programs (ARB vertex/fragment program)                  */
/* ===================================================================== */

/* [CONFIRMED] 3 args; r3 clobbered at 0x75f8 unread.  calloc(1,0x2c);
 * pp->0x28 = 3; pp->0x00 = glProgRec.  0x75e0 */
GLDReturn gldCreatePipelineProgram(gld_context_t *ctx, gld_program_t **out,
                                   void *glProgRec);

/* [CONFIRMED] 3 args.  pp->0x28 |= flags, then calls 0xb025c which is a single
 * `blr` -- a genuine no-op.  Returns 0.  0x7634 */
GLDReturn gldModifyPipelineProgram(gld_context_t *ctx, gld_program_t *pp,
                                   uint32_t flags);

/* [CONFIRMED] 4 args, leaf, r3 never read.  Dispatches on the SHADER's type
 * (shader->0x00->0x00): GL_VERTEX_SHADER (0x8B31) -> container->0x04,
 * GL_FRAGMENT_SHADER (0x8B30) -> container->0x08, anything else -> no-op.
 * attach == 0 stores NULL (detach).  Returns 0.  0x7664 */
GLDReturn gldRelatePipelineProgram(gld_context_t *ctx,
                                   gld_program_t *container,
                                   gld_program_t *shader, int attach);

/* [CONFIRMED] 4 args; forwards to 0xb0260 and unconditionally returns 0.
 * Answers only the five GL_PROGRAM_NATIVE_*_ARB queries
 * (0x88A2/A6/AA/AE/B2) and only for VERTEX programs; every other pname leaves
 * *params untouched.  0x76b8 */
GLDReturn gldGetPipelineProgramInfo(gld_context_t *ctx, gld_program_t *pp,
                                    GLenum pname, GLint *params);

/* [CONFIRMED] 2 args.  Clears ctx->0x13c/0x140 if they point at pp, tears down
 * the compiled-variant list under ctx->0x0c, free(pp).  0x76dc */
GLDReturn gldDestroyPipelineProgram(gld_context_t *ctx, gld_program_t *pp);


/* ===================================================================== */
/* 13.  Driver parameter namespace                                       */
/* ===================================================================== */

/* [CONFIRMED] 3 args each.  NULL value -> kGLDBadAddress; unknown param ->
 * kGLDBadEnumeration.  `value`/`params` is an int ARRAY whose length depends on
 * the parameter (up to 4 for param 200 / 995).  See NOTES.md section 2.8f for
 * the full table.  0x3c88 / 0x40cc */
GLDReturn gldSetInteger(gld_context_t *ctx, int param, const int *value);
GLDReturn gldGetInteger(gld_context_t *ctx, int param, int *params);

enum {                            /* [CONFIRMED] from the jump tables */
    kGLDParamSwapRect        = 200,   /* set/get int[4]                  */
    kGLDParamSwapRectEnable  = 201,   /* set/get bool                    */
    kGLDParam203             = 203,
    kGLDParamSwapInterval    = 222,   /* set/get int                     */
    kGLDParam292             = 292,   /* set only -> selector 0x0C       */
    kGLDParamTextureResident = 294,   /* get only, in/out texture object */
    kGLDParam298             = 298,   /* set only, int[3]                */
    kGLDParamSurfaceVolatile = 306,   /* set/get bool -> selector 0x10   */
    kGLDParamPresent         = 510,   /* set only, triggers the swap path*/
    kGLDParam666             = 666,   /* set/get bool                    */
    kGLDParamBindTexture     = 668,   /* set only: {unit<=5, GL target}  */
    kGLDParamBindVertexArray = 669,   /* set only                        */
    kGLDParamSurfaceFormat   = 995,   /* get only, in/out int[4]         */
    kGLDParam8086            = 8086   /* set only, int[2]                */
};


/* ===================================================================== */
/* 14.  Kernel user-client protocol  [ALL CONFIRMED]                     */
/* ===================================================================== */
/*
 * User-client types: 1 (per-context, opened by gldCreateContext and
 * gldGetRendererInfo) and 0 (per-device, opened by gldAttachDrawable for
 * drawable type 0x36).  No other type is used.
 *
 * IOConnectMapMemory, all with intoTask = mach_task_self_:
 *   type 0 -> ctx->0x194, options 0x101 (kIOMapAnywhere|kIOMapInhibitCache)
 *             UNCACHED MMIO / scratch aperture
 *   type 1 -> ctx->0x154 (base), ctx->0x158 (size), options 1
 *             COMMAND (DMA) BUFFER
 *   type 2 -> ctx->0x164 / ctx->0x168, options 1
 *   type 4 -> ctx->0x174 / ctx->0x178, options 1
 *             FENCE SLOT ARRAY, 8 bytes/slot, bitmap at ctx->0x17c
 *
 * THE COMPLETION COUNTER.  Leaf helper at 0x1a2fc:
 *     lwz   r2,0x194(r3)        ; ctx->uncached_map
 *     li    r9,0x15e0
 *     lwbrx r2,r2,r9            ; BYTE-REVERSED load: the GPU writes LE
 *     subf. r0,r2,r4
 *     cror  3,2,0               ; SO := EQ | LT
 *     mfcr  r3 ; rlwinm r3,r3,4,31,31
 * i.e.  fence_passed(ctx, seq) == (int32_t)(seq - LE32(map0[0x15E0])) <= 0
 * map0 + 0x15E0 is Radeon SCRATCH_REG0.  Wrapping signed comparison.
 * EVERY fence/idle test in the plugin funnels through this one function.
 *
 * COMMAND BUFFER (inside the type-1 mapping):
 *   base+0x10  capacity in dwords
 *   base+0x1c  first packet header dword
 *   base+0x20  first payload dword
 *   ctx->0x148 current packet header ptr (back-patched: *hdr |= (wp-hdr)>>2)
 *   ctx->0x14c write pointer
 *   ctx->0x150 limit = base + 0x20 + capacity*4 - 0x3C
 *   ctx->0x198 map generation, ++ on every remap
 * Command dwords are written with plain big-endian `stw`, while the scratch
 * register is read with `lwbrx`.  The asymmetry is deliberate.
 *
 * SELECTORS (via io_connect_method_* on ctx->0x04):
 *   0x00 scalarI    4 scalars {surfaceID, ctx->0x3c & 0xFFFF3FC0,
 *                              flags>>8 & 0xff, flags & 0xff}  attach/submit
 *   0x01 scalarI    4 scalars   swap rectangle (params 200/201)
 *   0x02 scalarI    2 scalars {swapInterval, param203}  present/swap
 *   0x03 scalarI/O  0 in, 3 out   capability words -> ctx->0x24/0x28/0x2c
 *   0x04 scalarI/O  0 in, 4 out
 *   0x05 scalarI/O  0 in, 4 out
 *   0x06 scalarI/O  1 in (drawable->0x08), 3 out   surface geometry/format
 *   0x07 scalarI/O  2 in, 1 out   (also a 0x1C-byte structureI_structureO form)
 *   0x08 scalarI    none          BLOCK UNTIL IDLE; retried while it returns
 *                                 0xE00002D6 == kIOReturnTimeout
 *   0x09 scalarI    1 scalar      BLOCK UNTIL FENCE REACHED
 *   0x0A structI/O  0x14-byte struct {type,p1,p2,p3,p4} in,
 *                   8 bytes {addr, memObj} out      ALLOCATE MEMORY OBJECT
 *   0x0B scalarI    1 scalar (memObj->0x00)         FREE MEMORY OBJECT
 *   0x0C scalarI    1 scalar      (param 292)
 *   0x0D scalarI    2 scalars {memObj->0x00, 1} or {memObj->0x00,
 *                   (face<<16)|level}               page-off / sync level
 *   0x0E scalarI    3 scalars from ctx->0xd0..0xd8  (param 298)
 *   0x0F scalarI    1 scalar      bind texture / vertex array (params 668/669)
 *   0x10 scalarI    1 scalar      surface volatile (param 306)
 *   0x11 scalarI    none          gldReclaimContext
 *   0x13 scalarI    2 scalars     (param 8086)
 * Selector 0x12 is never used by this plugin.
 */

#ifdef __cplusplus
}
#endif
#endif /* GLD_ABI_H */
