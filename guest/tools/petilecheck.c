#include "../src/PETilePack.h"
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <time.h>
#include <zlib.h>
static uint32_t rng=23;
static unsigned randomByte(void) {rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng&255;}
static void word(FILE *f,uint32_t n) {unsigned char b[4];PETilePut32(b,n);assert(fwrite(b,1,4,f)==4);}
int main(int argc,char **argv) {
    assert(argc==2);FILE *f=fopen(argv[1],"wb");assert(f);
    int test;
    for(test=0;test<120;test++) {
        unsigned w=1+(test*37)%193,h=1+(test*23)%161;
        size_t size=(size_t)w*h*4, cap=size+((w+31)/32)*((h+31)/32)*4+8,i;
        unsigned char *a=malloc(size),*b=malloc(size),*out=malloc(cap+16);
        for(i=0;i<size;i++) a[i]=randomByte();
        memcpy(b,a,size);b[(test*173)%size]^=255;b[size-1]^=1;
        size_t n=PETilePack(a,b,w,h,7,out,cap);assert(n);
        word(f,w);word(f,h);word(f,n);
        assert(fwrite(a,1,size,f)==size && fwrite(b,1,size,f)==size && fwrite(out,1,n,f)==n);
        size_t limits[]={0,7,n-1,n};int j;
        for(j=0;j<4;j++) {
            memset(out,0xcd,cap+16);
            assert(PETilePack(a,b,w,h,7,out,limits[j])==(limits[j]<n?0:n));
            for(i=limits[j];i<cap+16;i++) assert(out[i]==0xcd);
        }
        assert(!PETilePack(a,a,w,h,7,out,cap));
        assert(!PETilePack(a,b,w,h,0,out,cap));
        free(a);free(b);free(out);
    }
    fclose(f);
    unsigned w=1024,h=768;size_t size=(size_t)w*h*4,i;
    unsigned char *a=malloc(size),*b=malloc(size),*tiles=malloc(size/8),*z=malloc(compressBound(size));
    for(i=0;i<size;i++) a[i]=randomByte();
    memcpy(b,a,size);b[100*4096+100*4]^=255;
    assert(PETileWorthTrying(a,b,size/4));
    int run;double fullMS=0,tileMS=0;uLongf fullBytes=0,tileBytes=0;size_t n=0;
    for(run=0;run<20;run++) {
        clock_t start=clock();fullBytes=compressBound(size);assert(compress2(z,&fullBytes,b,size,1)==Z_OK);
        fullMS+=(double)(clock()-start)*1000/CLOCKS_PER_SEC;
        start=clock();n=PETilePack(a,b,w,h,7,tiles,size/8);assert(n);
        tileBytes=compressBound(size);assert(compress2(z,&tileBytes,tiles,n,1)==Z_OK);
        tileMS+=(double)(clock()-start)*1000/CLOCKS_PER_SEC;
    }
    printf("PASS: 120 fixtures, edge tiles, bounds, unchanged and missing base\n");
    printf("SYNTHETIC noisy 1024x768, one changed pixel: fullMS=%.3f fullBytes=%lu tileMS=%.3f tileBytes=%lu rawTileBytes=%lu\n",fullMS/20,(unsigned long)fullBytes,tileMS/20,(unsigned long)tileBytes,(unsigned long)n);
    memset(b,0,size);assert(!PETileWorthTrying(a,b,size/4));assert(!PETilePack(a,b,w,h,7,tiles,size/8));
    free(a);free(b);free(tiles);free(z);return 0;
}
