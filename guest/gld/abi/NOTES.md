# Apple "GLD" (OpenGL Driver plugin) ABI — Mac OS X 10.4 / PowerPC

Reverse-engineered from `/tmp/ATIRadeon8500GLDriver`
(Mach-O **bundle**, cputype PPC, `MH_BUNDLE | NOUNDEFS | DYLDLINK | TWOLEVEL`,
2 480 248 bytes, linked **2007-10-04** against libGLImage 1.0, CoreFoundation
368.31, IOKit 275.0, libSystem 88.1.10 — i.e. the 10.4.11 build).

Everything below is marked **CONFIRMED** (I can point at instruction addresses)
or **INFERRED** (plausible, but not proven). Where I could not decide, it says so.

Tooling used: `nm`/`otool -l` on the arm64 Mac; PowerPC disassembly via
`/opt/ppc/bin/powerpc-apple-darwin9-otool -tV` inside the `ppcbuild` Lima VM
(Xcode's `llvm-objdump` has **no** PowerPC backend on macOS 26 — it errors with
"unable to get target for 'powerpc-apple-darwin'", and `otool-classic` refuses
the file with "symbol table extends beyond the end of the file"; the file is in
fact complete, `stroff + strsize == filesize`).

Working files in this directory:

| file | contents |
|---|---|
| `full.asm` | complete `otool -tV` disassembly (611 696 lines) |
| `full_ann.asm` | same, with `; -> _symbol` appended to every resolved `bl` |
| `stubs.txt` | `__picsymbolstub1` address → imported C function |
| `nlptr_named.txt` | all 1074 `__nl_symbol_ptr` slots with values / names |
| `gli_fields.txt` | `GLIFunctionDispatch` field list w/ offsets, from the 10.4u SDK |
| `fn.sh` | `./fn.sh <8-hex-addr> [lines]` — dump a function |
| `gld_abi.h` | the recovered header |

ABI: 32-bit PowerPC Darwin. Integer/pointer args `r3..r10`, floats `f1..f13`,
return in `r3`/`f1`, 9th+ argument at `24(r1)` in the caller's frame.

---

## 0. Executive summary

* The plugin is a **bundle of 63 exported `gld*` C functions**. There is **no**
  constructor, no `__mod_init_func`, no exported table of function pointers, and
  no registration call. OpenGL.framework therefore resolves the entry points **by
  name** (`NSLookupSymbolInModule` / `dlsym`) — see §3.
* `gldCreateContext` opens **user-client type 1** on the accelerator's
  `io_service_t`, then `IOConnectMapMemory`s **four** memory types (0, 1, 2, 4).
  Memory type **0** is the uncached MMIO/scratch aperture; the GPU's completion
  counter lives at **byte offset 0x15E0** of it and is read **byte-reversed**
  (`lwbrx`) — that is Radeon `SCRATCH_REG0`, which the GPU writes little-endian.
* Command submission is a **linked ring of fixed 0x800-byte DMA slots** plus a
  command buffer in memory-type-1, with a scratch-register fence. Details §4.
* Error returns are **CGLError** values (`0x2710 + n`), not `GLenum`.
* **26 of the 63 symbol names still exist verbatim in macOS 26** (in
  `GLRendererFloat.bundle` / `GLEngine.bundle` inside the dyld shared cache).
  The GLD ABI is the same lineage, 20 years on. See §3.3.

---

## 1. Full exported symbol list, grouped

`nm -g` reports 127 symbols: **63 defined** (`T`, all `gld*`) and 64 undefined.
There are **no** exported data symbols. Addresses are `__TEXT` VM addresses.

### Library lifecycle
```
0x006e30 gldInitializeLibrary        0x006eb8 gldTerminateLibrary
0x230f14 gldGetVersion               0x230f68 gldGetString
0x005c74 gldGetError
0x003c88 gldSetInteger               0x0040cc gldGetInteger
```

### Pixel format / renderer enumeration
```
0x00639c gldChoosePixelFormat        0x006c3c gldDestroyPixelFormat
0x006c70 gldGetRendererInfo
```

### Context lifecycle
```
0x004c40 gldCreateContext            0x00541c gldDestroyContext
0x0055b8 gldReclaimContext
0x0054f0 gldCreateShared             0x00556c gldDestroyShared
0x0056bc gldAttachDrawable
0x021608 gldInitDispatch             0x021780 gldUpdateDispatch
```

### Drawable / framebuffer
```
0x006104 gldCreateFramebuffer        0x00610c gldReclaimFramebuffer
0x006110 gldDestroyFramebuffer
```

### Texture
```
0x0071f0 gldCreateTexture            0x00717c gldDeleteTexture
0x0072d4 gldCreateTextureLevel       0x006f00 gldDeleteTextureLevel
0x007320 gldModifyTexture            0x007334 gldModifyTextureLevel
0x0073ec gldGetTextureLevelInfo      0x22c96c gldGetTextureLevel
0x006ff4 gldReclaimTexture           0x006ef0 gldIsTextureResident
```

### Buffer objects + "memory plugin data" (the VRAM-allocation handle)
```
0x004310 gldCreateBuffer             0x0045a0 gldDestroyBuffer
0x004508 gldFlushBuffer              0x0045d8 gldReclaimBuffer
0x01d6e8 gldPageoffBuffer
0x004930 gldGetMemoryPluginData      0x00496c gldSetMemoryPluginData
0x0049c4 gldFinishMemoryPluginData   0x004a98 gldTestMemoryPluginData
0x004b30 gldDestroyMemoryPluginData
```

### Vertex arrays + vertex-buffer ring
```
0x0095e8 gldCreateVertexArray        0x009824 gldDestroyVertexArray
0x00963c gldModifyVertexArray        0x009758 gldReclaimVertexArray
0x009720 gldFlushVertexArray
0x01a6e8 gldAllocVertexBuffer        0x01aac0 gldFreeVertexBuffer
0x01aad4 gldCompleteVertexBuffer
```

### Fence / sync / flush
```
0x005e04 gldCreateFence              0x005fdc gldDestroyFence
0x006018 gldTestObject               0x00608c gldFinishObject
0x0190ec gldFinish                   0x019704 gldFlush
```

### Occlusion query
```
0x0080b4 gldCreateQuery              0x008124 gldDestroyQuery
0x018e38 gldGetQueryInfo
```

### Pipeline program (ARB vertex/fragment program)
```
0x0075e0 gldCreatePipelineProgram    0x0076dc gldDestroyPipelineProgram
0x007634 gldModifyPipelineProgram    0x007664 gldRelatePipelineProgram
0x0076b8 gldGetPipelineProgramInfo
```

### Imports (all 64), for reference
`IOServiceOpen, IOServiceClose, IOConnectAddClient, IOConnectMapMemory,
io_connect_method_scalarI_scalarO, io_connect_method_scalarI_structureI,
io_connect_method_structureI_structureO`, the CoreFoundation
`CFNotificationCenter*`/`CFDictionary*`/`CFNumber*` set, `glgConvertType /
glgPixelCenters / glgProcessPixels` (from libGLImage), `__cpu_capabilities`,
`mach_task_self_`, pthread mutex calls, libc (malloc/valloc/vfree/popen/…).

**Note the absence of `IOServiceGetMatchingServices` / `IOIteratorNext` / a
master-port lookup.** The `io_service_t` handles come from a global table that
`gldInitializeLibrary` is handed by the framework — the plugin never enumerates
IOKit itself.

---

## 2. Recovered signatures

