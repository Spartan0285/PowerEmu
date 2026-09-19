/*
 * Install PowerEmu Tools - on the PowerEmu Tools disc.
 *
 * Installs PowerEmu Agent for the current user: copies it to
 * ~/Library/PowerEmu, makes it a login item and starts it.  Nothing needs an
 * administrator's password.  "Remove" undoes all three.
 *
 * Objective-C 1 with manual retain/release, for the 10.4 SDK; no nib.
 */
#import <Cocoa/Cocoa.h>

#define AGENT_NAME @"PowerEmu Agent.app"

static NSString *InstalledAgentPath(void)
{
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/PowerEmu"]
            stringByAppendingPathComponent:AGENT_NAME];
}

/* Login items live in loginwindow's AutoLaunchedApplicationDictionary. */
static NSMutableArray *LoginItems(void)
{
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("AutoLaunchedApplicationDictionary"),
        CFSTR("loginwindow"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSMutableArray *a = [NSMutableArray array];
    if (v) {
        if (CFGetTypeID(v) == CFArrayGetTypeID()) [a addObjectsFromArray:(NSArray *)v];
        CFRelease(v);
    }
    return a;
}

static void SetLoginItems(NSArray *items)
{
    CFPreferencesSetValue(CFSTR("AutoLaunchedApplicationDictionary"), (CFArrayRef)items,
        CFSTR("loginwindow"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR("loginwindow"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

static NSMutableArray *LoginItemsWithoutAgent(void)
{
    NSMutableArray *items = LoginItems();
    int i;
    for (i = [items count] - 1; i >= 0; i--) {
        NSString *p = [[items objectAtIndex:i] objectForKey:@"Path"];
        if ([[p lastPathComponent] isEqualToString:AGENT_NAME]) [items removeObjectAtIndex:i];
    }
    return items;
}

static void StopAgent(void)
{
    NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/killall"
                                         arguments:[NSArray arrayWithObject:@"PowerEmu Agent"]];
    [t waitUntilExit];
}

@interface PEInstaller : NSObject {
    NSWindow *window;
    NSTextField *status;
    NSButton *removeButton;
}
@end

@implementation PEInstaller

- (NSTextField *)label:(NSString *)s frame:(NSRect)r size:(float)size bold:(BOOL)bold
{
    NSTextField *t = [[[NSTextField alloc] initWithFrame:r] autorelease];
    [t setStringValue:s];
    [t setEditable:NO];
    [t setSelectable:NO];
    [t setBezeled:NO];
    [t setDrawsBackground:NO];
    [t setFont:bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size]];
    [[window contentView] addSubview:t];
    return t;
}

- (void)refresh
{
    BOOL installed = [[NSFileManager defaultManager] fileExistsAtPath:InstalledAgentPath()];
    [removeButton setEnabled:installed];
    if (installed && [[status stringValue] length] == 0)
        [status setStringValue:@"PowerEmu Tools are installed. Installing again updates them."];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 230)
        styleMask:NSTitledWindowMask | NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"PowerEmu Tools"];
    NSImageView *icon = [[[NSImageView alloc] initWithFrame:NSMakeRect(20, 146, 64, 64)] autorelease];
    [icon setImage:[NSApp applicationIconImage]];
    [[window contentView] addSubview:icon];
    [self label:@"PowerEmu Tools" frame:NSMakeRect(100, 180, 340, 24) size:16 bold:YES];
    [self label:@"Lets this virtual Mac share the clipboard with your Mac, "
                 "open shared folders, and shut down cleanly when PowerEmu asks. "
                 "They are installed for your account and start when you log in."
          frame:NSMakeRect(100, 110, 340, 64) size:12 bold:NO];
    status = [[self label:@"" frame:NSMakeRect(100, 62, 340, 40) size:11 bold:NO] retain];

    NSButton *install = [[[NSButton alloc] initWithFrame:NSMakeRect(340, 14, 106, 32)] autorelease];
    [install setTitle:@"Install"];
    [install setBezelStyle:NSRoundedBezelStyle];
    [install setKeyEquivalent:@"\r"];
    [install setTarget:self];
    [install setAction:@selector(install:)];
    [[window contentView] addSubview:install];

    removeButton = [[NSButton alloc] initWithFrame:NSMakeRect(234, 14, 106, 32)];
    [removeButton setTitle:@"Remove"];
    [removeButton setBezelStyle:NSRoundedBezelStyle];
    [removeButton setTarget:self];
    [removeButton setAction:@selector(remove:)];
    [[window contentView] addSubview:removeButton];

    [self refresh];
    [window center];
    [window makeKeyAndOrderFront:nil];
}

- (void)install:(id)sender
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *src = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:AGENT_NAME];
    NSString *dst = InstalledAgentPath();
    NSString *dir = [dst stringByDeletingLastPathComponent];

    StopAgent();
    if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir attributes:nil];
    if ([fm fileExistsAtPath:dst]) [fm removeFileAtPath:dst handler:nil];
    if (![fm copyPath:src toPath:dst handler:nil]) {
        [status setStringValue:@"Could not copy PowerEmu Agent into your Library folder."];
        return;
    }
    NSMutableArray *items = LoginItemsWithoutAgent();
    [items addObject:[NSDictionary dictionaryWithObjectsAndKeys:
        dst, @"Path", [NSNumber numberWithBool:YES], @"Hide", nil]];
    SetLoginItems(items);
    [[NSWorkspace sharedWorkspace] launchApplication:dst];
    [status setStringValue:@"Installed. PowerEmu Tools are running and will start whenever you log in."];
    [self refresh];
}

- (void)remove:(id)sender
{
    StopAgent();
    SetLoginItems(LoginItemsWithoutAgent());
    [[NSFileManager defaultManager] removeFileAtPath:InstalledAgentPath() handler:nil];
    [status setStringValue:@"PowerEmu Tools have been removed."];
    [self refresh];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

@end

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    [NSApp setDelegate:[[PEInstaller alloc] init]];
    /* A minimal menu so Quit works. */
    NSMenu *bar = [[[NSMenu alloc] init] autorelease];
    NSMenuItem *appItem = [[[NSMenuItem alloc] init] autorelease];
    NSMenu *appMenu = [[[NSMenu alloc] initWithTitle:@"PowerEmu Tools"] autorelease];
    [appMenu addItemWithTitle:@"Quit Install PowerEmu Tools" action:@selector(terminate:) keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];
    [bar addItem:appItem];
    [NSApp setMainMenu:bar];
    [NSApp run];
    [pool release];
    return 0;
}
