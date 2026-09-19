/* listmodes: print the display modes Tiger offers for the main display */
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
static long num(CFDictionaryRef d, CFStringRef k) { long v = 0; CFNumberRef n = CFDictionaryGetValue(d, k); if (n) CFNumberGetValue(n, kCFNumberLongType, &v); return v; }
int main(void) {
    CFArrayRef modes = CGDisplayAvailableModes(CGMainDisplayID());
    CFIndex i;
    for (i = 0; i < CFArrayGetCount(modes); i++) {
        CFDictionaryRef m = CFArrayGetValueAtIndex(modes, i);
        printf("%ldx%ld %ldbpp%s\n", num(m, kCGDisplayWidth), num(m, kCGDisplayHeight),
               num(m, kCGDisplayBitsPerPixel), CFDictionaryGetValue(m, kCGDisplayModeUsableForDesktopGUI) == kCFBooleanTrue ? "" : " (not for desktop)");
    }
    return 0;
}
