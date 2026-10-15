/* Diagnostic-only report/capture contention fixture for Tiger.
 * It owns a known 640x400 window, calls PEAgent's inherited reportWindows:
 * from a main-thread 12 Hz NSTimer, and captures that owned window on one
 * serial worker at 12 Hz. Baseline mode runs reports on, paused, on. Paired
 * mode schedules one report per accepted capture: A/C enqueue then report,
 * while B reports to completion before enqueue. No host socket is opened, no input is sent, and no other app is
 * activated or changed. All rows are bounded in memory and printed only after
 * the timers and worker have stopped. This does not measure host delivery,
 * rendering latency, or user-visible frame rate.
 * The full CPU pixel-oracle scan occurs after capture and flush in every phase;
 * it is matched background work, excluded from the private-call interval.
 *
 * Build with the Tiger 10.4u SDK, then launch as an Aqua app with --run or
 * --paired. Paired mode reports actual timestamp overlap; enqueue ordering
 * alone is not evidence of concurrent private-call execution.
 */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
#include <mach/mach_time.h>
#include <mach/thread_info.h>
#include <mach/thread_act.h>
#include <mach/mach_port.h>
#include <mach/mach_init.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>

#define RC_W 640
#define RC_H 400
#define RC_N 30
#define RC_PHASES 3
#define RC_CAP_ROWS (RC_N*RC_PHASES)
#define RC_REPORT_ROWS 128

typedef int (*RCConnectionFn)(void);
typedef CGError (*RCBoundsFn)(int,int,CGRect *);
typedef void (*RCCaptureFn)(CGContextRef,CGRect,int,int,CGRect);
static mach_timebase_info_data_t rcTimebase;
static double rcEpoch;
static double rcNow(void) { return (double)mach_absolute_time()*rcTimebase.numer/rcTimebase.denom/1.0e9; }
static double rcThreadCPU(void)
{
    thread_basic_info_data_t info; mach_msg_type_number_t n=THREAD_BASIC_INFO_COUNT;
    thread_t self=mach_thread_self(); kern_return_t kr=thread_info(self,THREAD_BASIC_INFO,(thread_info_t)&info,&n);
    mach_port_deallocate(mach_task_self(),self);
    return kr==KERN_SUCCESS ? info.user_time.seconds+info.system_time.seconds+
        (info.user_time.microseconds+info.system_time.microseconds)/1.0e6 : -1.0;
}

@interface RCView : NSView @end
@implementation RCView
- (void)drawRect:(NSRect)dirty
{
    CGContextRef c=[[NSGraphicsContext currentContext] graphicsPort];
    CGContextSaveGState(c); CGContextSetShouldAntialias(c,false);
    CGContextSetRGBFillColor(c,1,0,0,1); CGContextFillRect(c,CGRectMake(0,0,320,200));
    CGContextSetRGBFillColor(c,0,1,0,1); CGContextFillRect(c,CGRectMake(320,0,320,200));
    CGContextSetRGBFillColor(c,0,0,1,1); CGContextFillRect(c,CGRectMake(0,200,320,200));
    CGContextSetRGBFillColor(c,1,1,0,1); CGContextFillRect(c,CGRectMake(320,200,320,200));
    int x,y;
    for(y=104;y<296;y+=8) for(x=104;x<536;x+=8) if(((x/8+y/8)&1)) {
        CGContextSetRGBFillColor(c,1,1,1,1); CGContextFillRect(c,CGRectMake(x,y,8,8));
    }
    CGContextSetRGBFillColor(c,0,0,0,1);
    CGContextFillRect(c,CGRectMake(8,8,32,32)); CGContextFillRect(c,CGRectMake(600,8,32,32));
    CGContextFillRect(c,CGRectMake(8,360,32,32)); CGContextFillRect(c,CGRectMake(600,360,32,32));
    CGContextRestoreGState(c);
}
@end