### 2.1 Return convention — CONFIRMED

Almost every `gld*` entry point returns a **CGLError** (`long`), 0 on success.
Literals observed in the binary, decoded against `CGLTypes.h`:

| value | CGLError |
|---|---|
| `0x2710` (10000) | `kCGLBadAttribute` |
| `0x2712` (10002) | `kCGLBadPixelFormat` |
| `0x2714` (10004) | `kCGLBadContext` |
| `0x2715` (10005) | `kCGLBadDrawable` |
| `0x2716` (10006) | `kCGLBadDisplay` |
| `0x2717` (10007) | `kCGLBadState` |
| `0x2718` (10008) | `kCGLBadValue` |
| `0x2719` (10009) | `kCGLBadMatch` |
| `0x271a` (10010) | `kCGLBadEnumeration` |
| `0x271e` (10014) | `kCGLBadAddress` (the NULL-out-pointer error) |
| `0x271f` (10015) | `kCGLBadCodeModule` (used for "kernel setup failed") |
| `0x2720` (10016) | `kCGLBadAlloc` |
| `0x2722` (10018) | `kCGLBadConnection` |

A minority return `void` (no `li r3,…` on any return path) or a `GLboolean`.
Marked per function in `gld_abi.h`.

### 2.2 `gldCreateContext` @0x4c40 — 7 arguments, CONFIRMED

```c
CGLError gldCreateContext(void **ctxOut,          /* r3 */
                          const gld_pixelformat_t *pf,  /* r4 */
                          gld_shared_t *shared,    /* r5 */
                          void *shareCtx,          /* r6, may be NULL */
                          void *engineA,           /* r7 */
                          void *engineState,       /* r8 */
                          void **objectTable);     /* r9 */
```

Evidence: the prologue at `0x4c5c–0x4c70` moves **r3…r9** into callee-saved
registers (`r26,r28,r25,r27,r24,r23,r22`); **r10 is never touched**, and no load
from `24(r1)+` exists — so exactly **7** integer/pointer arguments.

* `r3` — out pointer. `*r3 = 0` at `0x4c84`; NULL → `kCGLBadAddress` (`0x4c74`).
* `r4` — pixel format. Read-only. Fields used: `+0x08`, `+0x0c`, `+0x10`
  (colour-bit mask), `+0x14`, `+0x18`, `+0x1c`, `+0x22` (`lha`, 1 or 2),
  `+0x24` (`lha`, >0), `+0x30` (display bitmask, checked against the global
  device mask at `0x4c9c–0x4cb8`, mismatch → `kCGLBadDisplay`).
* `r5` — stored at `ctx+0x0c`; **CONFIRMED to be a `pthread_mutex_t *`**: it is
  passed directly to `pthread_mutex_lock` at `0xafab8`, `0xb0174`, `0xb02a4`,
  `0x9654`, `0x218c8`. `gldCreateShared` allocates exactly such an object
  (`malloc(0x34)`, `pthread_mutex_init(obj, RECURSIVE)` at offset 0).
  ⇒ **arg2 is the `gldCreateShared` object.**
* `r6` — if non-NULL, `IOConnectAddClient(newConn, r6->0x04)` at `0x4d74`.
  `+0x04` of a gld context is its `io_connect_t`, so **r6 is another gld
  context** (the share context). *INFERRED* but strongly: only `+0x04` is read.
* `r7` → `ctx+0x14`; a struct with a `uint8` at `+0x26` (`0x4004`, `0x401c`) and
  a word at `+0x120` (`0xb0bd8`). Purpose **unknown**.
* `r8` → `ctx+0x10`; a **large** engine state record — `lhz r3,0x2db8(r27)` at
  `0x165a4` proves it is ≥ 0x2DBA bytes. Passed as arg1 to many internal
  state-setters. *INFERRED*: the GL engine's software state block.
* `r9` → `ctx+0x18`; an **array of object pointers** indexed
  `table[unit*5 + target]` (`mulli r0,r2,0x5` / `lwzx` at `0x3fbc–0x3fcc`), and
  slot 101 (`0x194/4`) read at `0x4058`. *INFERRED*: the engine's texture-unit
  binding table.

Context object: `malloc(0xfb8)` at `0x4c10`, so **`sizeof(gld_context_t) = 0xFB0`**
with an 8-byte intrusive list node at `ctx+0xFB0` (`{ctx, next}`) linked onto a
global head at `0x25A594` (`__bss`).

### 2.3 `gldDestroyContext` @0x541c — CONFIRMED
```c
CGLError gldDestroyContext(void *ctx);   /* NULL -> kCGLBadContext, else 0 */
```
Unbinds the drawable (`0x5620`), tears down (`0x22382c`), `IOServiceClose(ctx->4)`,
unlinks from the global list, `free(ctx->0xe4)` (software accumulation buffer),
`free(ctx->0x17c)` (the shadow map, §4), `free(ctx)`.

### 2.4 `gldReclaimContext` @0x55b8 — CONFIRMED
```c
void gldReclaimContext(void *ctx);
```
`0x223a00(ctx)`, then user-client **selector 0x11** with no arguments. If that
call *fails*, the context is `free()`d (tail call at `0x5608`). Returns nothing
meaningful.

### 2.5 `gldCreateShared` / `gldDestroyShared` — CONFIRMED
```c
CGLError gldCreateShared(void **sharedOut);   /* 1 arg */
CGLError gldDestroyShared(void *shared);      /* 1 arg */
```
`malloc(0x34)`; `pthread_mutex_init(obj+0, attr with PTHREAD_MUTEX_RECURSIVE)`;
`0xafa8c` sets `obj->0x2c = obj->0x30 = &obj->0x2c` (empty circular list).
Errors: `kCGLBadAddress` if `sharedOut == NULL`, `kCGLBadAlloc` if malloc fails,
`kCGLBadContext` if destroying NULL.
**`sizeof(gld_shared_t) = 0x34`, first member is a `pthread_mutex_t`.**

### 2.6 `gldAttachDrawable` @0x56bc — 4 arguments, CONFIRMED
```c
CGLError gldAttachDrawable(void *ctx,        /* r3 */
                           GLint  type,      /* r4 */
                           void  *drawable,  /* r5 */
                           GLuint flags);    /* r6 */
```
`r7` is never read. Drawable-type constants compared against: **0x50**, **0x5A**
(`0x56f0`, `0x5700`), **0x36** (`0x58cc`), **0x35** (`0x5a14`) and **0** with a
NULL drawable (detach, `0x5a20`); anything else → `kCGLBadEnumeration`.
`flags` is split into two bytes: `ctx->0x98 = (flags >> 8) & 0xFF`,
`ctx->0x9c = flags & 0xFF` (`0x56f4/0x56f8`, stored at `0x5be4`).

The drawable struct is read at `+0x00`, `+0x04` and `+0x08`; **`+0x08` is the
surface/window ID** passed to the kernel (see §4). `ctx->0x94` holds the
attached drawable pointer.

Type **0x36** takes a second path that opens **user-client type 0** on the same
device (`IOServiceOpen` at `0x5948`, `li r5,0x0`) and caches the connection in
the global device table — *INFERRED*: full-screen / offscreen surfaces.

### 2.7 `gldGetVersion` @0x230f14 — CONFIRMED
```c
GLboolean gldGetVersion(GLint *a, GLint *b, GLint *c, GLint *d);
```
4 pointer args, all written: `*a = 2`, `*b = 4`, `*c = 11`, `*d = 0x1600`.
Returns 0 if a global initialisation word is still zero, else 1.
Meaning of the four values **unknown**; `2,4,11` reads like "10.**4**.**11**".

