/*
 * Guest-side ring writer.  See pering.c.
 *
 * poweremu_gpu_ring.h is a copy of the host's protocol header: the two must
 * stay identical, so it is copied rather than edited here.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef PERING_H
#define PERING_H

#include <stdint.h>
#include <stdio.h>
#include "poweremu_gpu_ring.h"

/*
 * Render state as the renderer has it, in host byte order.  The host
 * rejects a draw that no state packet precedes, so a batch that draws must
 * open with pe_ring_state(); the target fields are the minimum it needs.
 */
typedef struct PEGpuStateHost {
    unsigned int target_offset, target_pitch;
    unsigned short target_width, target_height;
    unsigned int depth_offset, depth_pitch;
    unsigned short depth_bits;      /* 16, or 24/32 */
    unsigned short flags;           /* PE_GPU_ST_* */
    unsigned short blend_src, blend_dst;    /* PE_GPU_BLEND_* */
    short scissor_x, scissor_y, scissor_w, scissor_h;
} PEGpuStateHost;

/* Vertices as the renderer has them: host floats, not yet byte-ordered. */
typedef struct PEGpuVertexHost {
    float pos[4];
    float colour[4];
    float tex[4];
} PEGpuVertexHost;

typedef struct PERing {
    unsigned char *base;            /* the shared mapping, ring at 0 */
    unsigned int shared_bytes;
    unsigned int head;              /* bytes written this batch */
    unsigned int data_next;         /* bump allocator for vertices/texels */
    unsigned int fence_seq;

    void (*doorbell)(void *arg, unsigned int head);
    void *doorbell_arg;

    unsigned long packets, batches, draws;

    void *capture;                  /* FILE *, when capturing to a file */
} PERing;

void pe_ring_init(PERing *r, void *shared, unsigned int shared_bytes);
void *pe_ring_packet(PERing *r, unsigned int type, unsigned int bytes);
void *pe_ring_data(PERing *r, unsigned int bytes, unsigned int *offset_out);
void pe_ring_flush(PERing *r);
unsigned int pe_ring_fence(PERing *r);
void pe_ring_present(PERing *r, unsigned int offset, unsigned int pitch,
                     unsigned short w, unsigned short h);
int pe_ring_capture(PERing *r, const char *path);
void pe_ring_state(PERing *r, const PEGpuStateHost *st);
void pe_ring_fill(PERing *r, unsigned int dst_offset, unsigned int dst_pitch,
                  unsigned short x, unsigned short y,
                  unsigned short w, unsigned short h, unsigned int colour);
int pe_ring_draw(PERing *r, unsigned int prim, const PEGpuVertexHost *verts,
                 unsigned int count);

#endif /* PERING_H */