static void expectedRGB(int x,int y,unsigned char p[4])
{
    if(x<320&&y<200){p[0]=255;p[1]=0;p[2]=0;}
    else if(x>=320&&y<200){p[0]=0;p[1]=255;p[2]=0;}
    else if(x<320){p[0]=0;p[1]=0;p[2]=255;}
    else {p[0]=255;p[1]=255;p[2]=0;}
    if(x>=104&&x<536&&y>=104&&y<296&&((x/8+y/8)&1))p[0]=p[1]=p[2]=255;
    if(((x>=8&&x<40)||(x>=600&&x<632))&&((y>=8&&y<40)||(y>=360&&y<392)))p[0]=p[1]=p[2]=0;
    p[3]=255;
}
static int rcPixelErrors(const unsigned char *bytes,int flip)
{
    int x,y,k,errors=0; unsigned char want[4];
    for(y=0;y<RC_H;y++)for(x=0;x<RC_W;x++){
        expectedRGB(x,flip?RC_H-1-y:y,want);
        const unsigned char *p=bytes+((size_t)y*RC_W+x)*4;
        for(k=0;k<4;k++)if(abs((int)p[k]-(int)want[k])>1)errors++;
    }
    return errors;
}

typedef struct { int phase,sample,geometryOK,pixelErrors,cpuOK; double callStartMS,callEndMS,callMS,flushMS,wallMS,cpuMS; } RCCaptureRow;
typedef struct { int phase,sample,windowsSent; double startMS,endMS,intervalMS,wallMS,cpuMS; } RCReportRow;
@class RCManager;
static void *rcWorkerEntry(void *context);
@interface RCAgent : PEAgent { @public RCManager *manager; }
- (void)configureDiagnostic;
- (BOOL)reportMenuBarFor:(pid_t)pid;
@end

@interface RCManager : NSObject {
@public
    RCAgent *agent; NSWindow *window; NSTimer *captureTimer,*reportTimer;
    pthread_mutex_t workerMutex; pthread_cond_t workerCondition;
    BOOL jobReady,workerStop,workerStopped,outstanding,finished,pairedMode; int jobPhase,jobSample;
    int phase,capturesInPhase,windowID,connectionID,orientation,gateFailures;
    CGRect sourceGeometry; RCCaptureFn capture; RCBoundsFn bounds;
    RCCaptureRow captureRows[RC_CAP_ROWS]; int captureCount;
    RCReportRow reportRows[RC_REPORT_ROWS]; int reportCount;
    int reportCounts[RC_PHASES],windowCounts[RC_PHASES],menuAXCounts[RC_PHASES],captureSkips[RC_PHASES];
    int appScanCounts[RC_PHASES],dockScanCounts[RC_PHASES],minScanCounts[RC_PHASES];
    int pairedOverlap[RC_PHASES],pairedSerialized[RC_PHASES];
    pthread_t workerThread; BOOL workerStarted,workerJoined;
    double lastReportAt; NSString *lastWindowReport;
}
- (void)start;
- (void)reportTick:(NSTimer *)timer;
- (void)captureTick:(NSTimer *)timer;
- (void)enqueueCapture;
- (void)captureComplete:(NSDictionary *)result;
- (void)workerStoppedOnMain:(id)object;
- (void)worker:(id)object;
- (void)noteVerb:(NSString *)verb payload:(NSData *)payload;
- (void)noteMenuAX;
- (void)printResults;
@end

@implementation RCAgent
- (void)configureDiagnostic { completeCaptureMode=YES;nativeReport12=YES;sheetReportBusy=YES; }
- (void)send:(NSString *)verb data:(NSData *)payload { [manager noteVerb:verb payload:payload]; }
- (BOOL)reportMenuBarFor:(pid_t)pid { [manager noteMenuAX];return [super reportMenuBarFor:pid]; }
@end

