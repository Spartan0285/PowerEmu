/* Diagnostic-only Tiger destination-scaling experiment. The fixture mode
 * owns two windows and never interacts with another app or changes input.
 * Results are bounded in memory and printed once at completion.
 *
 *   pecapturescalecheck --fixture
 *   pecapturescalecheck --list
 *   pecapturescalecheck WINDOW_ID EXPECTED_WIDTH EXPECTED_HEIGHT
 *
 * Only --fixture establishes output semantics: it verifies exact known
 * source pixels at full size and against an independent nearest-neighbor
 * half-size reference, then repeats those checks while covered by its own
 * second window. Timing is only the private call cost and does not establish
 * UI quality or responsiveness.
 */
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SOURCE_W 640
#define SOURCE_H 400
#define CYCLES 12
typedef int (*ConnectionFn)(void);
typedef CGError (*BoundsFn)(int, int, CGRect *);
typedef CGError (*ListFn)(int, int, int, int *, int *);
typedef CGError (*LevelFn)(int, int, int *);
typedef void (*CaptureFn)(CGContextRef, CGRect, int, int, CGRect);
static mach_timebase_info_data_t tb;
static double mono(void) { return (double)mach_absolute_time()*tb.numer/tb.denom/1.0e9; }
static double threadCPU(void)
{
    thread_basic_info_data_t info; mach_msg_type_number_t n=THREAD_BASIC_INFO_COUNT;
    thread_t self=mach_thread_self(); kern_return_t kr=thread_info(self,THREAD_BASIC_INFO,(thread_info_t)&info,&n);
    mach_port_deallocate(mach_task_self(),self);
    return kr==KERN_SUCCESS ? info.user_time.seconds+info.system_time.seconds+
        (info.user_time.microseconds+info.system_time.microseconds)/1.0e6 : -1;
}

@interface ScalePatternView : NSView
@end
@implementation ScalePatternView
- (void)drawRect:(NSRect)dirty
{
    CGContextRef c=[[NSGraphicsContext currentContext] graphicsPort];
    CGContextSaveGState(c); CGContextSetShouldAntialias(c,false);
    /* Four unmistakable regions plus an aligned checker field exercise both
     * source edges and a dense interior. All colors are opaque and exact. */
    CGContextSetRGBFillColor(c,1,0,0,1); CGContextFillRect(c,CGRectMake(0,0,320,200));
    CGContextSetRGBFillColor(c,0,1,0,1); CGContextFillRect(c,CGRectMake(320,0,320,200));
    CGContextSetRGBFillColor(c,0,0,1,1); CGContextFillRect(c,CGRectMake(0,200,320,200));
    CGContextSetRGBFillColor(c,1,1,0,1); CGContextFillRect(c,CGRectMake(320,200,320,200));
    int x,y;
    for(y=104;y<296;y+=8) for(x=104;x<536;x+=8) {
        if (((x/8)+(y/8))&1) {
            CGContextSetRGBFillColor(c,1,1,1,1);
            CGContextFillRect(c,CGRectMake(x,y,8,8));
        }
    }
    /* Four corner marks distinguish every source edge after scaling. */
    CGContextSetRGBFillColor(c,0,0,0,1);
    CGContextFillRect(c,CGRectMake(8,8,32,32));
    CGContextFillRect(c,CGRectMake(600,8,32,32));
    CGContextFillRect(c,CGRectMake(8,360,32,32));
    CGContextFillRect(c,CGRectMake(600,360,32,32));
    CGContextRestoreGState(c);
}
@end

