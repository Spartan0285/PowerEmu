/*
 * Guest-side writer for the PowerEmu GPU command ring.
 *
 * The renderer plugin builds packets here and hands them to the host in one
 * go.  The point of the exercise is that this costs the guest almost
 * nothing: packets are written into ordinary shared memory, and only the
 * doorbell is a register the host sees.
 *
 * Two transports, because the interesting one is not available first:
 *
 *   MAPPED  the real thing -- the kext maps the device's BAR into this
 *           process and we write straight into it.
 *   SOCKET  bring-up only -- packets go to a unix socket the host reads.
 *           Slower and not what ships, but it lets the whole pipeline
 *           (GL call -> packet -> host -> Metal) be proven before any
 *           kernel code exists, which is worth more early than speed.
 *
 * This file is deliberately free of both OpenGL and IOKit so it can be
 * compiled and unit-tested on the development machine, where a mistake in
 * the ring arithmetic is a failed assertion rather than a hung guest.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "pering.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The guest is big-endian and so is the protocol, so these are identity
 * there.  They exist for the host-side unit test, which is not. */
#if defined(__BIG_ENDIAN__) || (defined(__BYTE_ORDER__) && \
    __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
#define PE_BE32(x) (x)
#define PE_BE16(x) (x)
#else
#define PE_BE32(x) __builtin_bswap32(x)
#define PE_BE16(x) __builtin_bswap16(x)
#endif

void pe_ring_init(PERing *r, void *shared, unsigned int shared_bytes)
{
    memset(r, 0, sizeof(*r));
    r->base = (unsigned char *)shared;
    r->shared_bytes = shared_bytes;
    r->head = 0;
    r->data_next = PE_GPU_DATA_BASE;
}

/*
 * Reserve space for one packet.  Returns NULL when the ring is full, which
 * the caller answers by ringing the doorbell and waiting -- never by
 * writing anyway.  Packets are 8-byte aligned so the host can walk them
 * without unaligned loads on a PowerPC guest.
 */
void *pe_ring_packet(PERing *r, unsigned int type, unsigned int bytes)
{
    unsigned char *p;
    unsigned int aligned = (bytes + 7u) & ~7u;
    PEGpuPacketHdr hdr;

    if (aligned < sizeof(PEGpuPacketHdr) || aligned > PE_GPU_RING_BYTES) {
        return NULL;
    }
    if (r->head + aligned > PE_GPU_RING_BYTES) {
        return NULL;                    /* caller must flush */
    }
    p = r->base + r->head;
    hdr.type = PE_BE16((unsigned short)type);
    hdr.flags = 0;
    hdr.bytes = PE_BE32(aligned);
    memcpy(p, &hdr, sizeof(hdr));
    memset(p + sizeof(hdr), 0, aligned - sizeof(hdr));
    r->head += aligned;
    r->packets++;
    return p;
}

/*
 * Carve vertices or texels out of the data area.  The host validates every
 * offset it is given, but getting it right here keeps the guest from
 * building batches the host will only reject.
 */
void *pe_ring_data(PERing *r, unsigned int bytes, unsigned int *offset_out)
{
    unsigned int off = (r->data_next + 255u) & ~255u;   /* texture-friendly */

    if (bytes > PE_GPU_DATA_BYTES ||
        off + bytes > PE_GPU_DATA_BASE + PE_GPU_DATA_BYTES) {
        return NULL;                    /* caller must flush */
    }
    r->data_next = off + bytes;
    *offset_out = off;
    return r->base + off;
}

/* Everything written so far becomes visible to the host at once. */
void pe_ring_flush(PERing *r)
{
    if (!r->head) {
        return;
    }
    if (r->doorbell) {
        r->doorbell(r->doorbell_arg, r->head);
    }
    r->batches++;
    r->head = 0;
    r->data_next = PE_GPU_DATA_BASE;
}

unsigned int pe_ring_fence(PERing *r)
{
    PEGpuFence *f = pe_ring_packet(r, PE_GPU_PKT_FENCE, sizeof(*f));

    if (!f) {
        return 0;
    }
    f->value = PE_BE32(++r->fence_seq);
    return r->fence_seq;
}

void pe_ring_present(PERing *r, unsigned int offset, unsigned int pitch,
                     unsigned short w, unsigned short h)
{
    PEGpuPresent *p = pe_ring_packet(r, PE_GPU_PKT_PRESENT, sizeof(*p));

    if (!p) {
        return;
    }
    p->offset = PE_BE32(offset);
    p->pitch = PE_BE32(pitch);
    p->width = PE_BE16(w);
    p->height = PE_BE16(h);
}

/*
 * The host keeps no state across batches it did not see set, and rejects a
 * draw that no state packet precedes.  Emitting this is therefore not
 * optional bookkeeping: it is what makes the draws that follow legal.
 */
void pe_ring_state(PERing *r, const PEGpuStateHost *st)
{
    PEGpuState *p = pe_ring_packet(r, PE_GPU_PKT_STATE, sizeof(*p));

    if (!p) {
        return;
    }
    p->target_offset = PE_BE32(st->target_offset);
    p->target_pitch = PE_BE32(st->target_pitch);
    p->target_width = PE_BE16(st->target_width);
    p->target_height = PE_BE16(st->target_height);
    p->depth_offset = PE_BE32(st->depth_offset);
    p->depth_pitch = PE_BE32(st->depth_pitch);
    p->depth_bits = PE_BE16(st->depth_bits);
    p->flags = PE_BE16(st->flags);
    p->blend = PE_BE32(st->blend_src | ((unsigned int)st->blend_dst << 16));
    p->scissor_x = PE_BE16((unsigned short)st->scissor_x);
    p->scissor_y = PE_BE16((unsigned short)st->scissor_y);
    p->scissor_w = PE_BE16((unsigned short)st->scissor_w);
    p->scissor_h = PE_BE16((unsigned short)st->scissor_h);
}

