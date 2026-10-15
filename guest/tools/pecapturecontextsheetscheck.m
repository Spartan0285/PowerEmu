/* Compare production captureWindow's reused CGContext with a fresh CGContext
 * for the fixture's own attached test sheet. This creates and captures only
 * its own parent and sheet; it does not send input to other applications. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
#include <unistd.h>

@interface PECaptureContextCheckAgent : PEAgent
- (BOOL)reusableReady;
@end
@implementation PECaptureContextCheckAgent
- (BOOL)reusableReady { return captureScratchReusable && captureContext != NULL && captureScratch != nil; }
@end

static NSData *capture(PEAgent *agent, int wid, int seq, int accepted)
{
    return [agent captureWindow:[NSString stringWithFormat:@"%d %d %d",wid,seq,accepted]];
}

static BOOL writePPM(NSData *packet, const char *path, const unsigned char **pixelsOut,
                     size_t *pixelsLengthOut, size_t *widthOut, size_t *heightOut)
{
    const unsigned char *bytes=[packet bytes];
    const unsigned char *newline=memchr(bytes,'\n',[packet length]);
    int wid=0,w=0,h=0,encoding=-1,seq=0;
    if(!newline || sscanf((const char *)bytes,"%d %d %d %d %d",&wid,&w,&h,&encoding,&seq)!=5 ||
       w<1 || h<1 || encoding!=0) return NO;
    size_t header=(size_t)(newline-bytes)+1, length=(size_t)w*(size_t)h*4;
    if(header+length != [packet length]) return NO;
    FILE *f=fopen(path,"wb"); if(!f)return NO;
    fprintf(f,"P6\n%d %d\n255\n",w,h);
    size_t i; for(i=0;i<(size_t)w*(size_t)h;i++) fwrite(bytes+header+i*4,1,3,f);
    fclose(f);
    *pixelsOut=bytes+header; *pixelsLengthOut=length;
    *widthOut=(size_t)w; *heightOut=(size_t)h;
    return YES;
}

static BOOL hasAttachedAXSheet(int parentID, int sheetID)
{
    CGRect parentRect, childRect, axRect;
    pid_t resolvedPID=0;
    if(CGSGetScreenRectForWindow(_CGSDefaultConnection(),parentID,&parentRect)!=kCGErrorSuccess ||
       CGSGetScreenRectForWindow(_CGSDefaultConnection(),sheetID,&childRect)!=kCGErrorSuccess) return NO;
    AXUIElementRef parent=PEFindAXWindowForWindow(parentRect,parentID,&resolvedPID,NULL);
    if(!parent || resolvedPID!=getpid()) { if(parent)CFRelease(parent); return NO; }
    CFArrayRef sheets=PECopySheets(parent); BOOL found=NO;
    if(sheets) {
        int i;for(i=0;i<CFArrayGetCount(sheets);i++) {
            AXUIElementRef child=(AXUIElementRef)CFArrayGetValueAtIndex(sheets,i);
            if(PESheetRect(child,&axRect) && fabs(axRect.origin.x-childRect.origin.x)<=4 &&
               fabs(axRect.origin.y-childRect.origin.y)<=4 && fabs(axRect.size.width-childRect.size.width)<=4 &&
               fabs(axRect.size.height-childRect.size.height)<=4 && PESheetBelongsToFocus(child,parent)) {
                found=YES;break;
            }
        }
        CFRelease(sheets);
    }
    CFRelease(parent); return found;
}

static void pump(double seconds)
{
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while([until timeIntervalSinceNow]>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
}

int main(int argc,char **argv)
{
    alarm(30);
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    NSApplicationLoad(); NSApplication *app=[NSApplication sharedApplication]; [app finishLaunching];
    NSWindow *parent=[[NSWindow alloc] initWithContentRect:NSMakeRect(120,180,640,440)
        styleMask:NSTitledWindowMask|NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [parent setTitle:@"PowerEmu capture context check"];
    [parent makeKeyAndOrderFront:nil]; [app activateIgnoringOtherApps:YES];
    NSWindow *sheet=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,340,180)
        styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [sheet setTitle:@"PowerEmu context test sheet"];
    [app beginSheet:sheet modalForWindow:parent modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
    pump(0.7);
    int parentID=(int)[parent windowNumber], sheetID=(int)[sheet windowNumber];
    if(!sheetID || !AXAPIEnabled()) { fprintf(stderr,"FAIL: fixture sheet or Accessibility unavailable\n"); return 1; }
    if(!hasAttachedAXSheet(parentID,sheetID)) {
        fprintf(stderr,"FAIL: own AX parent-to-sheet identity missing\n"); return 1;
    }
    printf("FIXTURE parent=%d sheet=%d AXparentSheetIdentity=1\n",parentID,sheetID);
    setenv("PE_CAPTURE_RAW","1",1); setenv("PE_CAPTURE_REUSE","1",1);
    /* Use one agent instance for the complete sequence. The first two captures
     * qualify reuse; sequence 3 uses accepted=0 to force a full image packet. */
    PECaptureContextCheckAgent *agent=[[PECaptureContextCheckAgent alloc] init];
    NSData *first=capture(agent,sheetID,1,0);
    if(!first) { fprintf(stderr,"FAIL: missing first capture\n"); return 1; }
    NSData *second=capture(agent,sheetID,2,1);
    if(!second || ![agent reusableReady]) {
        fprintf(stderr,"FAIL: two stable captures did not qualify context reuse\n"); return 1;
    }
    NSData *reused=capture(agent,sheetID,3,0);
    if(!reused) { fprintf(stderr,"FAIL: missing reused-context packet\n"); return 1; }
    const unsigned char *reusedPixels=NULL; size_t reusedLength=0,reusedW=0,reusedH=0;
    if(!writePPM(reused,"/tmp/pecapture-context-reused.ppm",&reusedPixels,&reusedLength,&reusedW,&reusedH)) {
        fprintf(stderr,"FAIL: invalid reused-context packet\n"); return 1;
    }
    setenv("PE_CAPTURE_REUSE","0",1);
    NSData *fresh=capture(agent,sheetID,4,0);
    if(!fresh) { fprintf(stderr,"FAIL: missing fresh-context packet\n"); return 1; }
    const unsigned char *freshPixels=NULL; size_t freshLength=0,freshW=0,freshH=0;
    if(!writePPM(fresh,"/tmp/pecapture-context-fresh.ppm",&freshPixels,&freshLength,&freshW,&freshH)) {
        fprintf(stderr,"FAIL: invalid fresh-context packet\n"); return 1;
    }
    BOOL stable=hasAttachedAXSheet(parentID,sheetID);
    BOOL same=reusedLength==freshLength && reusedW==freshW && reusedH==freshH &&
        memcmp(reusedPixels,freshPixels,reusedLength)==0;
    printf("RESULT wid=%d dimensions=%lux%lu same=%d stableSheetIdentity=%d reused=/tmp/pecapture-context-reused.ppm fresh=/tmp/pecapture-context-fresh.ppm\n",
           sheetID,(unsigned long)freshW,(unsigned long)freshH,same,stable);
    [agent release]; [app endSheet:sheet]; [sheet orderOut:nil]; [parent orderOut:nil];
    [sheet release]; [parent release]; [pool drain];
    return same && stable?0:1;
}
