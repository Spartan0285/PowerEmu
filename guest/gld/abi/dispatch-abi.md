# The GLD dispatch table ABI

Recovered 20 September 2026 by static analysis of `GLEngine1011` (the
caller) and `ATIRadeon8500GLDriver` (a callee). Supersedes the slot map in
`dispatch-table.txt`, which records only one variant per slot.

## The discovery that made it possible

**`GLEngine1011` is not stripped** -- 3476 named `__text` symbols. The
driver is stripped, so working from the callee alone gives addresses and no
meaning; working from the caller gives names, call sites and argument
set-up. Everything below comes from GLEngine unless marked otherwise.

The table lives at a fixed offset inside GLEngine's own context:

| field | meaning | evidence |
|---|---|---|
| `engctx+0x4688` | the GLD context, arg1 of every slot | `GLEngine1011:0x3080` |
| `engctx+0x4698` | **the dispatch table**, arg2 of `gldInitDispatch` | `GLEngine1011:0x9f04` |
| `engctx+0x471c` | `gldInitDispatch`'s output block (6 words) | `GLEngine1011:0x9f08` |
| `engctx+0x4754` | 61-entry copy of the plugin's `gld*` pointers | `GLEngine1011:0x3088` |

`0x4698 + 0x84 == 0x471c`, so **the table is exactly 33 slots, bounded from
both ends** rather than merely counted from the writes. GLEngine's own
fallback path fills exactly `0x21` (33) words with `_gliDispatchNoop`
(`0x9f54`).

**Calibration passed.** Slot 22 resolves to `gldFinish` and slot 23 to
`gldFlush`, matching the two names in the driver's symbol table. Nothing
else in the binary reproduces that pairing, so the base offset is not a
coincidence. A method that failed this test would have been reported as
wrong rather than used.

## Why caller-side evidence is authoritative

The driver installs *different variants* of a slot depending on state
(`gldUpdateDispatch` rewrites 16 of them). GLEngine's call site does not
change. So a signature read from the caller holds for every variant, which
is why most rows below are CONFIRMED although only one variant of each
callee was disassembled.

## PowerPC detail that matters

GPR and FPR argument slots advance **in parallel**: a `float` argument
consumes an FPR *and* burns the matching GPR. Visible in slot 5, where r7
and r8 are deliberately never set because f1 and f2 occupy those positions,
and in slot 0, where r5 is skipped for f1. Getting this wrong shifts every
later argument.

## The table

`ctx` is the GLD context, in r3 for every slot.

| # | off | signature | purpose | conf |
|---|---|---|---|---|
| 0 | 0x00 | `(ctx, GLenum op, GLfloat value /*f1*/)` | glAccum | CONFIRMED |
| 1 | 0x04 | `(ctx, GLbitfield mask)` | glClear | CONFIRMED |
| 2 | 0x08 | `GLint (ctx, x, y, w, h, format, type, void *pixels, GLboolean, void *packBuf)` | glReadPixels | arity CONFIRMED |
| 3 | 0x0c | `GLboolean (ctx, const GLfloat raster[3], w, h, format, type, const void *pixels, GLuint, void *)` | glDrawPixels | arity CONFIRMED |
| 4 | 0x10 | `GLint (ctx, const GLfloat raster[3], x, y, w, h, GLenum type)` | glCopyPixels | CONFIRMED |
| 5 | 0x14 | `GLint (ctx, const GLfloat raster[3], w, h, xorig /*f1*/, yorig /*f2*/, const GLubyte *bitmap /*r9*/, GLuint /*r10*/)` | glBitmap | CONFIRMED |
| 6 | 0x18 | `(ctx, const void *verts, GLint count)` | render POINTS | CONFIRMED |
| 7 | 0x1c | `(ctx, const void *verts, GLint count)` | render LINES | CONFIRMED |
| 8 | 0x20 | `(ctx, verts, count, GLuint closeLoop)` | LINE_STRIP / LINE_LOOP | CONFIRMED |
| 9 | 0x24 | as slot 8 | LINE_LOOP, entry used when no primitive is open | INFERRED |
| 10 | 0x28 | `(ctx, verts, count, GLuint fillMode)` | POLYGON | CONFIRMED |
| 11 | 0x2c | `(ctx, verts, count, fillMode)` | TRIANGLES | CONFIRMED |
| 12 | 0x30 | `(ctx, const void *pivot, verts, count, fillMode)` | TRIANGLE_FAN | arity CONFIRMED |
| 13 | 0x34 | `(ctx, verts, count, fillMode)` | TRIANGLE_STRIP | CONFIRMED |
| 14 | 0x38 | `(ctx, verts, count, fillMode)` | QUADS | CONFIRMED |
| 15 | 0x3c | `(ctx, verts, count, fillMode)` | QUAD_STRIP | CONFIRMED |
| 16 | 0x40 | `(ctx, verts, count)` | POINTS, second family | CONFIRMED |
| 17 | 0x44 | `(ctx, verts, count, GLuint mode)` | LINES, second family | CONFIRMED |
| 18 | 0x48 | `(ctx, verts, count, fillMode)` | polygon-class, per-primitive loop | CONFIRMED |
| 19 | 0x4c | `(ctx, void *vaDesc, GLenum mode, GLuint, GLsizei count, GLenum indexType, const void *indices)` | glDrawElements | arity CONFIRMED |
| 20 | 0x50 | `(ctx, GLint primType, GLuint *inout)` | begin/flush a TCL primitive batch | CONFIRMED |
| 21 | 0x54 | `(ctx, GLuint, GLint, GLint)` | render / force-to-software a TCL primitive | arity CONFIRMED |
| 22 | 0x58 | `(ctx)` | **finish** (`_gldFinish`) | CONFIRMED |
| 23 | 0x5c | `(ctx)` | **flush** (`_gldFlush`) | CONFIRMED |
| 24 | 0x60 | `(ctx)` | **swap buffers / present** | CONFIRMED |
| 25 | 0x64 | `(ctx, gld_fence_t *)` | arm a fence (glSetFenceAPPLE) | CONFIRMED |
| 26 | 0x68 | `(ctx, gld_query_t *)` | glBeginQuery | CONFIRMED |
| 27 | 0x6c | `(ctx, gld_query_t *)` | glEndQuery | CONFIRMED |
| 28 | 0x70 | `(ctx, GLuint mode, …, void *vertexBuf /*r10*/, void *)` -- 9 args | vertex-array-range draw | arity CONFIRMED |
| 29 | 0x74 | `GLint (ctx, tex, face, level, xoff, yoff, zoff, x, y, w, h)` -- 11 args | glCopyTex(Sub)Image | arity CONFIRMED |
| 30 | 0x78 | `GLint (ctx, tex, face, level, x, y, z, w, h, d, format, type, pixels, GLubyte, void *unpackBuf)` -- 15 args | glTexSubImage, incl. compressed | arity CONFIRMED |
| 31 | 0x7c | `GLint (ctx, tex, GLuint)` | generate mipmaps -- **a stub in this driver** | CONFIRMED |
| 32 | 0x80 | `GLint (ctx, void *buf, GLintptr offset, GLsizeiptr size, const void *data)` | glBufferSubData -- **a stub in this driver** | arity CONFIRMED |

