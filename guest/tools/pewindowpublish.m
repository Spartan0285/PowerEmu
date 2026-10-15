/* Default-off cooperative publication experiment. Owns only two fixture
 * windows; never reads another app or changes its focus/input. Launch this
 * test app from Aqua after writing /tmp/pe-publish-config: PORT NONCE. */
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include "../src/PEPixelPack.h"
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
static mach_timebase_info_data_t timebase;
static double monotonic(void) { return (double)mach_absolute_time()*timebase.numer/timebase.denom/1e9; }
#include <dlfcn.h>
#include <unistd.h>
#include <errno.h>

static double cpuSeconds(void) {
    thread_basic_info_data_t info; mach_msg_type_number_t n=THREAD_BASIC_INFO_COUNT;
    thread_t thread=mach_thread_self();
    kern_return_t result=thread_info(thread,THREAD_BASIC_INFO,(thread_info_t)&info,&n);
    mach_port_deallocate(mach_task_self(),thread);
    return result==KERN_SUCCESS ? info.user_time.seconds+info.system_time.seconds+
        (info.user_time.microseconds+info.system_time.microseconds)/1000000.0 : -1;
}
static BOOL put(int fd,const void *data,size_t size) {
    const char *p=data;
    while(size) { ssize_t n=write(fd,p,size);if(n<0&&errno==EINTR)continue;if(n<=0)return NO;p+=n;size-=n; }
    return YES;
}
@interface PublishView:NSView { @public NSData *pixels; unsigned width,height; }
@end
@implementation PublishView
- (void)drawRect:(NSRect)r {
    if(!pixels)return;
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((CFDataRef)pixels);
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGImageRef image=CGImageCreate(width,height,8,32,width*4,color,kCGImageAlphaPremultipliedLast,provider,NULL,false,kCGRenderingIntentDefault);
    CGContextRef context=[[NSGraphicsContext currentContext] graphicsPort];
    CGContextSetInterpolationQuality(context,kCGInterpolationNone);
    NSRect bounds=[self bounds];
    CGContextDrawImage(context,CGRectMake(bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height),image);
    CGImageRelease(image);CGColorSpaceRelease(color);CGDataProviderRelease(provider);
}
@end
@interface Publisher:NSObject {
    NSWindow *window,*cover;PublishView *view;NSTimer *timer;NSConditionLock *lock;
    NSArray *pending;BOOL done;unsigned generation,produced,replaced,sent,errors;
    int port;NSString *nonce;unsigned workerErrors,referenceCount;
    struct {unsigned seq,bytes;double ms;} pushes[240];
    struct {double generation,display,flush;} timings[240];
    struct {unsigned seq,w,h,differences,flipped;double call,flush,cpu,draw;} references[6];
}
- (void)tick:(NSTimer *)timer;
- (void)worker:(id)unused;
- (void)finish:(id)unused;
@end
@implementation Publisher
- (id)init {
    if(!(self=[super init]))return nil;
    NSString *config=[NSString stringWithContentsOfFile:@"/tmp/pe-publish-config" encoding:NSUTF8StringEncoding error:NULL];
    NSArray *fields=[[config stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@" "];
    if([fields count]!=2 || (port=[[fields objectAtIndex:0] intValue])<1024 || port>65535 || [[fields objectAtIndex:1] length]!=32)exit(2);
    nonce=[[fields objectAtIndex:1] copy];lock=[[NSConditionLock alloc] initWithCondition:0];
    NSRect rect=NSMakeRect(100,200,615,407);
    window=[[NSWindow alloc] initWithContentRect:rect styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO];[window setLevel:NSFloatingWindowLevel];
    view=[[PublishView alloc] initWithFrame:NSMakeRect(0,0,615,407)];[window setContentView:view];[window orderFront:nil];
    cover=[[NSWindow alloc] initWithContentRect:NSInsetRect(rect,-30,-30) styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    [cover setReleasedWhenClosed:NO];[cover setLevel:NSFloatingWindowLevel+1];[cover setBackgroundColor:[NSColor grayColor]];
    [NSThread detachNewThreadSelector:@selector(worker:) toTarget:self withObject:nil];
    timer=[[NSTimer scheduledTimerWithTimeInterval:1.0/30 target:self selector:@selector(tick:) userInfo:nil repeats:YES] retain];
    [self performSelector:@selector(finish:) withObject:@"deadline" afterDelay:25];
    return self;
}
- (void)tick:(NSTimer *)unused {
    if(generation>=240) { [timer invalidate];[lock lock];done=YES;[lock unlockWithCondition:1];return; }
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];unsigned seq=++generation;
    if(seq==81)[cover orderFront:nil];
    if(seq==161) { [cover orderOut:nil];[window setContentSize:NSMakeSize(512,320)]; }
    unsigned w=seq<=160?615:512,h=seq<=160?407:320,x,y;
    CFAbsoluteTime began=monotonic();
    NSMutableData *data=[NSMutableData dataWithLength:w*h*4];unsigned char *p=[data mutableBytes];
    for(y=0;y<h;y++)for(x=0;x<w;x++) {
        unsigned at=(y*w+x)*4;
        p[at]=((x/32+seq)&1)?255:0;p[at+1]=((y/32+seq/2)&1)?255:0;
        p[at+2]=((x/64+y/64+seq/3)&1)?255:0;p[at+3]=255;
    }
    NSData *immutable=[[data copy] autorelease];[view->pixels release];view->pixels=[immutable retain];view->width=w;view->height=h;
    CFAbsoluteTime generated=monotonic();
    [view setNeedsDisplay:YES];[window displayIfNeeded];CFAbsoluteTime displayed=monotonic();[window flushWindow];
    CFAbsoluteTime committed=monotonic();
    timings[seq-1].generation=(generated-began)*1000;timings[seq-1].display=(displayed-generated)*1000;timings[seq-1].flush=(committed-displayed)*1000;
    NSArray *job=[NSArray arrayWithObjects:immutable,[NSNumber numberWithUnsignedInt:seq],[NSNumber numberWithUnsignedInt:w],
        [NSNumber numberWithUnsignedInt:h],[NSNumber numberWithDouble:committed],nil];
    [lock lock];if(pending)replaced++;[pending release];pending=[job retain];produced++;[lock unlockWithCondition:1];
    if(seq%40==0) {
        typedef void (*Capture)(CGContextRef,CGRect,int,int,CGRect);
        typedef int (*Connection)(void);
        Capture capture=(Capture)dlsym(RTLD_DEFAULT,"CGContextCopyWindowCaptureContentsToRect");
        Connection connection=(Connection)dlsym(RTLD_DEFAULT,"_CGSDefaultConnection");
        NSMutableData *reference=[NSMutableData dataWithLength:w*h*4];CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
        CGContextRef context=CGBitmapContextCreate([reference mutableBytes],w,h,8,w*4,color,kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(color);
        if(capture&&connection&&context) {
            double cpu=cpuSeconds();CFAbsoluteTime a=monotonic();
            capture(context,CGRectMake(0,0,w,h),connection(),[window windowNumber],CGRectMake(0,0,w,h));CFAbsoluteTime b=monotonic();
            CGContextFlush(context);CFAbsoluteTime c=monotonic();double used=cpuSeconds();
            unsigned differences=0,flipped=0,i;const unsigned char *bytes=[reference bytes];
            for(i=0;i<w*h*4;i++) {if(bytes[i]!=p[i])differences++;unsigned row=i/(w*4),col=i%(w*4);if(bytes[i]!=p[(h-1-row)*w*4+col])flipped++;}
            if(referenceCount<6) {
                unsigned n=referenceCount++;references[n].seq=seq;references[n].w=w;references[n].h=h;
                references[n].differences=differences;references[n].flipped=flipped;
                references[n].call=(b-a)*1000;references[n].flush=(c-b)*1000;
                references[n].cpu=cpu>=0&&used>=0?(used-cpu)*1000:-1;references[n].draw=(committed-began)*1000;
            } else errors++;
            if(differences && flipped) errors++;
        } else errors++;
        if(context)CGContextRelease(context);
    }
    [pool drain];
}
- (void)worker:(id)unused {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    int fd=socket(AF_INET,SOCK_STREAM,0),one=1;struct timeval timeout={3,0};
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof one);setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof one);
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout);setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof timeout);
    struct sockaddr_in address;memset(&address,0,sizeof address);address.sin_len=sizeof address;address.sin_family=AF_INET;
    address.sin_port=htons(port);address.sin_addr.s_addr=inet_addr("10.0.2.2");
    if(fd<0||connect(fd,(struct sockaddr*)&address,sizeof address)) {workerErrors++;goto end;}
    {NSString *hello=[NSString stringWithFormat:@"PUBLISHHELLO %@\n",nonce];if(!put(fd,[hello UTF8String],[hello length])) {workerErrors++;goto end;}}
    for(;;) {
        NSAutoreleasePool *itemPool=[[NSAutoreleasePool alloc] init];
        [lock lockWhenCondition:1];NSArray *job=pending;pending=nil;BOOL ended=done;[lock unlockWithCondition:0];
        if(!job) { [itemPool drain];if(ended)break;continue; }
        NSData *pixels=[job objectAtIndex:0];unsigned seq=[[job objectAtIndex:1] unsignedIntValue],w=[[job objectAtIndex:2] unsignedIntValue],h=[[job objectAtIndex:3] unsignedIntValue];
        NSMutableData *packed=[NSMutableData dataWithLength:[pixels length]*2];size_t length=PEPixelPack([pixels bytes],w*h,[packed mutableBytes],[packed length]);
        if(length)[packed setLength:length];
        NSMutableData *payload=[NSMutableData dataWithData:[[NSString stringWithFormat:@"1 %u %u %d %u\n",w,h,length?3:0,seq] dataUsingEncoding:NSASCIIStringEncoding]];
        [payload appendData:length?packed:pixels];NSString *head=[NSString stringWithFormat:@"FRAME %u\n",(unsigned)[payload length]];
        BOOL ok=put(fd,[head UTF8String],[head length])&&put(fd,[payload bytes],[payload length]);
        char ack[80];unsigned n=0;while(ok&&n<sizeof ack-1) {ssize_t got=read(fd,ack+n,1);if(got<0&&errno==EINTR)continue;if(got!=1){ok=NO;break;}if(ack[n++]=='\n')break;}
        ack[n]=0;unsigned accepted=0;if(!ok||sscanf(ack,"ACK %u",&accepted)!=1||accepted!=seq){workerErrors++;[job release];[itemPool drain];break;}
        if(sent<240) {pushes[sent].seq=seq;pushes[sent].bytes=[payload length];pushes[sent].ms=(monotonic()-[[job objectAtIndex:4] doubleValue])*1000;sent++;}
        else workerErrors++;
        [job release];[itemPool drain];if(ended)break;
    }