/*
 * A solid fill, which is a blit with no source.  Worth having separately
 * from anything the renderer needs: the host executes it into the shared
 * mapping with ordinary stores, so the guest can read the result straight
 * back and prove the whole transport -- packet out, work done, data back --
 * without OpenGL, a render target, or a single triangle.
 */
void pe_ring_fill(PERing *r, unsigned int dst_offset, unsigned int dst_pitch,
                  unsigned short x, unsigned short y,
                  unsigned short w, unsigned short h, unsigned int colour)
{
    PEGpuBlit *b = pe_ring_packet(r, PE_GPU_PKT_BLIT, sizeof(*b));

    if (!b) {
        return;
    }
    b->dst_offset = PE_BE32(dst_offset);
    b->dst_pitch = PE_BE32(dst_pitch);
    b->dst_x = PE_BE16(x);
    b->dst_y = PE_BE16(y);
    b->width = PE_BE16(w);
    b->height = PE_BE16(h);
    b->colour = PE_BE32(colour);
    /* src_pitch stays zero: that is what makes it a fill. */
}

int pe_ring_draw(PERing *r, unsigned int prim, const PEGpuVertexHost *verts,
                 unsigned int count)
{
    unsigned int off, i;
    PEGpuVertex *dst;
    PEGpuDraw *d;

    if (!count) {
        return 0;
    }
    dst = pe_ring_data(r, count * sizeof(*dst), &off);
    if (!dst) {
        return -1;
    }
    for (i = 0; i < count; i++) {
        const PEGpuVertexHost *v = &verts[i];
        union { float f; unsigned int u; } c;
        unsigned int argb;
        int k;
        float ch[4];

        c.f = v->pos[0]; dst[i].x = PE_BE32(c.u);
        c.f = v->pos[1]; dst[i].y = PE_BE32(c.u);
        c.f = v->pos[2]; dst[i].z = PE_BE32(c.u);
        c.f = v->pos[3]; dst[i].w = PE_BE32(c.u);
        c.f = v->tex[0]; dst[i].s = PE_BE32(c.u);
        c.f = v->tex[1]; dst[i].t = PE_BE32(c.u);

        /* The protocol carries colour packed, not as floats: one dword
         * instead of four, which matters at a few thousand draws a frame. */
        for (k = 0; k < 4; k++) {
            ch[k] = v->colour[k] < 0.0f ? 0.0f
                  : v->colour[k] > 1.0f ? 1.0f : v->colour[k];
        }
        argb = ((unsigned int)(ch[3] * 255.0f + 0.5f) << 24) |
               ((unsigned int)(ch[0] * 255.0f + 0.5f) << 16) |
               ((unsigned int)(ch[1] * 255.0f + 0.5f) << 8) |
                (unsigned int)(ch[2] * 255.0f + 0.5f);
        dst[i].colour = PE_BE32(argb);
        dst[i].reserved = 0;
    }
    d = pe_ring_packet(r, PE_GPU_PKT_DRAW, sizeof(*d));
    if (!d) {
        return -1;
    }
    d->vertex_offset = PE_BE32(off);
    d->vertex_count = PE_BE32(count);
    d->vertex_stride = PE_BE16((unsigned short)sizeof(*dst));
    d->prim = PE_BE16((unsigned short)prim);
    r->draws++;
    return 0;
}

/*
 * Capture transport.
 *
 * Until the kext exists there is no mapping to write into, but the packets
 * themselves are the interesting part: written to a file here and replayed
 * into the device on the host, they prove the encoder and the device agree
 * about the protocol -- the half of the pipeline that is easiest to get
 * subtly wrong and hardest to debug once a kernel and a guest are in the
 * way.
 */
static void pe_capture_doorbell(void *arg, unsigned int head)
{
    PERing *r = arg;
    FILE *f = (FILE *)r->capture;
    unsigned char hdr[8];

    if (!f) {
        return;
    }
    /* Each batch: its ring length, then the data-area high-water mark, so
     * the replayer knows how much of the shared area to hand over. */
    hdr[0] = head >> 24; hdr[1] = head >> 16; hdr[2] = head >> 8; hdr[3] = head;
    hdr[4] = r->data_next >> 24; hdr[5] = r->data_next >> 16;
    hdr[6] = r->data_next >> 8;  hdr[7] = r->data_next;
    fwrite(hdr, 1, sizeof(hdr), f);
    fwrite(r->base, 1, head, f);                        /* the ring */
    fwrite(r->base + PE_GPU_DATA_BASE, 1,
           r->data_next - PE_GPU_DATA_BASE, f);         /* its data */
    fflush(f);
}

int pe_ring_capture(PERing *r, const char *path)
{
    r->capture = fopen(path, "wb");
    if (!r->capture) {
        return -1;
    }
    r->doorbell = pe_capture_doorbell;
    r->doorbell_arg = r;
    return 0;
}