Selected call sites, for re-derivation: slot 0 `_glAccum_Exec:0x56c00`;
1 `_glClear_Exec:0x32054`; 2 `_glReadPixels_Exec:0x46074`;
4 `_glCopyPixels_Exec:0x55510`; 5 `_glBitmap_Exec:0x55144`;
11 `_gleVPRenderTriangles:0x104cc4`; 12 `_gleVPRenderTriangleFan:0x105450`;
19 `_gleExecuteTCLVertexArray:0xdad98`; 20 `_gleBeginPrimitiveTCLFunc:0x1d160`;
22 `_glFinish_Exec:0x5583c`; 23 `_glFlush_RevertExec:0x65e00`;
24 `_glSwap_Exec:0x435b4`; 25 `_gleSetFence:0x4fe38`;
26 `_glBeginQuery_Exec:0x78cfc`; 29 `_glCopyTexImage2D_Exec:0x53e94`;
30 `_glTexSubImage2D_Exec:0x1f274`; 32 `_glBufferSubData_Exec:0x58f64`.

Argument roles for slots 10-15 are pinned by the callee's own checks: the
count register is compared against the primitive's minimum (2 for triangles
at `0x198b44`, 3 for quads at `0x1e7630`) and the mode register against
`ctx->0x10c`. Slot 12 checks r6 and r7 instead of r5 and r6, which is what
proves its extra argument.

## Writing a plugin against this

- **Fill all 33 slots.** GLEngine calls every one; an unfilled slot is a
  call through uninitialised memory.
- **A safe stub is `li r3,0 ; blr`** -- return 0. That is exactly what
  GLEngine's own `_gliDispatchNoop` does (`0x3208c`), and every return value
  it inspects treats 0 as "not handled, fall back to software". So a
  partial implementation degrades instead of crashing.
- `fillMode` in slots 10-15 is `GL_POINT/GL_LINE/GL_FILL - 0x1B00`, i.e.
  0/1/2, with 3 used on one polygon path.
- Vertex stride is `engctx->0x487c`; on the vertex-program paths it is
  `0x100` (`addi r27,r27,0x300` for three vertices).
- Object handles reaching slots 25/26/27/29/30/32 are always
  `engineObject->0x10[rendererIndex]`, with `rendererIndex` at
  `*(uint8 *)(engctx+0x185a8)`.

## What is still unknown

Argument *roles* (not arity) for slots 2 (args 9-10), 3 (args 8-9), 19
(arg 4), 21 (args 2-4), 28 (args 2-7), 29/30 (the order of the
x/y/z/w/h/d group), and 32 (offset vs size order). Each is settled by
disassembling a second call site that passes different values -- the 1D/3D
variants of the texture entry points are the obvious lever, because the
slots they zero-fill differ.

Also unknown: what distinguishes the second render family (16/17/18) from
the first (6/7/10-15). Both are called for the same primitive types; slot
18 is called in a per-primitive loop with 0x300-byte strides while slot 11
takes the whole array at once.
