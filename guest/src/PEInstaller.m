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
#include <unistd.h>
#include <sys/stat.h>
#include <pwd.h>
#include <grp.h>
#include <stdlib.h>
#include <string.h>
#include "PEAccessibility.h"

#define AGENT_NAME @"PowerEmu Agent.app"
#define CLOCK_PLIST "/Library/LaunchDaemons/com.spartan0285.poweremu.clock.plist"
/* AuthorizationExecuteWithPrivileges gives root's rights but keeps the
 * user's real ID, and launchctl on 10.4 goes by the real ID: it would start
 * a launchd of the user's own and load the daemon there, as the user.  Make
 * the real ID root first (Perl ships with Mac OS X). */
#define LAUNCHCTL "/usr/bin/perl -e '$< = $>; exec @ARGV' /bin/launchctl"

/* Run a shell script as root after Mac OS X asks for an administrator's
 * name and password.  Returns NO if the user canceled or it failed. */
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
        /* Nothing the script starts may keep our pipe open (a launchd it
         * spawns would, and we'd wait for the end of the output forever), so
         * its output goes to a log.  LAUNCHD_SOCKET, if the user's session
         * has one, would point launchctl at the user's launchd. */
        NSString *quiet = [@"exec </dev/null >>/var/log/PowerEmuTools.log 2>&1; date; unset LAUNCHD_SOCKET; set -x; "
                              stringByAppendingString:script];
        char *args[] = { "-c", (char *)[quiet UTF8String], "sh", (char *)[arg fileSystemRepresentation], NULL };
        FILE *pipe = NULL;
        err = AuthorizationExecuteWithPrivileges(auth, "/bin/sh", kAuthorizationFlagDefaults, args, &pipe);
        /* The script is done when its output closes. */
        if (pipe) {
            char buf[256];
            while (fgets(buf, sizeof buf, pipe)) {}
            fclose(pipe);
        }
        /* Collect the finished helper without blocking: a plain wait() would
         * also wait for PowerEmu Agent, which this process launched (on 10.4
         * it is a child) and which never exits. */
        int status, tries;
        for (tries = 0; tries < 50; tries++) {
            if (waitpid(-1, &status, WNOHANG) > 0) break;
            usleep(20000);
        }
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

/* Native package helpers run for the logged-in guest user, never root's
 * Library. Stage first; a failed update preserves the previous installation. */
static BOOL InstallAgent(void)
{
    NSFileManager *fm=[NSFileManager defaultManager];
    NSString *src=[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:AGENT_NAME];
    NSString *dst=InstalledAgentPath(), *dir=[dst stringByDeletingLastPathComponent];
    NSString *stage=[dir stringByAppendingPathComponent:@"PowerEmu Agent.installing.app"];
    NSString *backup=[dir stringByAppendingPathComponent:@"PowerEmu Agent.previous.app"];
    if (![fm fileExistsAtPath:src]) return NO;
    if (![fm fileExistsAtPath:dir] && ![fm createDirectoryAtPath:dir attributes:nil]) return NO;
    if ([fm fileExistsAtPath:stage]) [fm removeFileAtPath:stage handler:nil];
    if (![fm copyPath:src toPath:stage handler:nil]) return NO;
    StopAgent();
    if ([fm fileExistsAtPath:backup]) [fm removeFileAtPath:backup handler:nil];
    BOOL hadOld=[fm fileExistsAtPath:dst];
    if (hadOld && ![fm movePath:dst toPath:backup handler:nil]) { [[NSWorkspace sharedWorkspace] launchApplication:dst]; return NO; }
    if (![fm movePath:stage toPath:dst handler:nil]) {
        if(hadOld) [fm movePath:backup toPath:dst handler:nil];
        [[NSWorkspace sharedWorkspace] launchApplication:dst];return NO;
    }
    NSMutableArray *items=LoginItemsWithoutAgent();
    [items addObject:[NSDictionary dictionaryWithObjectsAndKeys:dst,@"Path",[NSNumber numberWithBool:YES],@"Hide",nil]];
    SetLoginItems(items);
    if(hadOld) [fm removeFileAtPath:backup handler:nil];
    return [[NSWorkspace sharedWorkspace] launchApplication:dst];
}
static BOOL UninstallAgent(void)
{
    StopAgent();SetLoginItems(LoginItemsWithoutAgent());
    NSFileManager *fm=[NSFileManager defaultManager];NSString *dst=InstalledAgentPath();
    return ![fm fileExistsAtPath:dst] || [fm removeFileAtPath:dst handler:nil];
}
static BOOL BecomeConsoleUser(void)
{
    if(geteuid()!=0)return YES;
    struct stat st;if(stat("/dev/console",&st)||st.st_uid==0)return NO;
    struct passwd *pw=getpwuid(st.st_uid);if(!pw)return NO;
    uid_t uid=pw->pw_uid;gid_t gid=pw->pw_gid;
    char *name=strdup(pw->pw_name), *home=strdup(pw->pw_dir);
    if(!name || !home) {free(name);free(home);return NO;}
    BOOL ok=initgroups(name,gid)==0 && setgid(gid)==0 && setuid(uid)==0;
    if(ok) {setenv("HOME",home,1);setenv("USER",name,1);setenv("LOGNAME",name,1);}
    free(name);free(home);return ok;
}