### 2.8 `gldGetString` @0x230f68 — CONFIRMED
```c
const char *gldGetString(void *ctx, GLenum name);
```
`name - 0x1F00` must be in `[0,4]` (`GL_VENDOR … GL_EXTENSIONS` plus one more),
else returns NULL. The `GL_RENDERER` case selects one of three strings from
`ctx->0x24 & 0x00400000 / 0x00200000` — i.e. from the three capability words the
kernel returned via selector 3 (§4).

### 2.8b Library init / teardown — CONFIRMED

```c
void gldInitializeLibrary(io_service_t *services,  /* r3 */
                          void *a2,                /* r4 */
                          uint32_t displayMask,    /* r5 */
                          void *a4,                /* r6 */
                          void *a5);               /* r7 */
void gldTerminateLibrary(void);
```
`r3..r7` are read (`0x6e58–0x6eac`), `r8` is not; no return value is set.
It fills the single module global `G` at `0x25E5A0` (`__common`, reached through
the non-lazy pointer at `0x2594D4`):
`G[0x00]=displayMask`, `G[0x08]=r3`, `G[0x0c]=r4`, `G[0x10]=r6`, `G[0x14]=r7`;
zeroes `G[0x18 + 4i]` and byte `G[0x98 + i]` for i in 0..31; sets
`G[0x04] = (index of highest set bit in displayMask) + 1` = display count.
`G[0x08]` is later dereferenced as an **array of `io_service_t`, one per
display** — which is why the plugin never calls
`IOServiceGetMatchingServices`. `gldTerminateLibrary` zeroes `G[0x00..0x14]`
and reads no arguments.

### 2.8c Pixel format / renderer info — CONFIRMED

```c
CGLError gldChoosePixelFormat(gld_pixelformat_t **outList, const int *attribs);
CGLError gldDestroyPixelFormat(gld_pixelformat_t *pf);
CGLError gldGetRendererInfo(void *outRendererInfo /*>=0x38 bytes*/, uint32_t displayMask);
```
* `gldChoosePixelFormat` — 2 args. NULL out → `kCGLBadAddress`.
  **`getenv("GL_REJECT_HW")`** (string at `0x256BC8`, checked at `0x6408`)
  non-NULL ⇒ return success with an **empty** list: the driver's global
  hardware-disable switch.
  `attribs` is a 0-terminated `int` array, **max 36 entries** (>36 →
  `kCGLBadAttribute`). Dispatch is a `bctr` jump table at base `0x6460`,
  valid attribute index 0..0x5A.
  Result is **one `malloc` of `count * 0x34`**, entries linked through field
  `+0x00`. **`sizeof(gld_pixelformat_t) = 0x34`.**

  Recognised attributes (values verified from the jump table; the names are the
  standard CGL/AGL enum, which matches exactly):
  `2` (consumed, ignored; negative ⇒ stop) · `3` level → `+0x20` ·
  `4` RGBA (ignored) · `5` double buffer → `+0x0c |= 8` ·
  `6` stereo → `+0x0c |= 2` · `7` aux buffers → `+0x22` ·
  `8` colour size · `11` alpha size · `12` depth size · `13` stencil size ·
  `14` accum size · `20/21/22` R/G/B size · `23/24/25/26` accum R/G/B/A ·
  `51` minimum policy · `52` maximum policy · `53` offscreen → `+0x08 |= 4` ·
  `54` fullscreen → `|= 2` · `55` sample buffers → `+0x24` · `56` samples →
  `+0x26` · `57` aux depth/stencil → `|= 0x800` · `58` colour float ·
  `59` multisample → `+0x28 = 2` · `60` supersample → `+0x28 = 1` ·
  `61` sample alpha → `+0x2c` · `76` backing store → `|= 8` ·
  `80` window → `|= 1` · `84` display mask → `+0x30 &=`.
  Everything else ≤ 0x5A, and anything > 0x5A, returns `kCGLBadAttribute`.

  `gld_pixelformat_t` (0x34 bytes): `+0x00` next · `+0x04` renderer ID
  (`(displayIndex<<24) | 0x1600 | chipRev`) · `+0x08` buffer-mode flags
  (default 0x510) · `+0x0c` flags B · `+0x10` colour-mode mask (default
  `0x3ffffffc`) · `+0x14` accum-mode mask (`0xbffffffc`) · `+0x18` depth mask
  (`0x1ffff`) · `+0x1c` stencil mask · `+0x20` u16 level · `+0x22` u16 aux ·
  `+0x24` u16 sample buffers · `+0x26` u16 samples · `+0x28` multisample mode ·
  `+0x2c` u8 sample alpha · `+0x30` display mask.

* `gldGetRendererInfo` — 2 args. Rejects a `displayMask` that is not a non-empty
  subset of `G[0x00]` with `kCGLBadMatch`. Opens **user-client type 1**
  (`li r5,0x1` at `0x6d24`, `IOServiceOpen` at `0x6d34`), issues
  **selector 3 with 0 scalars in and 3 scalars out** (`0x6d64`), fills a record
  that mirrors the pixel-format layout, and closes the connection.
  Notable constants written: `+0x04` renderer ID · `+0x08` `0xB513`/`0xF513` ·
  `+0x10` `0x00008400` colour modes · `+0x14` `0x00808000` accum modes ·
  `+0x18` `0x1c01` depth modes · `+0x1c` `0x81` stencil modes ·
  `+0x30`/`+0x34` = kernel scalars out[2]/out[1] (*INFERRED*: VRAM and texture
  memory sizes). Kernel scalar out[0] is loaded and never used.

### 2.8d Fence / sync / query / error — CONFIRMED

```c
CGLError gldCreateFence (void *ctx, gld_fence_t **outFence);
CGLError gldDestroyFence(void *ctx, gld_fence_t *f);
int      gldTestObject  (void *ctx, int objectType, void *obj);   /* boolean */
CGLError gldFinishObject(void *ctx, int objectType, void *obj);
void     gldFinish(void *ctx);   /* r3 is the final kern_return_t */
void     gldFlush (void *ctx);   /* r3 meaningless; all internal callers ignore it */
CGLError gldCreateQuery (void *ctx, gld_query_t **outQuery);
CGLError gldDestroyQuery(void *ctx, gld_query_t *q);
CGLError gldGetQueryInfo(void *ctx, gld_query_t *q, GLenum pname, uint32_t *out);
CGLError gldGetError(void *ctx);   /* r = ctx->0x110; ctx->0x110 = 0; return r; */
```

**Fences live in the memory-type-4 mapping.** It is an array of 8-byte slots
`struct { uint32_t stamp; uint32_t pending; }` indexed `base + (id << 3)`;
`ctx->0x17c` is the slot-allocation bitmap (grow path at `0x5c88` re-maps type 4
and `realloc`s the bitmap). `gld_fence_t` = `malloc(8)` =
`{ uint32_t slotId; uint8_t done; }`. A freshly created fence is already
complete (`f->done = 1`, `slot->pending = 0`). Arming happens in `0x18f0c`
(not exported — reached through the dispatch table): it emits ring packet
`0x34000000` + slot id, then clears `f->done` and sets `slot->pending`.

`gldTestObject` / `gldFinishObject` `objectType`: **0 = fence, 1 = texture,
2 = vertex array, 3 = buffer**. `gldTestObject` returns **1** for an unknown
type; `gldFinishObject` returns `kCGLBadEnumeration`.

