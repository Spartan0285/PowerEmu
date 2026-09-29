/* Isolated guest integration: actual PEAgent capture/encoding, own test window.
 * Emits length-prefixed triples: independent base, candidate, full reference. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
#include <stdio.h>
@interface PETileTestView : NSView { @public NSImage *pattern; int tick; }
@end
@implementation PETileTestView
- (void)drawRect:(NSRect)r {
    [pattern drawInRect:[self bounds] fromRect:NSZeroRect operation:NSCompositeCopy fraction:1];
    [[NSColor colorWithCalibratedRed:(tick%2?0.8:0.2) green:0.3 blue:0.4 alpha:1] set];
    NSRectFill(NSMakeRect(97,93,12,10));
}
@end
static void writePacket(FILE *f,NSData *data) {
    unsigned char bytes[4];PETilePut32(bytes,[data length]);
    assert(fwrite(bytes,1,4,f)==4);assert(fwrite([data bytes],1,[data length],f)==[data length]);
}
int main(int argc,char **argv) {
    if(argc!=2)return 2;
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    PEAgent *agent=[[PEAgent alloc] init];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(120,220,640,480)
        styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    PETileTestView *view=[[PETileTestView alloc] initWithFrame:NSMakeRect(0,0,640,480)];
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:640 pixelsHigh:480
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:640*4 bitsPerPixel:32];
    unsigned char *pixels=[bitmap bitmapData];unsigned i;uint32_t rng=47;
    for(i=0;i<640*480*4;i++){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;pixels[i]=(i%4==3)?255:rng;}
    view->pattern=[[NSImage alloc] initWithSize:NSMakeSize(640,480)];[view->pattern addRepresentation:bitmap];
    [window setContentView:view];[window setLevel:NSFloatingWindowLevel];[window orderFront:nil];[window display];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    FILE *f=fopen(argv[1],"wb");assert(f);int seq=1,run,wid=[window windowNumber];
    for(run=0;run<14;run++) {
        NSAutoreleasePool *iteration=[[NSAutoreleasePool alloc] init];
        int baseSeq=seq++;
        NSData *base=[agent captureWindow:[NSString stringWithFormat:@"%d %d 0 rle32 tiles32",wid,baseSeq]];
        view->tick++;[view setNeedsDisplay:YES];[window display];
        if(run==10) { // Dense update: must fall back to a complete image.
            for(i=0;i<640*480*4;i++)if(i%4!=3)pixels[i]^=255;
            [view->pattern recache];[view setNeedsDisplay:YES];[window display];
        }
        if(run==11) [window setContentSize:NSMakeSize(633,477)];
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
        NSString *request=[NSString stringWithFormat:@"%d %d %d rle32%@",wid,seq++,run==12?baseSeq-1:baseSeq,run==13?@"":@" tiles32"];
        NSData *candidate=[agent captureWindow:request];
        double candidateMS=(CFAbsoluteTimeGetCurrent()-start)*1000;
        start=CFAbsoluteTimeGetCurrent();
        NSData *reference=[agent captureWindow:[NSString stringWithFormat:@"%d %d 0 rle32",wid,seq++]];
        double fullMS=(CFAbsoluteTimeGetCurrent()-start)*1000;
        writePacket(f,base);writePacket(f,candidate);writePacket(f,reference);
        int id,w,h,encoding,reply;sscanf([candidate bytes],"%d %d %d %d %d",&id,&w,&h,&encoding,&reply);
        printf("run=%d encoding=%d candidateMS=%.3f candidateBytes=%lu fullMS=%.3f fullBytes=%lu\n",run,encoding,candidateMS,(unsigned long)[candidate length],fullMS,(unsigned long)[reference length]);fflush(stdout);
        [iteration drain];
    }
    fclose(f);[window orderOut:nil];[window release];[view->pattern release];[bitmap release];[view release];[agent release];[pool drain];return 0;
}
