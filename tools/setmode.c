/* setmode W H : switch the main display to the best 32bpp mode of that size */
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    boolean_t exact = 0;
    CFDictionaryRef m;
    if (argc < 3) return 2;
    m = CGDisplayBestModeForParameters(CGMainDisplayID(), 32, atoi(argv[1]), atoi(argv[2]), &exact);
    if (!exact) { fprintf(stderr, "no exact mode\n"); return 1; }
    {
        /* For the login session: a plain CGDisplaySwitchToMode is undone
         * when this process exits. */
        CGDisplayConfigRef cfg;
        CGBeginDisplayConfiguration(&cfg);
        CGConfigureDisplayMode(cfg, CGMainDisplayID(), m);
        return CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession) == kCGErrorSuccess ? 0 : 1;
    }
}