typedef struct { int cycle,w,h,covered,valid; double call,flush,wall,cpu; } Row;
static void expectedRGB(int x,int y,unsigned char rgb[4])
{
    if(x<320&&y<200){rgb[0]=255;rgb[1]=0;rgb[2]=0;}
    else if(x>=320&&y<200){rgb[0]=0;rgb[1]=255;rgb[2]=0;}
    else if(x<320){rgb[0]=0;rgb[1]=0;rgb[2]=255;}
    else {rgb[0]=255;rgb[1]=255;rgb[2]=0;}
    if(x>=104&&x<536&&y>=104&&y<296&&(((x/8)+(y/8))&1))
        rgb[0]=rgb[1]=rgb[2]=255;
    if(((x>=8&&x<40)||(x>=600&&x<632))&&
       ((y>=8&&y<40)||(y>=360&&y<392)))
        rgb[0]=rgb[1]=rgb[2]=0;
    rgb[3]=255;
}
static int oracleBoundaryTest(void)
{
    static const struct {int x,y,r,g,b;} cases[]={
        {7,8,255,0,0},{8,8,0,0,0},{39,39,0,0,0},{40,39,255,0,0},
        {599,8,0,255,0},{600,8,0,0,0},{631,39,0,0,0},{632,39,0,255,0},
        {8,359,0,0,255},{8,360,0,0,0},{39,391,0,0,0},{40,391,0,0,255},
        {599,360,255,255,0},{600,360,0,0,0},{631,391,0,0,0},{632,391,255,255,0}
    };
    unsigned char p[4]; unsigned i;
    for(i=0;i<sizeof(cases)/sizeof(cases[0]);i++){
        expectedRGB(cases[i].x,cases[i].y,p);
        if(p[0]!=cases[i].r||p[1]!=cases[i].g||p[2]!=cases[i].b||p[3]!=255)return 0;
    }
    return 1;
}
static int pixelError(const unsigned char *actual,int aw,int ah,int flip,int scale)
{
    int x,y,k,errors=0;
    for(y=0;y<ah;y++) for(x=0;x<aw;x++) {
        int sx=(x*scale)+(scale/2), sy=(y*scale)+(scale/2);
        int ly=flip ? SOURCE_H-1-sy : sy;
        unsigned char expected[4];
        if (sx<0||sx>=SOURCE_W||ly<0||ly>=SOURCE_H) return 0x7fffffff;
        expectedRGB(sx,ly,expected);
        const unsigned char *p=actual+((size_t)y*aw+x)*4;
        for(k=0;k<4;k++) if(abs((int)p[k]-(int)expected[k])>1) errors++;
    }
    return errors;
}
static int verifyCapture(CaptureFn capture,int cid,int wid,int dw,int dh,int *flipOut,
                         int allowOrientation)
{
    size_t stride=(size_t)dw*4,length=stride*dh;
    NSMutableData *data=[[NSMutableData alloc] initWithLength:length];
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate([data mutableBytes],dw,dh,8,stride,cs,kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs); if(!ctx){[data release];return -1;}
    /* Private API order under test: first rect is destination, final rect is
     * the full source window. This call is accepted only after pixel proof. */
    capture(ctx,CGRectMake(0,0,dw,dh),cid,wid,CGRectMake(0,0,SOURCE_W,SOURCE_H));
    CGContextFlush(ctx);
    int e0=pixelError([data bytes],dw,dh,0,SOURCE_W/dw);
    int e1=allowOrientation ? pixelError([data bytes],dw,dh,1,SOURCE_W/dw) : e0;
    int flip=e1<e0, errors=flip?e1:e0;
    if(flipOut)*flipOut=flip;
    CGContextRelease(ctx);[data release];
    return errors;
}
static int timingCapture(CaptureFn capture,BoundsFn bounds,int cid,int wid,CGRect geometry,
                        int dw,int dh,int cycle,int covered,Row *r)
{
    size_t stride=(size_t)dw*4,length=stride*dh;
    NSMutableData *data=[[NSMutableData alloc] initWithLength:length];
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate([data mutableBytes],dw,dh,8,stride,cs,kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs); if(!ctx){[data release];return 0;}
    CGRect before,after; int ok=bounds(cid,wid,&before)==kCGErrorSuccess&&CGRectEqualToRect(geometry,before);
    double w0=mono(),c0=threadCPU(),a=mono();
    capture(ctx,CGRectMake(0,0,dw,dh),cid,wid,CGRectMake(0,0,SOURCE_W,SOURCE_H));
    double b=mono(); CGContextFlush(ctx); double c=mono(),c1=threadCPU();
    ok=ok&&bounds(cid,wid,&after)==kCGErrorSuccess&&CGRectEqualToRect(geometry,after);
    r->cycle=cycle;r->w=dw;r->h=dh;r->covered=covered;r->call=(b-a)*1000;
    r->flush=(c-b)*1000;r->wall=(c-w0)*1000;r->cpu=c0>=0&&c1>=c0?(c1-c0)*1000:-1;r->valid=ok;
    CGContextRelease(ctx);[data release];return ok;
}
static int listWindows(ConnectionFn connection,ListFn list,BoundsFn bounds,LevelFn level)
{
    int cid=connection(),ids[256],count=0,i;
    if(!list||list(cid,0,256,ids,&count)!=kCGErrorSuccess)return 3;
    for(i=0;i<count;i++){CGRect r;int z=-1;
        if(bounds(cid,ids[i],&r)==kCGErrorSuccess&&level&&level(cid,ids[i],&z)==kCGErrorSuccess)
            printf("window=%d level=%d geometry=%.0f,%.0f %.0fx%.0f\n",ids[i],z,r.origin.x,r.origin.y,r.size.width,r.size.height);
    }return 0;
}
int main(int argc,char **argv)
{
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    NSApplicationLoad(); signal(SIGALRM,SIG_DFL); alarm(30);
    if(mach_timebase_info(&tb)!=KERN_SUCCESS||!tb.denom)return 3;
    if(argc==2&&!strcmp(argv[1],"--oracle-test")){
        int ok=oracleBoundaryTest();alarm(0);printf("%s: exact corner-mark oracle boundaries\n",ok?"PASS":"FAIL");
        [pool drain];return ok?0:1;
    }
    ConnectionFn connection=(ConnectionFn)dlsym(RTLD_DEFAULT,"_CGSDefaultConnection");
    BoundsFn bounds=(BoundsFn)dlsym(RTLD_DEFAULT,"CGSGetScreenRectForWindow");
    ListFn list=(ListFn)dlsym(RTLD_DEFAULT,"CGSGetOnScreenWindowList");
    LevelFn level=(LevelFn)dlsym(RTLD_DEFAULT,"CGSGetWindowLevel");
    CaptureFn capture=(CaptureFn)dlsym(RTLD_DEFAULT,"CGContextCopyWindowCaptureContentsToRect");
    if(argc==2&&!strcmp(argv[1],"--list")) return connection&&bounds?listWindows(connection,list,bounds,level):3;
    if(!connection||!bounds||!capture){fprintf(stderr,"UNAVAILABLE: required private API missing\n");return 3;}
    BOOL fixture=argc==2&&!strcmp(argv[1],"--fixture");
    NSWindow *window=nil,*cover=nil;
    int wid,coverID=0,expectedW=SOURCE_W,expectedH=SOURCE_H;
    if(fixture){
        window=[[NSWindow alloc]initWithContentRect:NSMakeRect(40,40,SOURCE_W,SOURCE_H)
            styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        [window setReleasedWhenClosed:NO];[window setOpaque:YES];
        ScalePatternView *view=[[ScalePatternView alloc]initWithFrame:NSMakeRect(0,0,SOURCE_W,SOURCE_H)];
        [window setContentView:view];[view release];[window orderFront:nil];[window display];[window flushWindow];
        wid=[window windowNumber];
    }else{
        if(argc!=4){fprintf(stderr,"usage: pecapturescalecheck --fixture | --list | WINDOW_ID EXPECTED_WIDTH EXPECTED_HEIGHT\n");return 2;}
        wid=atoi(argv[1]);expectedW=atoi(argv[2]);expectedH=atoi(argv[3]);
    }
    int cid=connection();CGRect geometry;
    if(wid<=0||bounds(cid,wid,&geometry)!=kCGErrorSuccess||geometry.size.width!=expectedW||geometry.size.height!=expectedH){
        fprintf(stderr,"UNAVAILABLE: initial geometry mismatch (expected %dx%d)\n",expectedW,expectedH);return 4;}
    if(fixture){
        int full0=verifyCapture(capture,cid,wid,SOURCE_W,SOURCE_H,NULL,1);
        int half0=verifyCapture(capture,cid,wid,SOURCE_W/2,SOURCE_H/2,NULL,1);
        if(full0!=0||half0!=0){fprintf(stderr,"UNAVAILABLE: destination/source rectangle semantics or known-pattern check failed (full_errors=%d half_errors=%d)\n",full0,half0);return 5;}
        cover=[[NSWindow alloc]initWithContentRect:NSMakeRect(40,40,SOURCE_W,SOURCE_H)
            styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        [cover setReleasedWhenClosed:NO];[cover setOpaque:YES];[cover setBackgroundColor:[NSColor grayColor]];
        [cover orderFront:nil];[cover display];[cover flushWindow];coverID=[cover windowNumber];
        int coveredHalf=verifyCapture(capture,cid,wid,SOURCE_W/2,SOURCE_H/2,NULL,1);
        int coveredFull=verifyCapture(capture,cid,wid,SOURCE_W,SOURCE_H,NULL,1);
        if(coveredHalf!=0||coveredFull!=0){fprintf(stderr,"UNAVAILABLE: covered backing-store pixel check failed (half_errors=%d full_errors=%d)\n",coveredHalf,coveredFull);return 6;}
        [cover orderOut:nil];
    }else if(expectedW<1||expectedH<1||expectedW>4096||expectedH>4096){return 2;}

    Row rows[CYCLES*3];int n=0,fail=0,cycle,phase;
    for(cycle=1;cycle<=CYCLES;cycle++)for(phase=0;phase<3;phase++){
        int dw=phase==1?expectedW/2:expectedW,dh=phase==1?expectedH/2:expectedH;
        if(!fixture&&phase==1){dw=(expectedW+1)/2;dh=(expectedH+1)/2;}
        if(dw<1||dh<1)continue;
        if(!timingCapture(capture,bounds,cid,wid,geometry,dw,dh,cycle,0,&rows[n]))fail++;
        n++;
    }
    int coveredFinalOK=1;
    if(fixture){
        coveredFinalOK=cover!=nil&&coverID>0;
        if(coveredFinalOK){[cover orderFront:nil];[cover display];[cover flushWindow];coveredFinalOK=[cover isVisible];}
        if(coveredFinalOK) coveredFinalOK=
            verifyCapture(capture,cid,wid,SOURCE_W/2,SOURCE_H/2,NULL,1)==0&&
            verifyCapture(capture,cid,wid,SOURCE_W,SOURCE_H,NULL,1)==0;
        if(!coveredFinalOK)fail++;
        [cover orderOut:nil];
        [cover release];cover=nil;
    }
    printf("source=%dx%d window=%d cover_window=%d rows=%d order=full,half,full\n",expectedW,expectedH,wid,coverID,n);
    printf("cycle destination covered call_ms flush_ms wall_ms thread_cpu_ms bounds\n");
    int i;for(i=0;i<n;i++)printf("%d %dx%d %d %.3f %.3f %.3f %.3f %s\n",rows[i].cycle,rows[i].w,rows[i].h,
        rows[i].covered,rows[i].call,rows[i].flush,rows[i].wall,rows[i].cpu,rows[i].valid?"stable":"changed");
    printf("%s: known-pattern full/half precheck=%s initialCovered=PASS finalCovered=%s; no cross-resolution pixel identity claim\n",
        fail?"FAIL":"PASS",fixture?"PASS":"not-run",fixture?(coveredFinalOK?"PASS":"FAIL"):"not-run");
    alarm(0);[pool drain];return fail||n!=CYCLES*3?1:0;
}
