/* Standalone Tiger experiment. Owns two temporary test windows only; never
 * controls another application. Compare actual backing-store pixels with
 * screen-refresh hints under visible, covered and stationary workloads. */
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
static CGRect target;
static unsigned callbacks, hits;
static void refreshed(CGRectCount count, const CGRect *rects, void *context) {
    unsigned i;
    callbacks++;
    for (i=0; i<count; i++) if (CGRectIntersectsRect(target, rects[i])) { hits++; break; }
}
static void pump(double duration) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:duration];
    while ([end timeIntervalSinceNow] > 0) {
        NSEvent *event = [NSApp nextEventMatchingMask:NSAnyEventMask untilDate:end
                            inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event) [NSApp sendEvent:event];
    }
}
@interface PERefreshView : NSView { @public int tick; }
@end
@implementation PERefreshView
- (void)drawRect:(NSRect)rect {
    [[NSColor colorWithCalibratedRed:(tick%2 ? 0.8 : 0.1) green:0.2 blue:0.3 alpha:1] set];
    NSRectFill([self bounds]);
}
@end
int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    typedef int (*Connection)(void);
    typedef int (*Bounds)(int,int,CGRect *);
    typedef void (*Capture)(CGContextRef,CGRect,int,int,CGRect);
    Connection connection = (Connection)dlsym(RTLD_DEFAULT,"_CGSDefaultConnection");
    Bounds bounds = (Bounds)dlsym(RTLD_DEFAULT,"CGSGetScreenRectForWindow");
    Capture capture = (Capture)dlsym(RTLD_DEFAULT,"CGContextCopyWindowCaptureContentsToRect");
    if (!connection || !bounds || !capture) return 2;
    NSRect area=NSMakeRect(100,200,256,160);
    NSWindow *window=[[NSWindow alloc] initWithContentRect:area styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    PERefreshView *view=[[PERefreshView alloc] initWithFrame:NSMakeRect(0,0,256,160)];
    [window setContentView:view]; [window setLevel:NSFloatingWindowLevel]; [window orderFront:nil]; [window display];
    NSWindow *cover=[[NSWindow alloc] initWithContentRect:NSInsetRect(area,-30,-30) styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    [cover setLevel:NSFloatingWindowLevel+1]; [cover setBackgroundColor:[NSColor grayColor]];
    int cid=connection(),wid=[window windowNumber];
    if (bounds(cid,wid,&target)) return 3;
    // On Tiger the return code is undefined; validate actual delivery instead.
    CGRegisterScreenRefreshCallback(refreshed,NULL);
    pump(1);
    size_t size=256*160*4;
    unsigned char *pixels=calloc(1,size), *previous=calloc(1,size);
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap=CGBitmapContextCreate(pixels,256,160,8,256*4,color,kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(color);
    int phase, i;
    const char *names[]={"visible-changing","covered-changing","visible-idle"};
    for(phase=0;phase<3;phase++) {
        if(phase==1) { [cover orderFront:nil]; [cover display]; }
        else [cover orderOut:nil];
        pump(1);
        unsigned changed=0, missed=0, hints=0, all=0;
        memset(previous,0,size);
        for(i=0;i<30;i++) {
            callbacks=hits=0;
            if(phase!=2) { view->tick++; [view setNeedsDisplay:YES]; [window display]; }
            pump(0.1);
            memset(pixels,0,size);
            capture(bitmap,CGRectMake(0,0,256,160),cid,wid,CGRectMake(0,0,256,160));
            CGContextFlush(bitmap);
            pump(0.03);
            if(i>0 && memcmp(previous,pixels,size)) { changed++; if(!hits) missed++; }
            if(hits) hints++;
            all+=callbacks;
            memcpy(previous,pixels,size);
        }
        printf("phase=%s changed=%u missed_changes=%u hinted_samples=%u callbacks=%u samples=30\n",names[phase],changed,missed,hints,all);fflush(stdout);
    }
    CGUnregisterScreenRefreshCallback(refreshed,NULL);
    CGContextRelease(bitmap);free(pixels);free(previous);
    [cover orderOut:nil];[window orderOut:nil];[cover release];[window release];[view release];
    [pool drain];return 0;
}
