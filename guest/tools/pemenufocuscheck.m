/* Isolated Tiger test of guest AX-focus-to-CGS-window resolution. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
@interface PEMenuCheck : PEAgent { @public int expected; BOOL received; }
@end
@implementation PEMenuCheck
- (void)send:(NSString *)verb text:(NSString *)text {
    if([verb isEqualToString:@"MENUFOCUS"]) {
        NSString *want=[NSString stringWithFormat:@"test-menu %d",expected];
        received=[text isEqualToString:want];
        printf("MENUFOCUS %s expected=%s\n",[text UTF8String],[want UTF8String]);
    }
}
@end
int main(int argc,char **argv) {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    if(argc==2) {
        PEMenuCheck *agent=[[PEMenuCheck alloc] init];agent->expected=atoi(argv[1]);
        ProcessSerialNumber front;pid_t pid=0;GetFrontProcess(&front);GetProcessPID(&front,&pid);
        AXUIElementRef a=AXUIElementCreateApplication(pid);CFTypeRef focused=NULL;
        AXError e=AXUIElementCopyAttributeValue(a,kAXFocusedWindowAttribute,&focused);
        printf("AX enabled=%d front=%d focusedError=%d\n",AXAPIEnabled(),pid,e);
        if(focused)CFRelease(focused);CFRelease(a);
        [agent reportMenuFocus:@"test-menu"];
        BOOL ok=agent->received;[agent release];[pool drain];return ok?0:1;
    }
    ProcessSerialNumber psn;GetCurrentProcess(&psn);TransformProcessType(&psn,kProcessTransformToForegroundApplication);
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(120,200,300,200)
        styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"PowerEmu menu focus test"];
    [NSApp finishLaunching];
    [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:0.5];
    while([until timeIntervalSinceNow]>0) {
        NSEvent *e=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
        if(e)[NSApp sendEvent:e];
    }
    NSTask *observer=[[NSTask alloc] init];
    [observer setLaunchPath:[NSString stringWithUTF8String:argv[0]]];
    [observer setArguments:[NSArray arrayWithObject:[NSString stringWithFormat:@"%d",[window windowNumber]]]];
    [observer launch];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while([observer isRunning] && [deadline timeIntervalSinceNow]>0) {
        NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]
            inMode:NSDefaultRunLoopMode dequeue:YES];
        if(event)[NSApp sendEvent:event];
    }
    BOOL ok=![observer isRunning] && [observer terminationStatus]==0;
    if([observer isRunning])[observer terminate];
    [observer release];
    printf("%s: focused AX window maps to exact guest window ID across processes\n",ok?"PASS":"FAIL");
    [window orderOut:nil];[window release];[pool drain];return ok?0:1;
}