@implementation RCManager
- (id)init
{
    if((self=[super init])){
        orientation=-1;phase=0;pthread_mutex_init(&workerMutex,NULL);pthread_cond_init(&workerCondition,NULL);
        agent=[[RCAgent alloc]init];agent->manager=self;[agent configureDiagnostic];
        window=[[NSWindow alloc]initWithContentRect:NSMakeRect(40,40,RC_W,RC_H)
            styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        [window setReleasedWhenClosed:NO];[window setOpaque:YES];
        RCView *view=[[RCView alloc]initWithFrame:NSMakeRect(0,0,RC_W,RC_H)];
        [window setContentView:view];[view release];[window orderFront:nil];[window display];[window flushWindow];
        windowID=(int)[window windowNumber];
        RCConnectionFn connection=(RCConnectionFn)dlsym(RTLD_DEFAULT,"_CGSDefaultConnection");
        if(connection)connectionID=connection();else gateFailures++;
        bounds=(RCBoundsFn)dlsym(RTLD_DEFAULT,"CGSGetScreenRectForWindow");
        capture=(RCCaptureFn)dlsym(RTLD_DEFAULT,"CGContextCopyWindowCaptureContentsToRect");
        if(!windowID||!bounds||!capture||bounds(connectionID,windowID,&sourceGeometry)!=kCGErrorSuccess||
           sourceGeometry.size.width!=RC_W||sourceGeometry.size.height!=RC_H)gateFailures++;
        lastWindowReport=[[NSString alloc]init];
    }
    return self;
}
- (void)dealloc
{
    [captureTimer invalidate];[captureTimer release];
    [reportTimer invalidate];[reportTimer release];
    [window orderOut:nil];[window release];[agent release];[lastWindowReport release];
    pthread_cond_destroy(&workerCondition);pthread_mutex_destroy(&workerMutex);
    [super dealloc];
}
- (void)start
{
    if(pthread_create(&workerThread,NULL,rcWorkerEntry,self)!=0){gateFailures++;finished=YES;return;}
    workerStarted=YES;
    captureTimer=[[NSTimer scheduledTimerWithTimeInterval:1.0/12.0 target:self selector:@selector(captureTick:) userInfo:nil repeats:YES]retain];
    if(!pairedMode)reportTimer=[[NSTimer scheduledTimerWithTimeInterval:1.0/12.0 target:self selector:@selector(reportTick:) userInfo:nil repeats:YES]retain];
}
- (void)reportTick:(NSTimer *)timer
{
    if(phase<0||phase>=RC_PHASES)return;
    if(reportCount>=RC_REPORT_ROWS){gateFailures++;[reportTimer invalidate];reportTimer=nil;return;}
    int row=reportCount++,before=windowCounts[phase];
    double cpu0=rcThreadCPU(),began=rcNow();
    RCReportRow *r=&reportRows[row];r->phase=phase;r->sample=reportCounts[phase]+1;
    r->intervalMS=lastReportAt>0?(began-lastReportAt)*1000:0;lastReportAt=began;
    [agent reportWindows:timer];
    double end=rcNow(),cpu1=rcThreadCPU();
    r->startMS=(began-rcEpoch)*1000;r->endMS=(end-rcEpoch)*1000;
    r->wallMS=(end-began)*1000;r->cpuMS=cpu0>=0&&cpu1>=cpu0?(cpu1-cpu0)*1000:-1;
    r->windowsSent=windowCounts[phase]>before;
    reportCounts[phase]++;
    if(!r->windowsSent||r->cpuMS<0)gateFailures++;
    NSString *token=[NSString stringWithFormat:@"%d,%d,%d,%d,%d,",windowID,
        (int)sourceGeometry.origin.x,(int)sourceGeometry.origin.y,RC_W,RC_H];
    if([lastWindowReport rangeOfString:token].location==NSNotFound)gateFailures++;
}
- (void)captureTick:(NSTimer *)timer
{
    if(phase<0||phase>=RC_PHASES)return;
    if(outstanding){captureSkips[phase]++;return;}
    if(capturesInPhase>=RC_N)return;
    if(pairedMode){
        if(phase==1)[self reportTick:nil];
        [self enqueueCapture];
        if(phase==0||phase==2)[self reportTick:nil];
        return;
    }
    [self enqueueCapture];
}
- (void)enqueueCapture
{
    outstanding=YES;jobPhase=phase;jobSample=capturesInPhase+1;
    pthread_mutex_lock(&workerMutex);jobReady=YES;pthread_cond_signal(&workerCondition);pthread_mutex_unlock(&workerMutex);
}
- (void)captureComplete:(NSDictionary *)result
{
    if(!outstanding||phase<0||phase>=RC_PHASES){gateFailures++;return;}
    if(captureCount>=RC_CAP_ROWS){gateFailures++;outstanding=NO;return;}
    int row=captureCount++;
    RCCaptureRow *r=&captureRows[row];
    r->phase=[[result objectForKey:@"phase"]intValue];r->sample=[[result objectForKey:@"sample"]intValue];
    r->geometryOK=[[result objectForKey:@"geometry"]boolValue];r->pixelErrors=[[result objectForKey:@"pixels"]intValue];
    r->callMS=[[result objectForKey:@"call"]doubleValue];r->flushMS=[[result objectForKey:@"flush"]doubleValue];
    r->wallMS=[[result objectForKey:@"wall"]doubleValue];r->cpuMS=[[result objectForKey:@"cpu"]doubleValue];r->cpuOK=[[result objectForKey:@"cpuOK"]boolValue];
    r->callStartMS=[[result objectForKey:@"callStart"]doubleValue];r->callEndMS=[[result objectForKey:@"callEnd"]doubleValue];
    outstanding=NO;
    if(!r->geometryOK||r->pixelErrors||!r->cpuOK||r->phase!=phase||r->sample!=capturesInPhase+1)gateFailures++;
    capturesInPhase++;
    if(capturesInPhase==RC_N){
        if(reportTimer){[reportTimer invalidate];[reportTimer release];reportTimer=nil;}
        phase++;
        if(phase==1){lastReportAt=0;}
        else if(phase==2){lastReportAt=0;if(!pairedMode)reportTimer=[[NSTimer scheduledTimerWithTimeInterval:1.0/12.0 target:self selector:@selector(reportTick:) userInfo:nil repeats:YES]retain];}
        capturesInPhase=0;
        if(phase==RC_PHASES){
            [captureTimer invalidate];[captureTimer release];captureTimer=nil;
            pthread_mutex_lock(&workerMutex);workerStop=YES;pthread_cond_signal(&workerCondition);pthread_mutex_unlock(&workerMutex);
        }
    }
}
- (void)worker:(id)object
{
    NSAutoreleasePool *outer=[[NSAutoreleasePool alloc]init];
    for(;;){
        NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
        pthread_mutex_lock(&workerMutex);while(!jobReady&&!workerStop)pthread_cond_wait(&workerCondition,&workerMutex);
        if(workerStop){pthread_mutex_unlock(&workerMutex);[pool drain];break;}
        int p=jobPhase,s=jobSample;jobReady=NO;pthread_mutex_unlock(&workerMutex);
        size_t stride=RC_W*4,length=stride*RC_H;
        NSMutableData *data=[[NSMutableData alloc]initWithLength:length];
        CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx=CGBitmapContextCreate([data mutableBytes],RC_W,RC_H,8,stride,cs,kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(cs);int geometryOK=0,pixelErrors=0,cpuOK=1;double callStartMS=-1,callEndMS=-1,callMS=-1,flushMS=-1,wallMS=-1,cpuMS=-1;
        CGRect before,after;geometryOK=ctx&&bounds(connectionID,windowID,&before)==kCGErrorSuccess&&CGRectEqualToRect(sourceGeometry,before);
        if(ctx&&geometryOK){
            double w0=rcNow(),c0=rcThreadCPU(),a=rcNow();
            capture(ctx,CGRectMake(0,0,RC_W,RC_H),connectionID,windowID,CGRectMake(0,0,RC_W,RC_H));
            double b=rcNow();CGContextFlush(ctx);double c=rcNow(),c1=rcThreadCPU();
            callMS=(b-a)*1000;flushMS=(c-b)*1000;wallMS=(c-w0)*1000;
            callStartMS=(a-rcEpoch)*1000;callEndMS=(b-rcEpoch)*1000;
            if(c0<0||c1<c0)cpuOK=0;else cpuMS=(c1-c0)*1000;
            geometryOK=bounds(connectionID,windowID,&after)==kCGErrorSuccess&&CGRectEqualToRect(sourceGeometry,after);
            const unsigned char *bytes=[data bytes];
            if(orientation<0){int e0=rcPixelErrors(bytes,0),e1=rcPixelErrors(bytes,1);orientation=e1<e0?1:0;pixelErrors=e1<e0?e1:e0;}
            else pixelErrors=rcPixelErrors(bytes,orientation);
        }else{geometryOK=0;cpuOK=0;pixelErrors=INT_MAX;}
        if(ctx)CGContextRelease(ctx);[data release];
        NSDictionary *row=[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:p],@"phase",
            [NSNumber numberWithInt:s],@"sample",[NSNumber numberWithBool:geometryOK],@"geometry",
            [NSNumber numberWithInt:pixelErrors],@"pixels",[NSNumber numberWithBool:cpuOK],@"cpuOK",
            [NSNumber numberWithDouble:callMS],@"call",[NSNumber numberWithDouble:flushMS],@"flush",
            [NSNumber numberWithDouble:wallMS],@"wall",[NSNumber numberWithDouble:cpuMS],@"cpu",
            [NSNumber numberWithDouble:callStartMS],@"callStart",[NSNumber numberWithDouble:callEndMS],@"callEnd",nil];
        [self performSelectorOnMainThread:@selector(captureComplete:) withObject:row waitUntilDone:YES];
        [pool drain];
    }
    [self performSelectorOnMainThread:@selector(workerStoppedOnMain:) withObject:nil waitUntilDone:YES];
    [outer drain];
}
- (void)workerStoppedOnMain:(id)object
{
    workerStopped=YES;finished=YES;
}
- (void)noteVerb:(NSString *)verb payload:(NSData *)payload
{
    if(phase<0||phase>=RC_PHASES)return;
    if([verb isEqualToString:@"WINDOWS"]){
        windowCounts[phase]++;[lastWindowReport release];lastWindowReport=[[NSString alloc]initWithData:payload encoding:NSUTF8StringEncoding];
    }else if([verb isEqualToString:@"WINAPPS"])appScanCounts[phase]++;
    else if([verb isEqualToString:@"DOCKAPPS"])dockScanCounts[phase]++;
    else if([verb isEqualToString:@"MINWINDOWS"])minScanCounts[phase]++;
}
- (void)noteMenuAX
{
    if(phase>=0&&phase<RC_PHASES)menuAXCounts[phase]++;
}
- (void)printResults
{
    printf("fixture_window=%d source=%dx%d mode=%s phases=%s capture_rate_target_hz=12 report_rate_target_hz=12\n",windowID,RC_W,RC_H,pairedMode?"paired-order":"baseline",pairedMode?"A(enqueue-then-report),B(report-then-enqueue),C(enqueue-then-report)":"A(report),B(paused),C(report)");
    printf("phase name captures skippedCaptureTicks reportTicks appScanPayloads dockPayloads minWindowPayloads topMenuAXAttempts\n");
    const char *names[]={"A","B","C"};int p;
    for(p=0;p<RC_PHASES;p++){
        int n=0,j;for(j=0;j<captureCount;j++)if(captureRows[j].phase==p)n++;
        printf("%d %s %d %d %d %d %d %d %d\n",p,names[p],n,captureSkips[p],reportCounts[p],appScanCounts[p],dockScanCounts[p],minScanCounts[p],menuAXCounts[p]);
    }
    printf("capture phase sample call_start_ms call_end_ms call_ms flush_ms wall_ms thread_cpu_ms pixel_errors geometry\n");
    int i;for(i=0;i<captureCount;i++){RCCaptureRow *r=&captureRows[i];
        printf("%d %d %.3f %.3f %.3f %.3f %.3f %.3f %d %s\n",r->phase,r->sample,r->callStartMS,r->callEndMS,r->callMS,r->flushMS,r->wallMS,r->cpuMS,r->pixelErrors,r->geometryOK?"stable":"failed");}
    printf("report phase sample report_start_ms report_end_ms interval_ms wall_ms main_thread_cpu_ms windowsSent\n");
    for(i=0;i<reportCount;i++){RCReportRow *r=&reportRows[i];
        printf("%d %d %.3f %.3f %.3f %.3f %.3f %d\n",r->phase,r->sample,r->startMS,r->endMS,r->intervalMS,r->wallMS,r->cpuMS,r->windowsSent);}
    if(pairedMode){
        int p,j;for(p=0;p<RC_PHASES;p++)for(j=0;j<captureCount;j++)if(captureRows[j].phase==p){
            int k;for(k=0;k<reportCount;k++)if(reportRows[k].phase==p&&reportRows[k].sample==captureRows[j].sample){
                if(captureRows[j].callStartMS<reportRows[k].endMS&&reportRows[k].startMS<captureRows[j].callEndMS)pairedOverlap[p]++;
                else pairedSerialized[p]++;
                break;
            }
        }
        printf("paired_interval_matches phase overlap serialized\n");
        for(p=0;p<RC_PHASES;p++)printf("%d %d %d\n",p,pairedOverlap[p],pairedSerialized[p]);
    }
    printf("gates failures=%d captures=%d reports=%d workerStopped=%d workerJoined=%d timersStopped=%d sheetWorker=suppressed pixelVerification=matched-afterCaptureAndFlush orientation=%s\n",gateFailures,captureCount,reportCount,workerStopped,workerJoined,captureTimer==nil&&reportTimer==nil,orientation==1?"vertical-flip":"direct");
}
@end

static void *rcWorkerEntry(void *context)
{
    RCManager *run=(RCManager *)context;
    [run worker:nil];
    return NULL;
}

static int rcCompletionStatus(int paired,int failures,int captures,int stopped,int joined,
    int reports,const int reportCounts[RC_PHASES],const int phaseCaptures[RC_PHASES],
    const int overlaps[RC_PHASES],const int serialized[RC_PHASES])
{
    int p;
    if(failures||captures!=RC_CAP_ROWS||!stopped||!joined)return 1;
    if(paired){
        if(reports!=RC_CAP_ROWS)return 1;
        for(p=0;p<RC_PHASES;p++)if(reportCounts[p]!=RC_N||phaseCaptures[p]!=RC_N||
            overlaps[p]+serialized[p]!=RC_N)return 1;
        if(overlaps[0]==0||overlaps[1]!=0||serialized[1]!=RC_N||overlaps[2]==0)return 1;
    }else{
        if(reports==0||reportCounts[0]==0||reportCounts[1]!=0||reportCounts[2]==0)return 1;
        for(p=0;p<RC_PHASES;p++)if(phaseCaptures[p]!=RC_N)return 1;
    }
    return 0;
}

static int rcGateSelfTest(void)
{
    int rc=0,baseReports[RC_PHASES]={12,0,11},pairReports[RC_PHASES]={30,30,30};
    int caps[RC_PHASES]={30,30,30},overlap[RC_PHASES]={19,0,18},serial[RC_PHASES]={11,30,12};
    int badReports[RC_PHASES]={30,29,30},badOverlap[RC_PHASES]={19,1,18},badSerial[RC_PHASES]={10,30,11};
    if(rcCompletionStatus(0,0,RC_CAP_ROWS,1,1,23,baseReports,caps,overlap,serial)!=0)rc++;
    if(rcCompletionStatus(1,0,RC_CAP_ROWS,1,1,RC_CAP_ROWS,pairReports,caps,overlap,serial)!=0)rc++;
    if(rcCompletionStatus(1,0,RC_CAP_ROWS,1,1,RC_CAP_ROWS,badReports,caps,overlap,serial)==0)rc++;
    if(rcCompletionStatus(1,0,RC_CAP_ROWS,1,1,RC_CAP_ROWS,pairReports,caps,badOverlap,badSerial)==0)rc++;
    if(rcCompletionStatus(1,0,RC_CAP_ROWS,1,1,RC_CAP_ROWS,pairReports,caps,overlap,(int[RC_PHASES]){10,30,11})==0)rc++;
    printf("gate_selftest cases=5 failures=%d\n",rc);return rc?1:0;
}

int main(int argc,const char **argv)
{
    if(argc==2&&!strcmp(argv[1],"--gate-selftest"))return rcGateSelfTest();
    if(argc!=2||(strcmp(argv[1],"--run")&&strcmp(argv[1],"--paired"))){fprintf(stderr,"usage: pereportcapturecheck --run|--paired|--gate-selftest (launch run modes from Aqua)\n");return 2;}
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];NSApplicationLoad();signal(SIGALRM,SIG_DFL);alarm(60);
    if(mach_timebase_info(&rcTimebase)!=KERN_SUCCESS||!rcTimebase.denom)return 3;
    unsetenv("POWEREMU_CAPTURE_PROFILE");unsetenv("PE_CAPTURE_REPORT_OCCLUDERS");
    unsetenv("PE_FOCUS_ASYNC");unsetenv("PE_MENU_ITEMS_ASYNC");
    RCManager *run=[[RCManager alloc]init];
    run->pairedMode=!strcmp(argv[1],"--paired");
    if(run->gateFailures){fprintf(stderr,"UNAVAILABLE: fixture window or private capture APIs unavailable\n");[run release];alarm(0);[pool drain];return 4;}
    rcEpoch=rcNow();[run start];
    while(!run->finished)[[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    if(run->workerStarted){pthread_join(run->workerThread,NULL);run->workerJoined=YES;}
    [run printResults];int phaseCaptures[RC_PHASES]={0,0,0},i;
    for(i=0;i<run->captureCount;i++)if(run->captureRows[i].phase>=0&&run->captureRows[i].phase<RC_PHASES)phaseCaptures[run->captureRows[i].phase]++;
    int status=rcCompletionStatus(run->pairedMode,run->gateFailures,run->captureCount,run->workerStopped,run->workerJoined,
        run->reportCount,run->reportCounts,phaseCaptures,run->pairedOverlap,run->pairedSerialized);
    alarm(0);[run release];[pool drain];return status;
}
