/*
 * Prove the paravirtual GPU transport from the guest, with no OpenGL.
 *
 * Run this in the guest straight after loading the kext.  It answers, in
 * order, the questions that OpenGL would otherwise answer all at once and
 * unhelpfully:
 *
 *   1. is the kext attached and can this process open it
 *   2. do both mappings come back, and is the device the one we think
 *   3. does a batch written into shared memory reach the host at all
 *   4. did the host do the work, and did the result come back
 *
 * (3) and (4) are separate on purpose.  A fence that advances says the
 * host consumed the ring; pixels that changed say it executed what was in
 * it.  A transport can pass the first and fail the second, and knowing
 * which happened is the difference between debugging the kext and
 * debugging the device.
 *
 * Copyright (c) 2026 Spartan0285
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "peconn.h"

#include <stdio.h>
#include <string.h>

#define FB_W        256
#define FB_H        64
#define FB_PITCH    (FB_W * 4)
#define FILL_COLOUR 0x11223344u

static unsigned int be32_at(const unsigned char *p)
{
    return ((unsigned int)p[0] << 24) | ((unsigned int)p[1] << 16) |
           ((unsigned int)p[2] << 8) | p[3];
}

int main(void)
{
    PEConn c;
    unsigned char *fb;
    unsigned int fb_off, fence, bad = 0, x, y;
    int rc;

    rc = pe_conn_open(&c);
    printf("open: %s\n", pe_conn_strerror(rc));
    if (rc != PE_CONN_OK) {
        return 1;
    }
    printf("features: %08x  ctrl %p  shared %p\n", c.features, c.ctrl,
           c.shared);

    fb = pe_ring_data(&c.ring, FB_PITCH * FB_H, &fb_off);
    if (!fb) {
        printf("FAIL: no room for a %dx%d target\n", FB_W, FB_H);
        pe_conn_close(&c);
        return 1;
    }

    /*
     * Poisoned rather than zeroed, so a host that does nothing at all is
     * distinguishable from one that filled with black.
     */
    memset(fb, 0xA5, FB_PITCH * FB_H);

    pe_ring_fill(&c.ring, fb_off, FB_PITCH, 0, 0, FB_W, FB_H, FILL_COLOUR);
    fence = pe_ring_fence(&c.ring);
    pe_ring_flush(&c.ring);                 /* this rings the doorbell */

    if (pe_conn_wait(&c, fence, 10000000)) {
        printf("FAIL: fence %u never reached (host has %u), error %u\n",
               fence, pe_conn_fence(&c), pe_conn_error(&c));
        pe_conn_close(&c);
        return 1;
    }
    printf("fence %u reached, error %u\n", fence, pe_conn_error(&c));

    for (y = 0; y < FB_H; y++) {
        for (x = 0; x < FB_W; x++) {
            if (be32_at(fb + y * FB_PITCH + x * 4) != FILL_COLOUR) {
                bad++;
            }
        }
    }
    if (bad) {
        printf("FAIL: %u of %u pixels are not %08x (first is %08x)\n",
               bad, FB_W * FB_H, FILL_COLOUR, be32_at(fb));
        pe_conn_close(&c);
        return 1;
    }

    printf("PASS: %u pixels written by the host and read back by the guest\n",
           FB_W * FB_H);
    pe_conn_close(&c);
    return 0;
}