`gldGetQueryInfo` `pname`: `GL_QUERY_RESULT_ARB (0x8866)` spins up to 10 000
times with `usleep(100)` between kicks; `GL_QUERY_RESULT_AVAILABLE_ARB (0x8867)`
flushes once and reports availability. `0xFFFFFFFF` in the result slot is the
"not yet written" sentinel. Any other pname writes nothing and still returns 0.

### 2.8e Framebuffer — CONFIRMED to be stubs

```
0x6104 gldCreateFramebuffer  : li r3,0 ; blr
0x610c gldReclaimFramebuffer : blr
0x6110 gldDestroyFramebuffer : li r3,0 ; blr
```
No argument register is read, so the **arity is unknowable from this binary**.
EXT_framebuffer_object is simply not implemented by this driver.

### 2.8f `gldSetInteger` / `gldGetInteger` — the parameter namespace, CONFIRMED

```c
CGLError gldSetInteger(void *ctx, int param, const int *value);
CGLError gldGetInteger(void *ctx, int param, int *params);
```
3 args each; NULL value → `kCGLBadAddress`, unknown param → `kCGLBadEnumeration`.
This is effectively the driver's private `CGLSetParameter` surface:

| param | set behaviour | kernel call |
|---|---|---|
| 200 `0xc8` | `ctx->0xc0..0xcc = value[0..3]` (swap rectangle) | sel **1**, 4 scalars, only if `ctx->0xe0` |
| 201 `0xc9` | `ctx->0xe0 = !!value[0]` (swap rect enable) | sel **1**, 4 scalars or 4 zeroes |
| 203 `0xcb` | `ctx->0xe2 = value[0]` | sel **2**, `{ctx->0xde, value[0]}` |
| 222 `0xde` | `ctx->0xde = value[0]` (swap interval) | sel **2**, `{value[0], ctx->0xe2}` |
| 292 `0x124` | — | sel **0x0c**, 1 scalar |
| 294 `0x126` | *get only*, in/out: `params[0]` is a texture object; returns `tex->0x34->0x04` | — |
| 298 `0x12a` | `ctx->0xe1 = 1; ctx->0xd0/0xd4/0xd8 = value[0..2]` | — (consumed later by selector 0x0E in `gldAttachDrawable`) |
| 306 `0x132` | `ctx->0xe3 = !!value[0]` (surface volatile) | sel **0x10**, 1 scalar |
| 510 `0x1fe` | present/swap path `0x18a78(ctx, value[0], 1)` | — |
| 666 `0x29a` | `ctx->0x21 = !!value[0]` | — |
| 668 `0x29c` | bind texture: `value[0]` = unit (≤5), `value[1]` = GL target mapped `GL_TEXTURE_CUBE_MAP(0x8513)→0, GL_TEXTURE_3D(0x806F)→1, GL_TEXTURE_RECTANGLE(0x84F5)→2, GL_TEXTURE_2D(0xDE1)→3, GL_TEXTURE_1D(0xDE0)→4`; indexes `ctx->0x18[unit*5 + code]` | sel **0x0f**, 1 scalar |
| 669 `0x29d` | current vertex array's buffer, `ctx->0x18->0x194->0x1a8` | sel **0x0f**, 1 scalar |
| 995 `0x3e3` | *get only*, in/out: selector **6** with 1 scalar in / 3 out; `out[0] & 0xF` (3..13) selects a `(format, type)` pair, e.g. 4 → `GL_RGBA / GL_UNSIGNED_INT_8_8_8_8_REV`, 6-9 → `GL_YCBCR_422_APPLE / GL_UNSIGNED_SHORT_8_8_REV_APPLE`, 13 → `GL_RGBA / GL_FLOAT` | sel **6** |
| 8086 `0x1f96` | `ctx->0x3c` bit 0x10 and `ctx->0x14[0x26]` | sel **0x13**, 2 scalars |

This confirms the meaning of `ctx->0x18` (arg6 of `gldCreateContext`): it is the
**GL state block whose first member is the `[unit*5 + target]` texture binding
table**, with the current vertex array at `+0x194` and its buffer at `+0x1a8`.

### 2.9 Texture group — from disassembly, CONFIRMED unless noted

```c
CGLError gldCreateTexture      (void *ctx /*unused*/, gld_texture_t **out, void *glTexRec);
CGLError gldCreateTextureLevel (void *ctx /*unused*/, gld_texture_t *tex,
                                uint32_t flags, uint32_t face, uint32_t level);
CGLError gldModifyTexture      (void *ctx /*unused*/, gld_texture_t *tex, uint32_t flags);
CGLError gldModifyTextureLevel (void *ctx, gld_texture_t *tex, uint32_t face, int32_t level);
CGLError gldDeleteTexture      (void *ctx, gld_texture_t *tex);
CGLError gldDeleteTextureLevel (void *ctx, gld_texture_t *tex, uint32_t face, int32_t level);
void     gldReclaimTexture     (void *ctx, gld_texture_t *tex);
GLboolean gldIsTextureResident (void *ctx /*unused*/, gld_texture_t *tex);
CGLError gldGetTextureLevelInfo(void *ctx, gld_texture_t *tex, uint32_t face,
                                uint32_t level, GLenum pname, GLint *params);
CGLError gldGetTextureLevel    (void *ctx, gld_texture_t *tex, uint32_t face,
                                uint32_t level, void *dstPixels);
```

* `level == -1` is the "all levels" sentinel in `gldModifyTextureLevel` /
  `gldDeleteTextureLevel` (`cmpwi r6,0xffff` sign-extended, `0x7334`, `0x6f00`).
* **Asymmetry, verified not assumed**: `gldCreateTextureLevel` has a `flags`
  argument in r5 so face/level are r6/r7; `gldModifyTextureLevel` and
  `gldDeleteTextureLevel` take face/level in r5/r6 with no flags.
* `gldModifyTextureLevel`'s r7 is never read — if the real prototype has a
  trailing argument it is invisible here. **Unresolved.**
* `gldIsTextureResident` body is literally
  `lwz r0,0x34(r4); addic r2,r0,-1; subfe r3,r2,r0; blr` — returns `tex->mem != NULL`.
* `gldReclaimTexture` sets no return register on any path → treat as `void`.

`gld_texture_t` = `calloc(1, 0x5C)`:
`+0x00` hw image-descriptor block · `+0x18/1c/20` allocation list ·
`+0x24..0x2F` six `uint16` per-face level bitmasks (6 faces × 15 levels) ·
`+0x30` GL-side texture record (arg3 of Create) · `+0x34` memory object
(NULL ⇒ non-resident) · `+0x38` `uint8` hw format index (0xFF = recompute) ·
`+0x39` `uint8` dirty flags.

`gldGetTextureLevelInfo` `pname` map (jump table `0x747c–0x7588`) →
offsets into a 0x28-byte descriptor built by `0x22c584`:
`GL_TEXTURE_INTERNAL_FORMAT(0x1003)`→+0x00, `RED/GREEN/BLUE/ALPHA_SIZE
(0x805C-F)`→+0x04/08/0c/10, `LUMINANCE/INTENSITY_SIZE(0x8060/1)`→+0x14/18,
`GL_TEXTURE_DEPTH_SIZE(0x884A)`→+0x1c, `COMPRESSED_IMAGE_SIZE(0x86A0)`→+0x20,
`GL_TEXTURE_COMPRESSED(0x86A1)`→+0x24 (byte).
Unknown pname leaves `*params` untouched and still returns 0.

