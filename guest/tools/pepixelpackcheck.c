/* Emit cross-platform fixtures for the Swift decoder, exercising the actual
 * guest encoder. Also check output capacity and untouched guard bytes. */
#include "../src/PEPixelPack.h"
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
static uint32_t rng = 7;
static uint32_t next(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static void be32(FILE *f, uint32_t n) {
    unsigned char b[4] = {n >> 24, n >> 16, n >> 8, n}; assert(fwrite(b, 1, 4, f) == 4);
}
int main(int argc, char **argv) {
    assert(argc == 2); FILE *f = fopen(argv[1], "wb"); assert(f);
    uint32_t pixels[4096]; unsigned char packed[4096*5+16];
    int test, selected = 0;
    for (test = 0; test < 600; test++) {
        size_t count = test < 260 ? test + 1 : 1 + next()%4096, i;
        for (i = 0; i < count; i++) {
            if (test%3 == 0) pixels[i] = 0x12345678;
            else if (test%3 == 1) pixels[i] = next();
            else pixels[i] = i && next()%8 ? pixels[i-1] : next();
        }
        int worth = PEPixelPackWorthTrying(pixels, count); selected += worth;
        if (test%3 == 0 && count >= 3) assert(worth);
        if (test%3 == 1) assert(!worth);
        size_t length = PEPixelPack(pixels, count, packed, sizeof packed); assert(length);
        be32(f, count); be32(f, length);
        assert(fwrite(pixels, 4, count, f) == count);
        assert(fwrite(packed, 1, length, f) == length);
        size_t limits[5] = {0,1,4,length-1,length}; int j;
        for (j = 0; j < 5; j++) {
            memset(packed, 0xcd, sizeof packed);
            size_t n = PEPixelPack(pixels, count, packed, limits[j]);
            assert(n == (limits[j] < length ? 0 : length));
            for (i = limits[j]; i < sizeof packed; i++) assert(packed[i] == 0xcd);
        }
    }
    fclose(f); printf("PASS: 600 pixel packet fixtures, bounded output guards, preflight (%d selected)\n", selected); return 0;
}
