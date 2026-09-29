/* Run only in an isolated guest: exercises production Harmony transitions. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main

static void pump(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([end timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}
static NSAppleEventDescriptor *script(NSString *source) {
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = [[[[NSAppleScript alloc] initWithSource:source] autorelease]
        executeAndReturnError:&error];
    if (error || !result) { NSLog(@"FAIL script %@", error); exit(1); }
    return result;
}
static void window(NSString *name) {
    NSString *path = [@"/tmp/" stringByAppendingString:name];
    [[NSFileManager defaultManager] createDirectoryAtPath:path attributes:nil];
    script([NSString stringWithFormat:@"tell application \"Finder\" to make new Finder window to (POSIX file \"%@\" as alias)", path]);
}
static void checkFinderWindow(NSString *name) {
    int n = [script([NSString stringWithFormat:@"tell application \"Finder\" to count (every Finder window whose name is \"%@\")", name]) int32Value];
    if (n < 1) { fprintf(stderr, "FAIL missing %s\n", [name UTF8String]); exit(2); }
    printf("PASS preserved %s (%d windows)\n", [name UTF8String], n); fflush(stdout);
}
@interface PEKeepFinderProbe : PEAgent
@end
@implementation PEKeepFinderProbe
- (void)send:(NSString *)verb data:(NSData *)data {
    if (![verb isEqualToString:@"WINDOWS"] || ![data length]) return;
    NSString *report = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    NSArray *rows = [report componentsSeparatedByString:@";"];
    unsigned i;
    for (i=0; i<[rows count]; i++) {
        NSString *row=[rows objectAtIndex:i]; if (![row length]) continue;
        int wid=[row intValue], level=0;
        if (CGSGetWindowLevel(_CGSDefaultConnection(),wid,&level)==0 && level<0) {
            fprintf(stderr,"FAIL desktop in WINDOWS\n"); exit(3);
        }
    }
}
@end
static NSString *finderState(void) {
    return [script(@"tell application \"Finder\"\nset snapshot to {}\nrepeat with n from 1 to (count of Finder windows)\nset end of snapshot to {id of Finder window n, URL of (target of Finder window n), bounds of Finder window n, collapsed of Finder window n}\nend repeat\nreturn snapshot\nend tell") description];
}
static NSString *finderIDs(void) {
    return [script(@"tell application \"Finder\" to get id of every Finder window") description];
}
int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    PEAgent *agent = [[PEKeepFinderProbe alloc] init];
    window(@"PE-keep-A"); window(@"PE-keep-B"); window(@"PE-keep-B");
    NSString *before = [[finderIDs() copy] autorelease];
    int cycle;
    for(cycle=0;cycle<3;cycle++) {
        /* Change a live folder between sessions; title-only restoration cannot
         * reproduce the full state or duplicate-window identity. */
        NSString *path = [NSString stringWithFormat:@"/tmp/PE-current-%d", cycle];
        [[NSFileManager defaultManager] createDirectoryAtPath:path attributes:nil];
        script([NSString stringWithFormat:@"tell application \"Finder\" to set target of last Finder window to (POSIX file \"%@\" as alias)", path]);
        NSString *state = [[finderState() copy] autorelease];
        [agent handle:@"CAPTUREMODE" payload:[@"1" dataUsingEncoding:NSUTF8StringEncoding]];
        [agent harmony:YES]; [agent harmony:YES]; pump(12);
        checkFinderWindow(@"PE-keep-B");
        if (![before isEqualToString:finderIDs()]) { fprintf(stderr,"FAIL IDs changed on entry\n"); return 4; }
        if (![state isEqualToString:finderState()]) { fprintf(stderr,"FAIL folder/bounds/minimized changed on entry\n"); return 6; }
        [agent handle:@"CAPTUREMODE" payload:[@"0" dataUsingEncoding:NSUTF8StringEncoding]];
        [agent harmony:NO]; [agent harmony:NO]; pump(2);
        if (![before isEqualToString:finderIDs()]) { fprintf(stderr,"FAIL IDs changed on exit\n"); return 5; }
        if (![state isEqualToString:finderState()]) { fprintf(stderr,"FAIL folder/bounds/minimized changed on exit\n"); return 7; }
        printf("PASS cycle %d: same Finder window IDs; desktop excluded\n",cycle+1); fflush(stdout);
    }
    [agent release]; [pool release]; return 0;
}