### 2.10 Buffer / memory-plugin group — CONFIRMED

```c
CGLError gldCreateBuffer(void *ctx /*unused*/, gld_buffer_t **out,
                         void *opaque, uint32_t *engineFlags);
void     gldFlushBuffer (void *ctx, gld_buffer_t *b, void *addr, size_t len);
CGLError gldDestroyBuffer(void *ctx, gld_buffer_t *b);
void     gldReclaimBuffer(void *ctx, gld_buffer_t *b);
void     gldPageoffBuffer(void *ctx, gld_buffer_t *b);

void     gldGetMemoryPluginData    (void *ctx /*unused*/, gld_buffer_t *b, void **outD);
void     gldSetMemoryPluginData    (void *ctx /*unused*/, gld_buffer_t *b, void *D);
void     gldFinishMemoryPluginData (void *ctx, void *D);
int      gldTestMemoryPluginData   (void *ctx, void *D);   /* 1 = idle */
void     gldDestroyMemoryPluginData(void *ctx, void *D);
```

`gld_buffer_t` = `malloc(0x24)`:
`+0x00` opaque (arg2) · `+0x04` `uint32*` engine flag word · `+0x08`
memory-plugin handle `D = {mem_obj, reserved}` · `+0x10..0x20` the literal
5-dword input struct for kernel selector 0x0A `{type, p1, p2, p3, p4}`.

`Get`/`Set MemoryPluginData` **detach / re-attach** a GPU allocation between
buffer objects — `Get` does `*outD = b->8; b->8 = NULL`.

Memory object `M` (kernel-allocated, shared-mapped):
`+0x00` kernel handle (the scalar sent to selectors 0x0B / 0x0D) ·
`+0x08` / `+0x0c` fence sequence for type 6 / type 7 ·
`+0x10` packed refcount: **high 16 bits = refcount** (`lwarx/stwcx` ±0x10000),
low 16 = pending count · `+0x14` `uint8` in-use (written by user space) ·
`+0x16` `uint8` type, 6 or 7 · `+0x1c` `uint16` resident mask · `+0x28`
`uint16` requested mask.

### 2.11 Vertex arrays — CONFIRMED

```c
CGLError gldCreateVertexArray (void *ctx /*unused*/, gld_vertexarray_t **out, void *a, void *b);
CGLError gldModifyVertexArray (void *ctx, gld_vertexarray_t *va);
int      gldFlushVertexArray  (void *ctx, gld_vertexarray_t *va /*unused*/,
                               size_t len, void *addr, int doFlush);
void     gldReclaimVertexArray(void *ctx, gld_vertexarray_t *va);
CGLError gldDestroyVertexArray(void *ctx, gld_vertexarray_t *va);
```
`gld_vertexarray_t` = `calloc(1, 0x1C4)`; `+0x1a8` = memory object,
`+0x1b0` = current allocation type.
`gldModifyVertexArray` keeps the existing allocation only if the APPLE storage
hint (`va->0->0x312`, `GL_STORAGE_CACHED_APPLE 0x85BE`) still matches the
allocated type, else it drops it back to the kernel (selector 0x0B).
**Note the argument-order asymmetry, verified in the instruction stream:**
`gldFlushVertexArray` has address in r6 and length in r5;
`gldFlushBuffer` has address in r5 and length in r6. `va` (r4) is never read.

### 2.12 The vertex-buffer ring — CONFIRMED

```c
void *gldAllocVertexBuffer   (void *ctx, uint32_t kind, uint32_t *ioSize);
void  gldFreeVertexBuffer    (void *ctx /*unused*/, void *p);
void  gldCompleteVertexBuffer(void);   /* a single `blr` — pure no-op */
```
* `*ioSize` is the requested size **in**, the granted size **out**; it is always
  `0x800`, and a request > 0x800 returns NULL (`0x1a724`; note the compare is
  *signed*).
* `kind &= 0x7FFF`; jump table at `0x1a75c` maps **1→token 9, 2→10, 3→11**;
  kinds 0 and 4–6 return NULL.
* It is **not** an offset-based head/tail ring. It is a **circular singly-linked
  list of fixed 0x800-byte DMA slots**, at most **128** (`ctx->0x170 <= 0x7f`).
  `ctx->0x16c` = last slot handed out; `slot->0x10` = next; `slot->0x14` =
  "client released" flag (the *only* thing `gldFreeVertexBuffer` writes:
  `*(uint32*)((char*)p - 0x6c) = 1`, and `p = slot + 0x80`);
  `slot->0x1c` = the memory object carrying the fence; payload = `slot + 0x80`.
* Back-pressure: grow the ring first; only spin when it is full. The spin is a
  bare `lwbrx` poll of the scratch register bounded at 10^6 iterations
  (`0x1a874`), after which it proceeds anyway. **No `usleep` on this path** —
  the binary's only `usleep` is in `gldGetQueryInfo`.
* Two flagged anomalies: `slot->0x18` is stored as `ctx->0x198 - 1` but compared
  for equality against `ctx->0x198`, which (since `0x198` only increments from 0)
  can never hold — the remap-before-wait branch at `0x1a890` looks like **dead
  code**, possibly an off-by-one. Don't model it as live without more evidence.

### 2.13 Pipeline programs — CONFIRMED
```c
CGLError gldCreatePipelineProgram (void *ctx /*unused*/, gld_program_t **out, void *glProgRec);
CGLError gldModifyPipelineProgram (void *ctx /*unused*/, gld_program_t *pp, uint32_t flags);
CGLError gldRelatePipelineProgram (void *ctx /*unused*/, gld_program_t *container,
                                   gld_program_t *shader, int attach);
CGLError gldGetPipelineProgramInfo(void *ctx, gld_program_t *pp, GLenum pname, GLint *params);
CGLError gldDestroyPipelineProgram(void *ctx, gld_program_t *pp);
```
`gld_program_t` = `calloc(1, 0x2C)`; `+0x00` GL-side record
(`[+0x00]` = `GL_FRAGMENT_SHADER 0x8B30` / `GL_VERTEX_SHADER 0x8B31`),
`+0x04` attached vertex shader, `+0x08` attached fragment shader,
`+0x28` dirty flags.
`gldRelatePipelineProgram` dispatches on the *shader's* type and stores NULL when
`attach == 0` (detach). `gldGetPipelineProgramInfo` answers the five
`GL_PROGRAM_NATIVE_*_ARB` queries (`0x88A2/A6/AA/AE/B2`) for **vertex programs
only**, reading `ctx->0xf54 + 0x18 + {0x70,0x74,0x78,0x7c,0x80}`; every other
pname leaves `*params` untouched.
`gldModifyPipelineProgram`'s helper `0xb025c` is a single `blr` — a genuine no-op.

---

## 3. How the plugin is entered

### 3.1 No table, no constructor — CONFIRMED

* `otool -l` shows **9 load commands** and no `LC_ROUTINES`; `__DATA` has
  `__data`, `__dyld`, `__la_symbol_ptr`, `__nl_symbol_ptr`, `__bss`, `__common`
  and **no `__mod_init_func`/`__constructor`** section.
* `LC_DYSYMTAB` reports `nextdefsym = 63`, all of them `gld*` **functions**
  (`N_SECT|N_EXT` in `__text`). There is **no exported struct of function
  pointers** and no `gldGetProcs`-style symbol.

