/* Disposable guest-only Finder drag probe. Launch as a GUI app. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
@interface DragProbe : NSObject { PEAgent *agent; CGPoint start; int step; }
- (void)begin;
- (void)tick:(NSTimer *)timer;
@end
static BOOL findItem(AXUIElementRef element,CGPoint *point,int depth) {
 if(depth>8)return NO;
 CFTypeRef url=NULL,kids=NULL;
 AXUIElementCopyAttributeValue(element,CFSTR("AXURL"),&url);
 BOOL match=url && [[(id)url description] rangeOfString:@"PowerEmu-drag-probe.txt"].location!=NSNotFound;
 if(url)CFRelease(url);
 CGRect r;
 if(match && PESheetRect(element,&r)){*point=CGPointMake(CGRectGetMidX(r),CGRectGetMidY(r));return YES;}
 BOOL found=NO;
 if(AXUIElementCopyAttributeValue(element,kAXChildrenAttribute,&kids)==0 && kids && CFGetTypeID(kids)==CFArrayGetTypeID()) {
  int i;for(i=0;i<CFArrayGetCount(kids)&&i<256&&!found;i++)found=findItem((AXUIElementRef)CFArrayGetValueAtIndex(kids,i),point,depth+1);
 }
 if(kids)CFRelease(kids);return found;
}
@implementation DragProbe
- (void)applicationDidFinishLaunching:(NSNotification *)n {
 freopen("/tmp/pefinderdrag.log","w",stderr);
 agent=[[PEAgent alloc]init];
 [[NSWorkspace sharedWorkspace] openFile:@"/tmp/PowerEmu-Drag-Probe"];
 [self performSelector:@selector(begin) withObject:nil afterDelay:3];
}
- (void)begin {
 NSArray *apps=[[NSWorkspace sharedWorkspace] launchedApplications];NSDictionary *app;
 NSEnumerator *en=[apps objectEnumerator];BOOL found=NO;
 while((app=[en nextObject]))if([[app objectForKey:@"NSApplicationBundleIdentifier"] isEqual:@"com.apple.finder"]) {
  AXUIElementRef ax=AXUIElementCreateApplication([[app objectForKey:@"NSApplicationProcessIdentifier"]intValue]);
  CFTypeRef windows=NULL;
  if(AXUIElementCopyAttributeValue(ax,kAXWindowsAttribute,&windows)==0&&windows){int i;for(i=0;i<CFArrayGetCount(windows)&&!found;i++)found=findItem((AXUIElementRef)CFArrayGetValueAtIndex(windows,i),&start,0);CFRelease(windows);}
  CFRelease(ax);
 }
 if(!found){NSLog(@"FAIL no fixture item");[NSApp terminate:nil];return;}
 NSLog(@"START %g,%g",start.x,start.y);
 CGPostMouseEvent(start,true,1,true);
 NSTimer *timer=[NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
 [[NSRunLoop currentRunLoop]addTimer:timer forMode:(NSString *)kCFRunLoopCommonModes];
}
- (void)tick:(NSTimer *)timer {
 step++;
 CGPoint p=CGPointMake(start.x+30+(step%8)*4,start.y+30);
 CGPostMouseEvent(p,true,1,true);
 ProcessSerialNumber psn;CGSConnectionID owner=0;int ids[128],count=0,level=0;pid_t pid=0;
 GetFrontProcess(&psn);GetProcessPID(&psn,&pid);CGSGetConnectionIDForPSN(_CGSDefaultConnection(),&psn,&owner);
 CGSGetOnScreenWindowList(_CGSDefaultConnection(),owner,128,ids,&count);
 if(count)CGSGetWindowLevel(_CGSDefaultConnection(),ids[0],&level);
 AXUIElementRef app=AXUIElementCreateApplication(pid);CFTypeRef focused=NULL;CGRect r=CGRectZero;
 if(AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute,&focused)==0&&focused){PESheetRect((AXUIElementRef)focused,&r);CFRelease(focused);}CFRelease(app);
 NSLog(@"step=%d top=%d level=%d AXfocused=%g,%g %gx%g buttonHeld=1",step,count?ids[0]:0,level,r.origin.x,r.origin.y,r.size.width,r.size.height);
 if(step>=24){CGPostKeyboardEvent(0,53,true);CGPostKeyboardEvent(0,53,false);CGPostMouseEvent(start,true,1,false);[timer invalidate];NSLog(@"END explicit release after six seconds");[NSApp terminate:nil];}
}
@end
int main(void) {
 NSAutoreleasePool *p=[[NSAutoreleasePool alloc]init];[NSApplication sharedApplication];DragProbe *d=[[DragProbe alloc]init];[NSApp setDelegate:d];[NSApp run];[p release];return 0;
}
