/* Capability probe: capture a window without changing focus or ordering.
 * Build with the 10.4u SDK. Private API availability is checked at runtime.
 * Usage: pewindowcapture WINDOW_ID OUTPUT.ppm [global]
 */
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef int (*ConnectionFn)(void);
typedef CGError (*BoundsFn)(int, int, CGRect *);
typedef CGError (*OwnerFn)(int, int, int *);
typedef void (*CopyFn)(CGContextRef, CGRect, int, int, CGRect);
typedef CGError (*ListFn)(int, int, int, int *, int *);
typedef CGError (*LevelFn)(int, int, int *);

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSApplicationLoad();
    fprintf(stderr, "accessibility_enabled=%d\n", AXAPIEnabled());
    if (argc < 3) { fprintf(stderr, "usage: pewindowcapture ID OUTPUT.ppm [global]\n"); return 2; }
    ConnectionFn connection = (ConnectionFn)dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
    BoundsFn bounds = (BoundsFn)dlsym(RTLD_DEFAULT, "CGSGetScreenRectForWindow");
    CopyFn copy = (CopyFn)dlsym(RTLD_DEFAULT, getenv("PE_CAPTURE") ? "CGContextCopyWindowCaptureContentsToRect" : "CGContextCopyWindowContentsToRect");
    if (!connection || !bounds || !copy) { fprintf(stderr, "capture API unavailable\n"); return 3; }
    int cid = connection(), wid = atoi(argv[1]);
    if (wid < 0) {
        ListFn list = (ListFn)dlsym(RTLD_DEFAULT, "CGSGetOnScreenWindowList");
        LevelFn level = (LevelFn)dlsym(RTLD_DEFAULT, "CGSGetWindowLevel");
        int ids[256], count = 0, i;
        if (!list || !level || list(cid, 0, 256, ids, &count) != kCGErrorSuccess) return 3;
        for (i = 0; i < count; i++) {
            int layer = -1; CGRect candidate;
            if (level(cid, ids[i], &layer) == kCGErrorSuccess && layer == 0 &&
                bounds(cid, ids[i], &candidate) == kCGErrorSuccess && candidate.size.width > 400) {
                wid = ids[i]; break;
            }
        }
        if (wid < 0) return 4;
    }
    if (getenv("PE_LIST_WINDOWS")) {
        ListFn list = (ListFn)dlsym(RTLD_DEFAULT, "CGSGetOnScreenWindowList");
        LevelFn level = (LevelFn)dlsym(RTLD_DEFAULT, "CGSGetWindowLevel");
        int ids[256], count = 0, i;
        if (!list || !level || list(cid, 0, 256, ids, &count) != kCGErrorSuccess) return 3;
        for (i = 0; i < count; i++) {
            int layer; CGRect r;
            if (level(cid, ids[i], &layer) == kCGErrorSuccess && bounds(cid, ids[i], &r) == kCGErrorSuccess)
                fprintf(stderr, "id=%d level=%d width=%.0f height=%.0f\n", ids[i], layer, r.size.width, r.size.height);
        }
        return 0;
    }
    NSWindow *control = nil;
    if (wid == 0) {
        control = [[NSWindow alloc] initWithContentRect:NSMakeRect(200,200,240,160)
            styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
        [control setTitle:@"PowerEmu capture probe"];
        [control setBackgroundColor:[NSColor greenColor]];
        [control orderFront:nil];
        [control display];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        wid = [control windowNumber];
    }
    CGRect rect;
    if (bounds(cid, wid, &rect) != kCGErrorSuccess) return 4;
    size_t w = (size_t)rect.size.width, h = (size_t)rect.size.height;
    if (!w || !h || w > 8192 || h > 8192) return 5;
    unsigned char *bytes = calloc(h, w * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    int argb = getenv("PE_CAPTURE_ARGB") != NULL;
    CGContextRef ctx = CGBitmapContextCreate(bytes, w, h, 8, w * 4, cs,
        argb ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaPremultipliedLast);
    if (!ctx) return 6;
    CGRect local = CGRectMake(0, 0, w, h);
    if (getenv("PE_OWNER")) {
        OwnerFn owner = (OwnerFn)dlsym(RTLD_DEFAULT, "CGSGetWindowOwner");
        int ownerID = cid;
        if (owner && owner(cid, wid, &ownerID) == kCGErrorSuccess) cid = ownerID;
    }
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    int repeats = getenv("PE_CAPTURE_REPEAT") ? atoi(getenv("PE_CAPTURE_REPEAT")) : 1, run;
    if (repeats < 1 || repeats > 100) return 2;
    for (run = 0; run < repeats; run++) {
        copy(ctx, local, cid, wid, argc > 3 ? rect : local);
        CGContextFlush(ctx);
    }
    double elapsed = (CFAbsoluteTimeGetCurrent() - began) * 1000 / repeats;
    FILE *f = fopen(argv[2], "wb");
    if (!f) return 7;
    fprintf(f, "P6\n%lu %lu\n255\n", (unsigned long)w, (unsigned long)h);
    size_t i, nonzero = 0;
    for (i = 0; i < w * h; i++) {
        unsigned char *rgb = bytes + i * 4 + (argb ? 1 : 0);
        fwrite(rgb, 1, 3, f);
        if (rgb[0] || rgb[1] || rgb[2]) nonzero++;
    }
    fclose(f);
    fprintf(stderr, "window=%d rect=%.0f,%.0f %lux%lu nonzero=%lu capture_ms=%.3f\n", wid,
        rect.origin.x, rect.origin.y, (unsigned long)w, (unsigned long)h, (unsigned long)nonzero, elapsed);
    CGContextRelease(ctx); CGColorSpaceRelease(cs); free(bytes); [pool release];
    return 0;
}
