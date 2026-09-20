/*
 * Native unit test for the guest ring writer.  Runs on the development
 * machine: the encoder is plain C and its arithmetic is worth checking
 * where a mistake is an assertion rather than a hung guest.  It also
 * verifies the packets come out big-endian on a little-endian host, which
 * is exactly the bug that would otherwise only appear in the guest.
 */
#include "pering.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned int last_head;
static int rings;

static void doorbell(void *arg, unsigned int head)
{
    (void)arg;
    last_head = head;
    rings++;
}

static unsigned int be32(const void *p)
{
    const unsigned char *b = p;
    return ((unsigned int)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
}

int main(void)
{
    unsigned char *shared = calloc(1, PE_GPU_SHARED_BYTES);
    PEGpuVertexHost v[3];
    PERing r;
    int i, fails = 0;

    assert(shared);
    pe_ring_init(&r, shared, PE_GPU_SHARED_BYTES);
    r.doorbell = doorbell;

    /* a fence packet is well formed and big-endian on the wire */
    unsigned int seq = pe_ring_fence(&r);
    if (seq != 1) { printf("FAIL: first fence is %u\n", seq); fails++; }
    if (be32(shared + 0) >> 16 != PE_GPU_PKT_FENCE) {
        printf("FAIL: fence type not big-endian\n"); fails++;
    }
    if (be32(shared + 4) != sizeof(PEGpuFence)) {
        printf("FAIL: fence size %u\n", be32(shared + 4)); fails++;
    }

    /* a draw lands its vertices in the data area, 256-byte aligned */
    memset(v, 0, sizeof(v));
    for (i = 0; i < 3; i++) { v[i].pos[0] = (float)i; v[i].pos[3] = 1.0f; }
    if (pe_ring_draw(&r, PE_GPU_PRIM_TRIANGLES, v, 3)) {
        printf("FAIL: draw rejected\n"); fails++;
    }
    if (r.data_next <= PE_GPU_DATA_BASE) {
        printf("FAIL: no data allocated\n"); fails++;
    }

    /* the ring refuses to overflow rather than wrapping into itself */
    while (pe_ring_packet(&r, PE_GPU_PKT_NOP, 64)) {
        if (r.head > PE_GPU_RING_BYTES) {
            printf("FAIL: head ran past the ring\n"); fails++; break;
        }
    }
    if (r.head + 64 <= PE_GPU_RING_BYTES) {
        printf("FAIL: stopped early at %u\n", r.head); fails++;
    }

    /* flushing rings the doorbell once and resets both allocators */
    pe_ring_flush(&r);
    if (rings != 1 || !last_head) { printf("FAIL: doorbell\n"); fails++; }
    if (r.head || r.data_next != PE_GPU_DATA_BASE) {
        printf("FAIL: not reset after flush\n"); fails++;
    }

    /* an empty batch must not ring the doorbell */
    pe_ring_flush(&r);
    if (rings != 1) { printf("FAIL: rang on an empty batch\n"); fails++; }

    printf("%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
    free(shared);
    return fails != 0;
}
