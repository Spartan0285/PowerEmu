#import <Cocoa/Cocoa.h>
#include <unistd.h>
#include <signal.h>

/*
 * Standalone Harmony pixel-latency source fixture.
 *
 * Host decode format (CGImage, any row orientation): locate a horizontal row
 * whose eight equal-width cell-center samples match magic A6 or 59. The magic
 * strip is 24 content points high at the bottom of the 640x400 content view;
 * A6 means even counter, 59 means odd counter. Read the eight counter cells at
 * the same x centers, 200 image pixels inward from that row. Try both row
 * directions and accept the one whose counter row is in bounds. Cells are
 * ordered left-to-right, most-significant bit first. A black sample is 1,
 * white is 0. For odd counters, XOR the sampled byte with FF to recover the
 * counter (the body polarity flips each click so all eight bands change).
 * Ignore titlebar pixels: magic is searched across the immutable CGImage.
 * Each band is 80 points wide; the host should sample cell centers away from
 * antialiased edges. Initial visible counter is 0. Clicks advance to 255 and
 * then remain there. No guest application is launched or controlled.
 */

@interface PEPixelLatencyView : NSView
{
    unsigned char counter;
}
- (void)drawRect:(NSRect)dirtyRect;
- (void)mouseDown:(NSEvent *)event;
@end

@implementation PEPixelLatencyView

- (void)drawRect:(NSRect)dirtyRect
{
    NSRect bounds = [self bounds];
    float cellWidth = bounds.size.width / 8.0;
    int parity = counter & 1;
    int i;
    (void)dirtyRect;

    /* Eight full-height bands carry the click counter, MSB at the left. */
    for (i = 0; i < 8; i++) {
        int bit = (counter >> (7 - i)) & 1;
        int displayed = bit ^ parity;
        [[NSColor colorWithCalibratedWhite:(displayed ? 0.0 : 1.0) alpha:1.0] set];
        NSRectFill(NSMakeRect(bounds.origin.x + i * cellWidth,
                              bounds.origin.y,
                              (i == 7) ? bounds.size.width - i * cellWidth : cellWidth,
                              bounds.size.height));
    }

    /* Separate, fixed-height magic strip; its value encodes body polarity. */
    {
        unsigned char magic = parity ? 0x59 : 0xA6;
        float stripHeight = 24.0;
        for (i = 0; i < 8; i++) {
            int bit = (magic >> (7 - i)) & 1;
            [[NSColor colorWithCalibratedWhite:(bit ? 0.0 : 1.0) alpha:1.0] set];
            NSRectFill(NSMakeRect(bounds.origin.x + i * cellWidth,
                                  bounds.origin.y,
                                  (i == 7) ? bounds.size.width - i * cellWidth : cellWidth,
                                  stripHeight));
        }
    }
}

- (void)mouseDown:(NSEvent *)event
{
    (void)event;
    if (counter == 255) return;
    counter++;
    [self setNeedsDisplay:YES];
    /* Synchronous AppKit draw: do not wait for an animation/timer callback. */
    [self displayIfNeeded];
}

@end

@interface PEPixelLatencyApp : NSObject 
{
    NSWindow *window;
    PEPixelLatencyView *patternView;
    NSTimer *exitTimer;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)windowWillClose:(NSNotification *)notification;
- (void)exitAfterBound:(NSTimer *)timer;
@end

@implementation PEPixelLatencyApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(160, 120, 640, 400)
                                          styleMask:(NSTitledWindowMask | NSClosableWindowMask |
                                                     NSMiniaturizableWindowMask)
                                            backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"PowerEmu Pixel Latency"];
    [window setDelegate:self];
    patternView = [[PEPixelLatencyView alloc] initWithFrame:NSMakeRect(0, 0, 640, 400)];
    [window setContentView:patternView];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [patternView setNeedsDisplay:YES];
    [patternView displayIfNeeded];

    /* Graceful exit at 179s; alarm is a hard bound if the UI loop stalls. */
    exitTimer = [[NSTimer scheduledTimerWithTimeInterval:179.0
                                                  target:self
                                                selector:@selector(exitAfterBound:)
                                                userInfo:nil repeats:NO] retain];
}

- (void)windowWillClose:(NSNotification *)notification
{
    (void)notification;
    [NSApp terminate:nil];
}

- (void)exitAfterBound:(NSTimer *)timer
{
    (void)timer;
    [NSApp terminate:nil];
}

- (void)dealloc
{
    [exitTimer invalidate];
    [exitTimer release];
    [patternView release];
    [window release];
    [super dealloc];
}

@end

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    PEPixelLatencyApp *delegate;
    (void)argc;
    (void)argv;

    /* SIGALRM fallback bounds process lifetime if the UI loop stalls. */
    alarm(180);
    [NSApplication sharedApplication];
    delegate = [[PEPixelLatencyApp alloc] init];
    [NSApp setDelegate:delegate];
    [NSApp run];
    [delegate release];
    [pool release];
    return 0;
}
