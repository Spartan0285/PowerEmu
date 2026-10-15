#include <sys/socket.h>
#include <stdio.h>
#include <assert.h>
#include "../../guest/src/PECaptureRequest.h"
static void check(const char *data,size_t n,int expected) {
 int pair[2];char text[257];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));
 assert(write(pair[0],data,n)==(ssize_t)n);shutdown(pair[0],SHUT_WR);
 int got=PEReadCaptureRequest(pair[1],text);if(got!=expected)fprintf(stderr,"case %.*s got %d expected %d\n",(int)n,data,got,expected);
 assert(got==expected);close(pair[0]);close(pair[1]);
}
static void payload(const char *text,int expected) {
 char packet[512];int n=snprintf(packet,sizeof packet,"WINDOWFRAME %lu\n%s",(unsigned long)strlen(text),text);check(packet,n,expected);
}
#define CHECK(s,e) check(s,sizeof(s)-1,e)
int main(void) {
 payload("12 1 0 rle32 tiles32 fresh",1);payload("12 1 0 rle32 tiles32",1);
 CHECK("",0);CHECK("RUN 4\nnoop",-1);CHECK("WINDOWFRAME 257\n",-1);
 CHECK("WINDOWFRAME 9999999999999999999999999\n",-1);CHECK("WINDOWFRAME 19\n12 1",-1);
 payload("00 0 0 rle32 tiles32",-1);payload("-1 1 0 rle32 tiles32",-1);
 payload("12 1 0 rle32 tiles3X",-1);payload("21474836480000 1 0 rle32 tiles32",-1);
 CHECK("WINDOWFRAME 19\n12 1 0 rle32\0tiles32",-1);
 puts("PASS capture-only parser valid, fresh, EOF, wrong verb, limits, truncation, invalid fields and embedded NUL");
}
