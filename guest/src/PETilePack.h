#ifndef PE_TILE_PACK_H
#define PE_TILE_PACK_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
/* Canonical 32x32 RGBA tiles, clipped at the right/bottom edges. The wire
 * stream uses big-endian integers on both PPC and Intel/ARM:
 * base sequence, changed count, then ascending (tile index, raw pixels).
 * A bounded destination aborts dense updates early; caller sends a full frame.
 */
static void PETilePut32(unsigned char *p, uint32_t n) {
    p[0]=n>>24; p[1]=n>>16; p[2]=n>>8; p[3]=n;
}
/* Cheap rejection of broadly changing content. False negatives only select
 * a full frame; actual tile selection always compares every included byte. */
static int PETileWorthTrying(const unsigned char *before, const unsigned char *after, size_t pixels) {
    if (!before || !after || !pixels) return 0;
    unsigned i, changed=0;
    for(i=0;i<64;i++) {
        size_t offset=((pixels-1)*i/63)*4;
        if(memcmp(before+offset,after+offset,4) && ++changed>=8) return 0;
    }
    return 1;
}
static size_t PETilePack(const unsigned char *before, const unsigned char *after,
                         unsigned w, unsigned h, uint32_t base,
                         unsigned char *out, size_t capacity) {
    if (!before || !after || !out || !base || !w || !h || w>4096 || h>4096 || capacity<8) return 0;
    unsigned x,y,row,cols=(w+31)/32,count=0;
    size_t used=8;
    for(y=0;y<h;y+=32) for(x=0;x<w;x+=32) {
        unsigned tw=w-x<32?w-x:32, th=h-y<32?h-y:32;
        size_t bytes=(size_t)tw*th*4;
        int changed=0;
        for(row=0;row<th;row++) {
            size_t offset=((size_t)(y+row)*w+x)*4;
            if(memcmp(before+offset,after+offset,tw*4)) {changed=1;break;}
        }
        if(!changed) continue;
        if(capacity-used<4+bytes) return 0;
        PETilePut32(out+used,(y/32)*cols+x/32);used+=4;
        for(row=0;row<th;row++) {
            memcpy(out+used,after+((size_t)(y+row)*w+x)*4,tw*4);used+=tw*4;
        }
        count++;
    }
    if(!count) return 0;
    PETilePut32(out,base);PETilePut32(out+4,count);
    return used;
}
#endif
