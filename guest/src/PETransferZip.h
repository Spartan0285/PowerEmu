#ifndef PE_TRANSFER_ZIP_H
#define PE_TRANSFER_ZIP_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
static uint32_t PEZip16(const unsigned char *p) { return p[0]|((uint32_t)p[1]<<8); }
static uint32_t PEZip32(const unsigned char *p) { return PEZip16(p)|(PEZip16(p+2)<<16); }
/* Both central and local names are checked before extraction. Links, special
 * files, ZIP64, encryption and parent/absolute paths are not in our protocol. */
static int PETransferZipSafe(const unsigned char *d,size_t length,const char *root)
{
    size_t e,p,start,limit,rootLen=strlen(root);unsigned count,i;uint64_t total=0;
    if(length<22 || !rootLen || strchr(root,'/') || strchr(root,'\\'))return 0;
    limit=length>65557?length-65557:0;e=length-22;
    for(;;) { if(PEZip32(d+e)==0x06054b50 && e+22+PEZip16(d+e+20)==length)break;if(e==limit)return 0;e--; }
    count=PEZip16(d+e+10);start=PEZip32(d+e+16);
    if(PEZip16(d+e+4)||PEZip16(d+e+6)||count!=PEZip16(d+e+8)||!count||count==65535||start>=e||PEZip32(d+e+12)!=e-start)return 0;
    p=start;
    for(i=0;i<count;i++) {
        size_t n,extra,comment,local,body,j,component=0;uint32_t mode,compressed,raw;
        const unsigned char *name;
        if(p>e || e-p<46 || PEZip32(d+p)!=0x02014b50)return 0;
        n=PEZip16(d+p+28);extra=PEZip16(d+p+30);comment=PEZip16(d+p+32);
        if(n+extra+comment>e-p-46 || PEZip16(d+p+8)&1 || (PEZip16(d+p+10)!=0 && PEZip16(d+p+10)!=8) || PEZip16(d+p+34))return 0;
        name=d+p+46;
        if(!n || name[0]=='/' || !((n>=rootLen && memcmp(name,root,rootLen)==0 && (n==rootLen || name[rootLen]=='/')) || (n>=9 && memcmp(name,"__MACOSX/",9)==0)))return 0;
        for(j=0;j<=n;j++) {
            if(j<n && (name[j]=='\\' || name[j]==0))return 0;
            if(j==n || name[j]=='/') {
                size_t l=j-component;
                if((l==1 && name[component]=='.') || (l==2 && name[component]=='.' && name[component+1]=='.'))return 0;
                component=j+1;
            }
        }
        mode=(PEZip32(d+p+38)>>16)&0xf000;
        if(mode && mode!=0x8000 && mode!=0x4000)return 0;
        compressed=PEZip32(d+p+20);raw=PEZip32(d+p+24);local=PEZip32(d+p+42);
        if(raw==0xffffffff || compressed==0xffffffff || local>start || start-local<30 || PEZip32(d+local)!=0x04034b50 ||
           PEZip16(d+local+6)!=PEZip16(d+p+8) || PEZip16(d+local+8)!=PEZip16(d+p+10) || PEZip16(d+local+26)!=n)return 0;
        body=local+30+n+PEZip16(d+local+28);
        if(body>start || compressed>start-body || memcmp(d+local+30,name,n))return 0;
        total+=raw;if(total>4000000000ULL)return 0;
        p+=46+n+extra+comment;
    }
    return p==e;
}
#endif