@interface PEInstaller : NSObject {
    NSWindow *window;
    NSTextField *status;
    NSButton *removeButton;
    NSButton *clockBox;
    BOOL uninstallMode;
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
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 240)
        styleMask:NSTitledWindowMask | NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO];
    uninstallMode = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"PowerEmuUninstaller"] boolValue];
    [window setTitle:uninstallMode ? @"Uninstall PowerEmu Tools" : @"Install PowerEmu Tools"];
    NSImageView *icon = [[[NSImageView alloc] initWithFrame:NSMakeRect(20, 156, 64, 64)] autorelease];
    [icon setImage:[NSApp applicationIconImage]];
    [[window contentView] addSubview:icon];
    [self label:@"PowerEmu Tools" frame:NSMakeRect(100, 190, 400, 24) size:16 bold:YES];
    [self label:uninstallMode ? @"Remove PowerEmu Tools from your account. Harmony, shared clipboard and guest integration will stop working." :
                 @"Install Harmony window integration, shared clipboard and shared folders. Tools start automatically when you log in. Window control requires an administrator password."
          frame:NSMakeRect(100, 114, 400, 64) size:12 bold:NO];
    status = [[self label:@"" frame:NSMakeRect(100, 52, 400, 34) size:11 bold:NO] retain];

    /*
     * Off to begin with, and deliberately.  Everything else here installs
     * for one account and asks for no password, which is what the disc's
     * Read Me promises -- but the clock is a LaunchDaemon and needs an
     * administrator.  On by default, the promise is broken by a box nobody
     * chose to tick: 10.5 stops the install with a password prompt, and
     * somebody who has no password to hand is stuck with a dialog they
     * cannot dismiss.  Whoever wants the clock can ask for it.
     *
     * The window is 60pt wider than it was because at Leopard's
     * small-system-font metrics this title is cut off mid-word --
     * "(needs an administrato" -- and there was no room for it before.
     */
    clockBox = [[NSButton alloc] initWithFrame:NSMakeRect(98, 88, 420, 22)];
    [clockBox setButtonType:NSSwitchButton];
    [clockBox setTitle:@"Keep the clock in step with PowerEmu (needs an administrator)"];
    [[clockBox cell] setControlSize:NSSmallControlSize];
    [clockBox setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [clockBox setState:NSOffState];
    [[window contentView] addSubview:clockBox];

    NSButton *install = [[[NSButton alloc] initWithFrame:NSMakeRect(400, 14, 106, 32)] autorelease];
    [install setTitle:@"Install"];
    [install setHidden:uninstallMode];
    [install setBezelStyle:NSRoundedBezelStyle];
    [install setKeyEquivalent:@"\r"];
    [install setTarget:self];
    [install setAction:@selector(install:)];
    [[window contentView] addSubview:install];

    removeButton = [[NSButton alloc] initWithFrame:NSMakeRect(294, 14, 106, 32)];
    [removeButton setTitle:@"Uninstall"];
    [removeButton setHidden:!uninstallMode];
    [clockBox setHidden:uninstallMode];
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
    if (!InstallAgent()) {
        [status setStringValue:@"Installation could not finish. Your existing files were preserved where possible. Check access to your Library folder and try again."];
        return;
    }
    NSString *msg = @"Installed. PowerEmu Tools are running and will start whenever you log in.";
    /*
     * Harmony shows this Mac's windows on the other Mac's desktop, which means
     * moving them, bringing them to the front and reading their menus -- all of
     * which belong to other applications.  Mac OS X only lets one application
     * do that to another's windows when "Enable access for assistive devices"
     * is on, and that switch is root's to set.  Without it the only way to move
     * a window is to fake a drag on its title bar, which is as bad as it
     * sounds.  So it goes in here, where an administrator's password is asked
     * for once.
     */
    BOOL wantClock = [clockBox state] == NSOnState;
    NSMutableString *script = [NSMutableString stringWithString:
        @"touch /var/db/.AccessibilityAPIEnabled; chmod 444 /var/db/.AccessibilityAPIEnabled; "];
    if (wantClock) {
        [script appendString:
            @"set -e; mkdir -p /Library/PowerEmu; "
             "cp \"$1/PowerEmuClock\" /Library/PowerEmu/PowerEmuClock; "
             "chown root:wheel /Library/PowerEmu/PowerEmuClock; chmod 755 /Library/PowerEmu/PowerEmuClock; "
             LAUNCHCTL " unload " CLOCK_PLIST " || true; "
             "cp \"$1/com.spartan0285.poweremu.clock.plist\" " CLOCK_PLIST "; "
             "chown root:wheel " CLOCK_PLIST "; chmod 644 " CLOCK_PLIST "; "
             LAUNCHCTL " load " CLOCK_PLIST "; " LAUNCHCTL " list"];
    }
    BOOL authed = RunAsAdmin(script, [[NSBundle mainBundle] resourcePath]);
    BOOL axOn = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/db/.AccessibilityAPIEnabled"];
    if (authed && axOn) PERefreshAccessibilityState();
    if (!authed || !axOn) {
        msg = @"Installed, but without window control (no administrator's password was given). "
               "Harmony will not be able to move or bring forward this Mac's windows.";
    } else if (wantClock && !ClockInstalled()) {
        msg = @"Installed, but without clock syncing.";
    }
    [status setStringValue:msg];
    [self refresh];
}

