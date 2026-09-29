/* Independent RGBA pixel packets. A control byte stores count-1 (0..127).
 * High bit: repeat the following four bytes. Otherwise copy count pixels.
 * Return zero if the output exceeds capacity, so the caller can use zlib.
 * Source/destination never overlap. No host/guest byte-order assumptions. */
#ifndef PE_PIXEL_PACK_H
#define PE_PIXEL_PACK_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>
/* Cheap rejection for detailed images before allocating/trying the encoder.
 * A false positive only causes the bounded encoder to fall back to zlib;
 * a false negative uses zlib directly. Neither can change image pixels. */
static int PEPixelPackWorthTrying(const uint32_t *pixels, size_t count)
{
    if (count < 3) return 0;
    size_t sample, repeated = 0;
    for (sample = 0; sample < 128; sample++) {
        size_t i = (count - 3) * sample / 127;
        if (pixels[i] == pixels[i+1] && pixels[i] == pixels[i+2]) repeated++;
    }
    // Be conservative: favor long uniform regions, not marginal compression.
    return repeated >= 104;
}
static size_t PEPixelPack(const uint32_t *pixels, size_t count,
                          unsigned char *out, size_t capacity)
{
    size_t i = 0, used = 0;
    while (i < count) {
        size_t run = 1;
        while (run < 128 && i + run < count && pixels[i + run] == pixels[i]) run++;
        if (run >= 3) {
            if (capacity - used < 5) return 0;
            out[used++] = 0x80 | (unsigned char)(run - 1);
            memcpy(out + used, pixels + i, 4); used += 4; i += run;
        } else {
            size_t start = i;
            i += run;
            while (i < count && i - start < 128) {
                if (i + 2 < count && pixels[i] == pixels[i+1] && pixels[i] == pixels[i+2]) break;
                i++;
            }
            size_t length = i - start;
            if (capacity - used < 1 + length * 4) return 0;
            out[used++] = (unsigned char)(length - 1);
            memcpy(out + used, pixels + start, length * 4); used += length * 4;
        }
    }
    return used;
}
#endif
