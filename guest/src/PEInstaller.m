/*
 * Install PowerEmu Tools - on the PowerEmu Tools disc.
 *
 * Installs PowerEmu Agent for the current user: copies it to
 * ~/Library/PowerEmu, makes it a login item and starts it; none of that
 * needs an administrator.  Optionally (asking for an administrator's
 * password) it also installs PowerEmu Clock, a LaunchDaemon that keeps the
 * clock with the host's.  "Remove" undoes it all.
 *
 * Objective-C 1 with manual retain/release, for the 10.4 SDK; no nib.
 */
#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
#include <sys/wait.h>

#define AGENT_NAME @"PowerEmu Agent.app"
#define CLOCK_PLIST "/Library/LaunchDaemons/com.spartan0285.poweremu.clock.plist"

/* Run a shell script as root after Mac OS X asks for an administrator's
 * name and password.  Returns NO if the user cancelled or it failed. */
static BOOL RunAsAdmin(NSString *script, NSString *arg)
{
    AuthorizationRef auth;
    if (AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &auth) != errAuthorizationSuccess)
        return NO;
    AuthorizationItem right = { kAuthorizationRightExecute, 0, NULL, 0 };
    AuthorizationRights rights = { 1, &right };
    AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights
                             | kAuthorizationFlagPreAuthorize;
    OSStatus err = AuthorizationCopyRights(auth, &rights, NULL, flags, NULL);
    if (err == errAuthorizationSuccess) {
        char *args[] = { "-c", (char *)[script UTF8String], "sh", (char *)[arg fileSystemRepresentation], NULL };
        FILE *pipe = NULL;
        err = AuthorizationExecuteWithPrivileges(auth, "/bin/sh", kAuthorizationFlagDefaults, args, &pipe);
        if (pipe) {
            char buf[256];
            while (fgets(buf, sizeof buf, pipe)) {}
            fclose(pipe);
        }
        int status;
        while (wait(&status) > 0) {}
    }
    AuthorizationFree(auth, kAuthorizationFlagDefaults);
    return err == errAuthorizationSuccess;
}

static BOOL ClockInstalled(void)
{
    return [[NSFileManager defaultManager] fileExistsAtPath:@CLOCK_PLIST];
}

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
    NSButton *clockBox;
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
    [removeButton setEnabled:installed || ClockInstalled()];
    if (installed && [[status stringValue] length] == 0)
        [status setStringValue:@"PowerEmu Tools are installed. Installing again updates them."];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 240)
        styleMask:NSTitledWindowMask | NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"PowerEmu Tools"];
    NSImageView *icon = [[[NSImageView alloc] initWithFrame:NSMakeRect(20, 156, 64, 64)] autorelease];
    [icon setImage:[NSApp applicationIconImage]];
    [[window contentView] addSubview:icon];
    [self label:@"PowerEmu Tools" frame:NSMakeRect(100, 190, 340, 24) size:16 bold:YES];
    [self label:@"Lets this virtual Mac share the clipboard with your Mac, "
                 "open shared folders, and shut down cleanly when PowerEmu asks. "
                 "They are installed for your account and start when you log in."
          frame:NSMakeRect(100, 114, 340, 64) size:12 bold:NO];
    status = [[self label:@"" frame:NSMakeRect(100, 52, 340, 34) size:11 bold:NO] retain];

    clockBox = [[NSButton alloc] initWithFrame:NSMakeRect(98, 88, 350, 22)];
    [clockBox setButtonType:NSSwitchButton];
    [clockBox setTitle:@"Keep the clock in step with PowerEmu (needs an administrator)"];
    [[clockBox cell] setControlSize:NSSmallControlSize];
    [clockBox setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [clockBox setState:NSOnState];
    [[window contentView] addSubview:clockBox];

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
    NSString *msg = @"Installed. PowerEmu Tools are running and will start whenever you log in.";
    if ([clockBox state] == NSOnState) {
        NSString *script =
            @"set -e; mkdir -p /Library/PowerEmu; "
             "cp \"$1/PowerEmuClock\" /Library/PowerEmu/PowerEmuClock; "
             "chown root:wheel /Library/PowerEmu/PowerEmuClock; chmod 755 /Library/PowerEmu/PowerEmuClock; "
             "launchctl unload " CLOCK_PLIST " 2>/dev/null || true; "
             "cp \"$1/com.spartan0285.poweremu.clock.plist\" " CLOCK_PLIST "; "
             "chown root:wheel " CLOCK_PLIST "; chmod 644 " CLOCK_PLIST "; "
             "launchctl load " CLOCK_PLIST;
        if (!RunAsAdmin(script, [[NSBundle mainBundle] resourcePath]) || !ClockInstalled())
            msg = @"Installed, but without clock syncing (no administrator's password was given).";
    }
    [status setStringValue:msg];
    [self refresh];
}

- (void)remove:(id)sender
{
    StopAgent();
    SetLoginItems(LoginItemsWithoutAgent());
    [[NSFileManager defaultManager] removeFileAtPath:InstalledAgentPath() handler:nil];
    NSString *msg = @"PowerEmu Tools have been removed.";
    if (ClockInstalled()) {
        RunAsAdmin(@"launchctl unload " CLOCK_PLIST "; rm -f " CLOCK_PLIST "; rm -rf /Library/PowerEmu", @"");
        if (ClockInstalled()) msg = @"PowerEmu Tools have been removed, except clock syncing (no administrator's password was given).";
    }
    [status setStringValue:msg];
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