- (void)remove:(id)sender
{
    if (!uninstallMode) return;
    if (NSRunAlertPanel(@"Uninstall PowerEmu Tools?", @"Harmony and shared clipboard will stop working. You can reinstall Tools from this disc.", @"Cancel", @"Uninstall", nil) != NSAlertAlternateReturn) return;
    if (!UninstallAgent()) { [status setStringValue:@"PowerEmu Tools could not be removed. Check access to your Library folder."]; return; }
    NSString *msg = @"PowerEmu Tools have been removed.";
    if (ClockInstalled()) {
        RunAsAdmin(@LAUNCHCTL " unload " CLOCK_PLIST "; rm -f " CLOCK_PLIST "; rm -rf /Library/PowerEmu", @"");
        if (ClockInstalled()) msg = @"PowerEmu Tools have been removed, except clock syncing (no administrator's password was given).";
    }
    [status setStringValue:msg];
    [self refresh];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

@end

int main(int argc, const char *argv[])
{
    BOOL packageInstall=argc==2 && !strcmp(argv[1],"--package-install");
    BOOL packageUninstall=argc==2 && !strcmp(argv[1],"--package-uninstall");
    if ((packageInstall || packageUninstall) && !BecomeConsoleUser()) return 2;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    if(packageInstall || packageUninstall) {
        if (packageInstall) PERefreshAccessibilityState();
        BOOL ok=packageInstall ? InstallAgent() : UninstallAgent();
        [pool drain];return ok?0:1;
    }
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
