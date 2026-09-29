#import <Cocoa/Cocoa.h>
@interface SheetFixture : NSObject { NSWindow *window; NSSavePanel *savePanel; }
- (void)showSheet;
- (void)poll:(NSTimer *)timer;
- (void)sheetDidEnd:(NSSavePanel *)panel returnCode:(int)code contextInfo:(void *)context;
@end
@implementation SheetFixture
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,200,640,440)
        styleMask:NSTitledWindowMask|NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"PowerEmu disposable sheet test"];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self performSelector:@selector(showSheet) withObject:nil afterDelay:1.0];
    NSTimer *timer=[NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
}
- (void)poll:(NSTimer *)timer {
    NSString *path=@"/tmp/pesheet-command";
    NSString *command=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if(!command)return;
    [[NSFileManager defaultManager] removeFileAtPath:path handler:nil];
    if([command hasPrefix:@"cancel"])[savePanel cancel:nil];
    else if([command hasPrefix:@"open"] && ![window attachedSheet])[self showSheet];
}
- (void)sheetDidEnd:(NSSavePanel *)panel returnCode:(int)code contextInfo:(void *)context {
    [panel orderOut:nil];
}
- (void)showSheet {
    if(!savePanel)savePanel=[[NSSavePanel savePanel] retain];
    [savePanel beginSheetForDirectory:@"/tmp" file:@"disposable.txt"
        modalForWindow:window modalDelegate:self didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}
@end
int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    SheetFixture *delegate = [[SheetFixture alloc] init];
    [NSApp setDelegate:delegate];
    [NSApp run]; [delegate release]; [pool release]; return 0;
}
