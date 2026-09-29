#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
int main(int argc,char **argv) {
 NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];[NSApplication sharedApplication];[NSApp finishLaunching];
 CGPostKeyboardEvent(0,53,true);CGPostKeyboardEvent(0,53,false);CGPostMouseEvent(CGPointMake(317,191),true,3,false,false,false);usleep(200000);
 printf("AX=%d\n",AXAPIEnabled());
 AXUIElementRef sys=AXUIElementCreateApplication(argc>3?atoi(argv[3]):961),e=NULL;
 CFTypeRef wins=NULL; printf("windows=%d\n",AXUIElementCopyAttributeValue(sys,kAXWindowsAttribute,&wins));NSLog(@"windows %@",wins);if(wins)CFRelease(wins);
 printf("hit=%d\n",AXUIElementCopyElementAtPosition(sys,argc>1?atoi(argv[1]):317,argc>2?atoi(argv[2]):191,&e));
 int i;for(i=0;e&&i<6;i++){
  CFArrayRef names=NULL;AXUIElementCopyAttributeNames(e,&names);NSLog(@"NAMES %@",names);
  NSEnumerator *n=[(NSArray *)names objectEnumerator];NSString *name;
  while((name=[n nextObject])) { CFTypeRef v=NULL;AXUIElementCopyAttributeValue(e,(CFStringRef)name,&v);NSLog(@"%@=%@",name,v);if(v)CFRelease(v); }
  if(names)CFRelease(names);CFTypeRef parent=NULL;AXUIElementCopyAttributeValue(e,kAXParentAttribute,&parent);CFRelease(e);e=(AXUIElementRef)parent;
 }
 if(e)CFRelease(e);CFRelease(sys);[pool release];return 0;
}