end:
    if(fd>=0)close(fd);
    [self performSelectorOnMainThread:@selector(finish:) withObject:@"worker" waitUntilDone:NO];[pool drain];
}
- (void)finish:(id)unused {
    [timer invalidate];[cover orderOut:nil];[window orderOut:nil];
    if(![unused isEqual:@"worker"] || produced!=240 || sent+replaced!=produced || referenceCount!=6)errors++;
    unsigned i;
    for(i=0;i<produced;i++)fprintf(stderr,"DRAW seq=%u generationMS=%.3f displayMS=%.3f flushMS=%.3f\n",i+1,timings[i].generation,timings[i].display,timings[i].flush);
    for(i=0;i<sent;i++)fprintf(stderr,"PUSH seq=%u ackMS=%.3f bytes=%u\n",pushes[i].seq,pushes[i].ms,pushes[i].bytes);
    for(i=0;i<referenceCount;i++)fprintf(stderr,"REFERENCE seq=%u covered=%d size=%ux%u captureMS=%.3f flushMS=%.3f cpuMS=%.3f mismatch=%u flippedMismatch=%u drawMS=%.3f\n",
        references[i].seq,references[i].seq>80&&references[i].seq<=160,references[i].w,references[i].h,references[i].call,references[i].flush,references[i].cpu,references[i].differences,references[i].flipped,references[i].draw);
    fprintf(stderr,"SUMMARY produced=%u sent=%u replaced=%u errors=%u workerErrors=%u references=%u\n",produced,sent,replaced,errors,workerErrors,referenceCount);fflush(stderr);exit(errors||workerErrors?1:0);
}
@end
int main(void) {
    mach_timebase_info(&timebase);freopen("/tmp/pe-publish.log","w",stderr);NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];Publisher *publisher=[[Publisher alloc] init];[NSApp run];[publisher release];[pool drain];return 0;
}