⇒ OpenGL.framework must look the entry points up **by name**. On 10.4 the
framework loads the bundle with `NSCreateObjectFileImageFromFile` /
`NSLinkModule` and resolves `_gld…` via `NSLookupSymbolInModule`
(the `MH_BUNDLE` filetype and the lack of any init routine are consistent with
this and inconsistent with a registration protocol). *INFERRED* — I did not have
a 10.4 `libGL.dylib` to disassemble; the negative evidence in the plugin is solid.

### 3.2 What is called first — CONFIRMED order constraints

1. **`gldGetVersion(&a,&b,&c,&d)`** — returns 0 until a global word is non-zero,
   i.e. until the library has been initialised. It is the cheapest probe and is
   the natural first call.
2. **`gldInitializeLibrary(services, a2, displayMask, a4, a5)`** @0x6e30 —
   **this is the real entry point**, and the framework hands the plugin the
   `io_service_t` array; the plugin never enumerates IOKit itself. It fills the
   device table at `0x25E5A0` (`__common`), which every other entry point
   indexes: `+0x00` display bitmask, `+0x04` device count,
   `+0x08` `io_service_t[]` (= arg1), `+0x14` a **framework-supplied callback
   function pointer** (= arg5, called via `bctrl` at `0x5820`),
   `+0x18` `io_connect_t[]`, `+0x98` a `uint8[]` per device.
3. `gldChoosePixelFormat` → `gldCreateShared` → `gldCreateContext` →
   `gldInitDispatch` → `gldAttachDrawable`.

### 3.3 The dispatch table — `gldInitDispatch` / `gldUpdateDispatch`

```c
void gldInitDispatch  (void *ctx, void *dispatchTable, uint32_t maskOut[6]);
void gldUpdateDispatch(void *ctx, void *dispatchTable, uint32_t mask[5]);
```
* `gldInitDispatch` copies `ctx->0xf4 … ctx->0x108` (6 words) into `maskOut[0..5]`
  (`0x21620–0x2164c`), stores the table pointer at **`ctx->0x1c`** (`0x21674`),
  writes 17 function pointers into the table, and tail-calls `gldUpdateDispatch`
  with a **different**, 5-word mask copied from a `__const` template at `0x257F60`.
* Measured table layout (base register `r26` = arg2, verified at `0x21a70` etc.):

  | slot | filled by | value(s) |
  |---|---|---|
  | `+0x00` | Init | `0x3bcc` — **`accum(ctx, GLenum op, GLfloat value)`**, CONFIRMED: it range-checks `op - 0x100 <= 4` (`GL_ACCUM…GL_ADD`) and is gated on `ctx->0xe4`, the software accumulation buffer that `gldDestroyContext` frees |
  | `+0x04…+0x14` | Init | `0x20820, 0x21c2ac, 0x18758, 0x1657c, 0x1294c` |
  | `+0x18…+0x3c` | **Update** | 10 slots swapped *wholesale* between **15 variant families** — the state-selected fast paths. Each family member is `f(ctx, a, b)` forwarding to a common helper with a per-slot constant |
  | `+0x40…+0x48` | never written | — |
  | `+0x4c…+0x54` | Init | `0xaf2c0, 0xb0ba4, 0xb0fa4` |
  | `+0x58` | Update | **`gldFinish`** (`0x190ec`) or internal `0x19280` |
  | `+0x5c` | Update | **`gldFlush`** (`0x19704`) or internal `0x1986c` |
  | `+0x60` | Update | `0x1a11c` / `0x1986c` / `0x19cc4` |
  | `+0x64…+0x80` | Init | 8 more pointers |

* **This is *not* `GLIFunctionDispatch`.** The 10.4u SDK's
  `<OpenGL/gliDispatch.h>` has 686 fields and puts `finish`/`flush` at
  **`+0x164` / `+0x168`**, not `+0x58` / `+0x5c` (see `gli_fields.txt`). The
  first slot matching `accum` exactly is a real result, but the rest of the
  layout diverges immediately, so the table handed to `gldInitDispatch` is a
  **smaller GLD-private renderer dispatch (≥ 0x84 bytes, ~33 slots)**. I could
  not recover its field names; that needs the 10.4 `libGL.dylib`.

### 3.4 Continuity with modern macOS — CONFIRMED

The names are still alive. `dyld_info -exports` on
`/System/Library/Frameworks/OpenGL.framework/Versions/A/Resources/GLRendererFloat.bundle/GLRendererFloat`
(arm64e, macOS 26) lists a `gld*` export set, and **26 of the 63 10.4 names
match verbatim**:

```
gldAttachDrawable  gldCreateBuffer   gldCreateContext   gldCreateFence
gldCreateFramebuffer gldCreateTexture gldCreateVertexArray gldDestroyBuffer
gldDestroyContext  gldDestroyFence   gldDestroyFramebuffer gldDestroyVertexArray
gldFinishObject    gldFlushVertexArray gldGetError      gldGetInteger
gldIsTextureResident gldModifyTexture gldModifyVertexArray gldReclaimBuffer
gldReclaimContext  gldReclaimFramebuffer gldReclaimTexture gldReclaimVertexArray
gldSetInteger      gldTestObject
```
`gldChoosePixelFormat`, `gldCreatePipelineProgram` and `gldCreateQuery` are also
still exported by that bundle (they just didn't appear in the linkedit string
slice I diffed against). Renamed relatives:
`gldCreateShared → gldCreateShareGroup`, `gldCreatePipelineProgram → gldCreateProgram`,
`gld*MemoryPluginData → gld*MemoryPlugin`, `gldFinish/gldFlush →
gldFinishContext/gldFlushContext`, plus a large OpenCL/compute extension
(`gldCreateComputeContext`, `gldCreateKernel`, `gldCreateQueue`, …).

I could **not** disassemble the modern implementation to cross-check argument
counts: `GLRendererFloat` exists only inside the dyld shared cache on this
machine (the on-disk bundle directory is empty) and no `dyld_shared_cache_util`
is installed. Doing that would be the single highest-value next step — the
arm64 AAPCS makes argument counting much easier, and the shapes have clearly
been stable for two decades.

---

## 4. The kext handshake

### 4.1 Opening the user client — CONFIRMED

In `gldCreateContext`:
```
0x4d54  IOServiceOpen(devTable->services[ctx->0x00],  /* io_service_t   */
                      mach_task_self_,
                      1,                               /* USER CLIENT TYPE 1 */
                      &ctx->0x04);                     /* io_connect_t   */
0x4d74  if (shareCtx) IOConnectAddClient(ctx->0x04, shareCtx->0x04);
```
In `gldAttachDrawable`, drawable type 0x36 only:
```
0x5948  IOServiceOpen(devTable->services[i], mach_task_self_,
                      0,                               /* USER CLIENT TYPE 0 */
                      &devTable->connects[i]);
```
`gldGetRendererInfo` @0x6c70 also opens a client (`0x6d34`) and closes it again
at `0x6d74`/`0x6e14`.

**Only two user-client types are used: 0 and 1.**

### 4.2 Shared-memory mappings — CONFIRMED

Four `IOConnectMapMemory` calls, all with `intoTask = mach_task_self_`:

| memoryType | `atAddress` | `ofSize` | options | meaning |
|---|---|---|---|---|
| **0** | `ctx+0x194` | (stack) | `0x101` = `kIOMapAnywhere \| kIOMapInhibitCache` | **uncached MMIO / scratch aperture** |
| **1** | `ctx+0x154` | `ctx+0x158` | `0x1` = `kIOMapAnywhere` | **command (DMA) buffer** |
| **2** | `ctx+0x164` | `ctx+0x168` | `0x1` | second shared region |
| **4** | `ctx+0x174` | `ctx+0x178` | `0x1` | **fence slot array** |

