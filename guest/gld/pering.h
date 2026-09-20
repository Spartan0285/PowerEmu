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
#include "poweremu_gpu_ring.h"

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
} PERing;

void pe_ring_init(PERing *r, void *shared, unsigned int shared_bytes);
void *pe_ring_packet(PERing *r, unsigned int type, unsigned int bytes);
void *pe_ring_data(PERing *r, unsigned int bytes, unsigned int *offset_out);
void pe_ring_flush(PERing *r);
unsigned int pe_ring_fence(PERing *r);
void pe_ring_present(PERing *r, unsigned int offset, unsigned int pitch,
                     unsigned short w, unsigned short h);
int pe_ring_draw(PERing *r, unsigned int prim, const PEGpuVertexHost *verts,
                 unsigned int count);

#endif /* PERING_H */
