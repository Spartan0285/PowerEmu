/* Read-only, opt-in Tiger menu-window diagnostic. Not part of Guest Tools.
 * Launch in an owned GUI session only. Does not activate/modify/capture windows.
 * Retains 300 bounded snapshots in memory, then writes a new owner-only receipt.
 * A 50ms sampling gap can miss short-lived windows; absence is not proof.
 * Each query is sequential, not an atomic snapshot. A blocked CGS query needs
 * the external owned-VM guard; the 15-second limit is checked between samples.
 * Build using the 10.4u PPC SDK. Host syntax checking is not runtime validation.
 */
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <mach/mach_time.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>

enum { SampleCapacity=300, WindowCapacity=512 };
typedef int (*ConnectionFn)(void);
typedef CGError (*ListFn)(int,int,int,int *,int *);
typedef CGError (*IntFn)(int,int,int *);
typedef CGError (*RectFn)(int,int,CGRect *);
typedef CGError (*PIDFn)(int,pid_t *,int);
typedef struct {
    int wid,owner,level,pid,ownerError,levelError,rectError,pidError;
    CGRect rect;
} WindowRow;
typedef struct {
    uint64_t began,ended;
    int error,count,truncated;
    WindowRow windows[WindowCapacity];
} Snapshot;

int main(int argc, const char **argv)
{
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    ConnectionFn connection=(ConnectionFn)dlsym(RTLD_DEFAULT,"_CGSDefaultConnection");
    ListFn list=(ListFn)dlsym(RTLD_DEFAULT,"CGSGetOnScreenWindowList");
    IntFn owner=(IntFn)dlsym(RTLD_DEFAULT,"CGSGetWindowOwner");
    IntFn level=(IntFn)dlsym(RTLD_DEFAULT,"CGSGetWindowLevel");
    RectFn rect=(RectFn)dlsym(RTLD_DEFAULT,"CGSGetScreenRectForWindow");
    PIDFn pid=(PIDFn)dlsym(RTLD_DEFAULT,"CGSConnectionGetPID");
    Snapshot *samples=NULL;
    mach_timebase_info_data_t tb;
    int cid=0,n=0,i,j,fd=-1,result=1;
    uint64_t start=0,end=0;
    char path[128];
    FILE *out=NULL;
    (void)argc;(void)argv;
    if(!connection||!list||!owner||!level||!rect||!pid)goto done;
    if(mach_timebase_info(&tb)!=KERN_SUCCESS||!tb.denom)goto done;
    cid=connection();if(!cid)goto done;
    samples=calloc(SampleCapacity,sizeof(*samples));if(!samples)goto done;
    start=mach_absolute_time();
    for(n=0;n<SampleCapacity;n++) {
        int ids[WindowCapacity],count=0;
        Snapshot *s=&samples[n];
        s->began=mach_absolute_time();
        if((double)(s->began-start)*tb.numer/tb.denom>=15e9)break;
        s->error=list(cid,0,WindowCapacity,ids,&count);
        s->truncated=count>=WindowCapacity;
        if(s->error==0&&count>=0&&count<=WindowCapacity) {
            s->count=count;
            for(i=0;i<count;i++) {
                WindowRow *w=&s->windows[i];w->wid=ids[i];
                w->ownerError=owner(cid,w->wid,&w->owner);
                w->levelError=level(cid,w->wid,&w->level);
                w->rectError=rect(cid,w->wid,&w->rect);
                w->pidError=w->ownerError==0?pid(cid,&w->pid,w->owner):-1;
            }
        } else if(s->error==0)s->error=-1;
        s->ended=mach_absolute_time();
        usleep(50000); /* actual query start/end retained; not an exact cadence */
    }
    end=mach_absolute_time();
    snprintf(path,sizeof(path),"/tmp/pe-menu-trace-%d.json",(int)getpid());
    fd=open(path,O_WRONLY|O_CREAT|O_EXCL,0600);if(fd<0)goto done;
    out=fdopen(fd,"w");if(!out) {close(fd);fd=-1;goto done;}
    fprintf(out,"{\"version\":1,\"pid\":%d,\"timebaseNumer\":%u,\"timebaseDenom\":%u,\"start\":%llu,\"end\":%llu,\"samples\":[",(int)getpid(),tb.numer,tb.denom,(unsigned long long)start,(unsigned long long)end);
    for(i=0;i<n;i++) {
        Snapshot *s=&samples[i];
        fprintf(out,"%s{\"begin\":%llu,\"end\":%llu,\"error\":%d,\"truncated\":%d,\"windows\":[",i?",":"",(unsigned long long)s->began,(unsigned long long)s->ended,s->error,s->truncated);
        for(j=0;j<s->count;j++) {
            WindowRow *w=&s->windows[j];
            fprintf(out,"%s{\"id\":%d,\"owner\":%d,\"pid\":%d,\"level\":%d,\"errors\":[%d,%d,%d,%d],\"rect\":[%.9g,%.9g,%.9g,%.9g]}",j?",":"",w->wid,w->owner,w->pid,w->level,w->ownerError,w->pidError,w->levelError,w->rectError,(double)w->rect.origin.x,(double)w->rect.origin.y,(double)w->rect.size.width,(double)w->rect.size.height);
        }
        fputs("]}",out);
    }
    fputs("]}\n",out);
    {int bad=ferror(out);if(fclose(out)!=0)bad=1;out=NULL;if(!bad)result=0;}
done:
    if(out)fclose(out);
    free(samples);[pool release];return result;
}