Right after the type-4 mapping the plugin does
`ctx->0x17c = malloc(ctx->0x178 >> 5); memset(ctx->0x17c, 0, ctx->0x178 >> 5)`
(`0x4e90–0x4eb8`). CONFIRMED by the allocator at `0x5d14`: `ctx->0x17c` is a
**bit map of used fence slots** (scan words, skip `0xFFFFFFFF`, first clear bit,
`id = word*32 + bit`), and the type-4 mapping itself is an array of 8-byte slots
`{ uint32_t stamp; uint32_t pending; }` at `base + (id << 3)`. `0x5c88` grows it
by re-issuing `IOConnectMapMemory` for type 4 and `realloc`ing the bitmap.
If any of the four maps fails: `IOServiceClose`, `free(ctx)`, return
`kCGLBadCodeModule` (0x271f).

### 4.3 The completion counter — CONFIRMED, and the single most useful finding

Leaf helper at **`0x1a2fc`**:
```
0001a2fc  lwz   r2,0x194(r3)     ; r2 = ctx->uncached_map        (memoryType 0)
0001a300  li    r9,0x15e0
0001a304  lwbrx r2,r2,r9         ; byte-reversed load  -> little-endian GPU word
0001a308  subf. r0,r2,r4         ; r4 - completed
0001a30c  cror  3,2,0            ; SO := EQ | LT
0001a310  mfcr  r3
0001a314  rlwinm r3,r3,4,31,31
0001a318  blr
```
i.e. `int gld_fence_passed(ctx, uint32_t seq) { return (int32_t)(seq - *(LE32*)(map0 + 0x15E0)) <= 0; }`

**`map0 + 0x15E0` is Radeon `SCRATCH_REG0`** — a monotonically increasing
sequence number the GPU writes little-endian. Wrapping signed comparison, so
sequence numbers may wrap. Every fence/idle test in the plugin goes through this
one function.

### 4.4 Command-buffer layout — CONFIRMED

Inside the memory-type-1 mapping (`ctx->0x154`, size `ctx->0x158`):

| address | meaning |
|---|---|
| `base + 0x10` | capacity in **dwords** |
| `base + 0x1c` | first packet-header dword |
| `base + 0x20` | first payload dword |

Corresponding context fields (set at `0x1a218–0x1a240`):
`ctx->0x148` = pointer to the current packet header (back-patched with the dword
count: `*hdr |= (wp - hdr) >> 2`, `0x1a1d8–0x1a1f4`) · `ctx->0x14c` = write
pointer · `ctx->0x150` = limit = `base + 0x20 + capacity*4 - 0x3C` ·
`ctx->0x198` = map generation, incremented on every remap.
On a remap the old header gets `0x00100000` written into it (`0x1a1f0/0x1a208`)
and `IOConnectMapMemory` is re-issued for the same context.
Command dwords are written with plain `stw` (big-endian), while the scratch
register is read with `lwbrx` — the asymmetry is deliberate.

### 4.5 Complete user-client selector inventory — CONFIRMED

Extracted from all 65 `io_connect_method_*` call sites (see `full_ann.asm`).

| sel | method | in | out | used by / meaning |
|---|---|---|---|---|
| **0** | `scalarI_structureI` | 4 scalars | — | attach/retarget surface: `{surfaceID, ctx->0x3c & 0xFFFF3FC0, (flags>>8)&0xff, flags&0xff}`. `gldAttachDrawable` `0x5868`, `0x5a04`, `0x5c38`; submit paths `0x18c40`, `0x1a2dc`, `0x21f3d8` |
| **1** | `scalarI_structureI` | 4 scalars | — | swap rectangle: `gldSetInteger` params 200/201 (`0x3d50`, `0x3dc8`) |
| **2** | `scalarI_structureI` | 2 scalars | — | present/swap: `{ctx->0xde, ctx->0xe2}` or `{0,0}` / `{1,1}`. `0x196a8`, `0x19c68`, `0x1a0c0` |
| **3** | `scalarI_scalarO` | — | 3 scalars | capability query → `ctx->0x24/0x28/0x2c`. `0x4da4`, `0x5a8c`, `0x6d64`, `0x230e8c`. These three words drive `gldGetString(GL_RENDERER)` |
| **4** | `scalarI_scalarO` | — | 4 scalars | `gldAttachDrawable` `0x5ad8` |
| **5** | `scalarI_scalarO` | — | 4 scalars | `gldAttachDrawable` `0x5a60` |
| **6** | `scalarI_scalarO` | 1 scalar (`drawable->0x08`) | 3 scalars | per-surface geometry/format query. `0x5768`, `0x41f4`, `0x22c31c` |
| **7** | `scalarI_scalarO` / `structureI_structureO` | 2 scalars / 0x1c bytes | | `0x59b0`, `0x21cbdc` |
| **8** | `scalarI_structureI` | — | — | **block until GPU idle**; retried while it returns `0xE00002D6` = `kIOReturnTimeout` (`0x19240–0x19268`, `0x19604`) |
| **9** | `scalarI_structureI` | 1 scalar (fence value) | — | **block until fence reached** |
| **0x0A** | `structureI_structureO` | **0x14-byte struct** `{type,p1,p2,p3,p4}` | 8 bytes `{addr, memObj}` | **allocate a memory object** — the core VRAM/GART allocator. 12 call sites |
| **0x0B** | `scalarI_structureI` | 1 scalar (`M->0x00`) | — | **free a memory object.** Most-used selector (17 sites) |
| **0x0C** | `scalarI_structureI` | 1 scalar | — | `gldSetInteger` param 292 (`0x3f14`); non-zero kr → `kCGLBadMatch` |
| **0x0D** | `scalarI_structureI` | 2 scalars `{M->0, 1}` / `{M->0,(face<<16)|level}` | — | page-off / sync a level. `gldPageoffBuffer` `0x1d750`, `0x22cb94` |
| **0x0E** | `scalarI_structureI` | 3 scalars from `ctx+0xd0..0xd8` | — | `gldAttachDrawable` `0x5898`, gated on `ctx->0xe1` |
| **0x0F** | `scalarI_structureI` | 1 scalar | — | bind texture / vertex array: `gldSetInteger` params 668 / 669 (`0x3f78`, `0x4090`) |
| **0x10** | `scalarI_structureI` | 1 scalar | — | surface volatile: `gldSetInteger` param 306 (`0x3ecc`); also `gldAttachDrawable` `0x58c4` |
| **0x11** | `scalarI_structureI` | — | — | `gldReclaimContext` `0x55e8` |
| **0x13** | `scalarI_structureI` | 2 scalars | — | `gldSetInteger` param 8086 (`0x4040`); non-zero kr → `kCGLBadPixelFormat` |


Selector **0x12** is never used by this plugin.

---

## 5. Context struct map (partial), `sizeof = 0xFB0`

