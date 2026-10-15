/* Capture-only socket parser. Bounded requests, no general command dispatch. */
#ifndef PE_CAPTURE_REQUEST_H
#define PE_CAPTURE_REQUEST_H
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
static int PEReadCaptureExact(int fd, char *bytes, size_t length) {
    while(length) { ssize_t n=read(fd,bytes,length); if(n<0&&errno==EINTR)continue;
        if(n<=0)return 0; bytes+=n;length-=n; }
    return 1;
}
static int PEValidCaptureText(const char *text) {
    const char *p=text;int i;
    for(i=0;i<3;i++) {
        char *end;long value;
        if(*p<'0'||*p>'9')return 0;
        errno=0;value=strtol(p,&end,10);
        if(errno||value>INT_MAX||(i<2&&value<=0)||*end!=' ')return 0;
        p=end+1;
    }
    return !strcmp(p,"rle32 tiles32")||!strcmp(p,"rle32 tiles32 fresh");
}
/* 1 valid request, 0 clean EOF, -1 malformed/truncated/read failure. */
static int PEReadCaptureRequest(int fd,char output[257]) {
    char header[64];size_t n=0,length=0;char *p;
    while(n<sizeof(header)-1) {
        ssize_t got=read(fd,header+n,1);
        if(got<0&&errno==EINTR)continue;
        if(got==0&&n==0)return 0;
        if(got!=1)return -1;
        if(header[n++]=='\n')break;
    }
    if(!n||header[n-1]!='\n')return -1;
    header[n-1]=0;
    if(strncmp(header,"WINDOWFRAME ",12))return -1;
    p=header+12;if(!*p)return -1;
    while(*p) { if(*p<'0'||*p>'9')return -1;length=length*10+(*p++-'0');if(length>256)return -1; }
    if(!length||!PEReadCaptureExact(fd,output,length)||memchr(output,0,length))return -1;
    output[length]=0;
    return PEValidCaptureText(output)?1:-1;
}
#endif
