/* Tiger/Leopard applications cache whether the Accessibility API is enabled.
 * Updating the marker alone leaves already-running apps (notably Leopard
 * Finder) returning kAXErrorAPIDisabled even while AXAPIEnabled() is true.
 * Announce the existing setting in the console session; never enable access
 * here or restart applications to make them reread it. */
#ifndef PE_ACCESSIBILITY_H
#define PE_ACCESSIBILITY_H
static void PERefreshAccessibilityState(void)
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/db/.AccessibilityAPIEnabled"])
        return;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(),
        CFSTR("com.apple.accessibility.api"), NULL, NULL, true);
}
#endif
