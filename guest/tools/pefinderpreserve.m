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
int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    PEAgent *agent = [[PEAgent alloc] init];
    [agent harmony:YES]; pump(3);
    window(@"PE-preserve-A"); window(@"PE-preserve-B"); window(@"PE-preserve-B");
    pump(12); checkFinderWindow(@"PE-preserve-A"); checkFinderWindow(@"PE-preserve-B");
    [agent harmony:NO]; pump(2); [agent harmony:YES]; pump(2);
    window(@"PE-preserve-after-toggle"); pump(12); checkFinderWindow(@"PE-preserve-after-toggle");
    [agent harmony:NO]; pump(3);
    window(@"PE-preserve-after-exit"); pump(12); checkFinderWindow(@"PE-preserve-after-exit");
    printf("PASS production Harmony entry, rapid off/on, and exit delays\n");
    [agent release]; [pool release]; return 0;
}