```
+0x000  uint32   display / device index into the global device table
+0x004  io_connect_t                                (user-client type 1)
+0x008  uint8    dcache line size (0x20 / 0x40 / 0x80, from __cpu_capabilities)
+0x00c  pthread_mutex_t *  (the gldCreateShared object)      <- arg2
+0x010  void *   engine state record, >= 0x2DBA bytes        <- arg5
+0x014  void *   engine record (u8 @+0x26, u32 @+0x120)      <- arg4
+0x018  void **  GL object state block                       <- arg6
                 [0 .. n]      texture bindings, [unit*5 + target]
                 [+0x194]      current vertex array -> [+0x1a8] its buffer
+0x021  uint8    param 0x29a (666)
+0x01c  void *   dispatch table (set by gldInitDispatch)
+0x020  uint8    acceleration gate
+0x024  uint32[3] kernel capability words (selector 3)
+0x028      "     (also read as a VRAM budget)
+0x030..0x038  zeroed at create
+0x03c  uint32   mode/pixel-format bits (0x20 = drawable attached, …)
+0x094  void *   attached drawable
+0x098  uint32   (attachFlags >> 8) & 0xFF
+0x09c  uint32   attachFlags & 0xFF
+0x0b0  = 0x19 (25)     +0x0b4 = 0x32 (50)
+0x0c0..0x0cc  int[4]   swap rectangle          (param 200)
+0x0d0..0x0d8  3 scalars for selector 0x0E      (param 298)
+0x0dd  uint8    derived from pf->0x14
+0x0de  uint8    swap interval                  (param 222)
+0x0df  uint8    = 1
+0x0e0  uint8    swap-rect enable               (param 201)
+0x0e1  uint8    gate for selector 0x0E
+0x0e2  uint8    param 203
+0x0e3  uint8    surface volatile               (param 306)
+0x0e4  void *   software accumulation buffer (freed by gldDestroyContext)
+0x0ec  uint32   saved mode bits
+0x110  uint32   last error, read-and-cleared by gldGetError
+0x0f4..0x108  6 words copied out by gldInitDispatch
+0x124..0x138  6 bound-texture slots
+0x13c..0x140  2 bound-pipeline-program slots
+0x144  current vertex array
+0x148  current packet-header dword pointer
+0x14c  command-buffer write pointer
+0x150  command-buffer limit
+0x154  cmd-buffer base   +0x158 size      (IOConnectMapMemory type 1)
+0x164  base              +0x168 size      (type 2)
+0x16c  vertex-buffer ring head (last slot handed out)
+0x170  vertex-buffer ring node count (max 0x80)
+0x174  fence slot array  +0x178 size      (type 4)
+0x17c  void *   fence-slot allocation bitmap
+0x180  void *   occlusion-query result block  (realloc'd to ids*16 + 0x90)
+0x184  uint32   its byte size
+0x188  void *   query-id allocation bitmap
+0x18c  uint32   query-id capacity
+0x194  void *   uncached MMIO aperture   (type 0)  — SCRATCH_REG0 at +0x15E0
+0x198  uint32   command-buffer map generation
+0x19c  base of the big per-context hardware-state block (used as `ctx+0x19c`)
+0x5de  uint8    occlusion query active
+0xf54  program resource block
+0xfb0  { gld_context_t *self; void *next; }  intrusive global-list node
```

---

## 6. Open questions / what I could not determine

1. **The dispatch-table field names.** Slot 0 is `accum`; `+0x58`/`+0x5c` are
   `finish`/`flush`. The rest needs the 10.4 `libGL.dylib` or the real
   (non-SDK) GLD header.
2. **`gldCreateContext` args 4 and 5** (`r7` → `ctx+0x14`, `r8` → `ctx+0x10`):
   confirmed to exist and confirmed where they are stored, but their **types are
   unknown**. (Arg 6, `r9` → `ctx+0x18`, *is* identified: the GL object state
   block, see §2.8f.)
2b. **Framebuffer arity** — the three `gldCreate/Reclaim/DestroyFramebuffer`
   entry points are stubs that read no argument registers, so nothing about
   their signatures can be recovered from this binary.
3. **`gldGetVersion`'s four outputs** (2, 4, 11, 0x1600) — meaning unknown.
4. **`gldModifyTextureLevel`'s possible 5th argument** — `r7` is never read.
5. **The 15 dispatch variant families** at `+0x18…+0x3c`: I know the shape
   (`f(ctx, a, b)` → common helper with a per-slot constant) but not the
   semantics.
6. **Drawable types 0x35 / 0x36 / 0x50 / 0x5A** — only that 0x50 and 0x5A share
   a path and 0x36 opens user-client type 0. No names recovered.
7. **Hardware texel-format index 2 → `0x2A10`** is not a standard GL enum
   (vendor-private, unidentified).
8. Argument counts were derived from "highest `rN` read before written", which
   cannot see a **trailing argument the callee ignores**. Every prototype here
   is therefore a *lower bound* on the argument count.


## The GLD dispatch table, recovered 20 September 2026

`gldInitDispatch` is the entry point that could not be guessed at: it writes
function pointers into a table GLEngine then calls directly, so a wrong slot
means GLEngine calls the wrong function with the wrong arguments, and that
crashes rather than warns. It is now read out of Apple's driver rather than
inferred, by `dispatch-map.py`, which simulates the few PowerPC instructions
involved (the bcl PIC base, the addis/lwz pairs that form a data address,
and the stores to the table register).

**The table is 33 slots, 0x00 to 0x80, and every one is accounted for.**
Two functions fill it between them:

- `gldInitDispatch` writes 17: slots 0-5, 19-21, 25-32.
- `gldUpdateDispatch` writes 16: slots 6-18, 22-24. This is the
  state-dependent half -- it is called again when state changes, which is
  why the draw-path slots live here and the setup slots do not.

`dispatch-table.txt` holds the full map. Two slots are named outright in
the driver's own symbol table, and they anchor the rest:

    +0x58  [22]  _gldFinish
    +0x5c  [23]  _gldFlush

**Four slots are no-ops.** Slots 16, 17, 18 and 24 all point at 0x21604,
which is a single `blr`. Ours can be empty stubs, and that is four fewer
functions to get wrong.

> **This was wrong.** `0x21604` is one *variant* among several.
> `gldUpdateDispatch` rewrites those slots from different state paths --
> slots 16/17/18 also take real functions (`0xcea30`, `0x186a70`) at
> `0x2bd4c/0x2bd5c/0x2bd6c`, and slot 24 takes `0x1a11c`, `0x19cc4` or
> `0x1986c` depending on `ctx->0x19c+0x434` and flag bit `0x400`. Slot 24
> is in fact the buffer-swap entry, called from `_glSwap_Exec`.
>
> The error came from `dispatch-map.py` reporting a single value per slot:
> for the 16 slots `gldUpdateDispatch` writes, the target is
> state-dependent and needs a multi-path walk. Treating one path's answer
> as the answer is the mistake to avoid here.
>
> Slots 31 and 32 *are* genuine stubs (`li r3,0 ; blr`): this driver does
> not accelerate mipmap generation or `glBufferSubData`.
>
> See `dispatch-abi.md` for the recovered signatures.

`gldInitDispatch(ctx, table, out)` also does two things besides filling the
table, both recovered from the same disassembly:

- it copies six words from `ctx+0xf4 .. ctx+0x108` into `out+0x00 .. +0x14`,
  so the third argument is an output block, not an input;
- it stores the table pointer itself at `ctx+0x1c`.

**What is still unknown** is each slot's signature and meaning. The targets
resolve only to `nearest symbol + offset` because the driver is stripped, so
names will have to come from somewhere else: the call sites in GLEngine,
which load a slot and `bctrl` through it, and which sit next to code whose
purpose can be identified. That is the next piece of work, and slots 22 and
23 give it two fixed points to calibrate against.
