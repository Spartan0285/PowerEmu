/* Explicit AXSheet children only; never infer modality from geometry.
 * Leopard Cocoa exposes sheets in AXChildren, not AXSheets. */
static CFArrayRef PECopySheets(AXUIElementRef parent) {
    NSMutableArray *found=[NSMutableArray array];
    const CFStringRef attributes[]={CFSTR("AXSheets"),kAXChildrenAttribute};
    int a;
    for(a=0;a<2;a++) {
        CFTypeRef children=NULL;
        if(AXUIElementCopyAttributeValue(parent,attributes[a],&children)==0 && children &&
           CFGetTypeID(children)==CFArrayGetTypeID()) {
            int i;for(i=0;i<CFArrayGetCount(children) && i<128;i++) {
                AXUIElementRef child=(AXUIElementRef)CFArrayGetValueAtIndex(children,i);
                if(CFGetTypeID(child)!=AXUIElementGetTypeID())continue;
                CFTypeRef role=NULL;
                BOOL sheet=AXUIElementCopyAttributeValue(child,kAXRoleAttribute,&role)==0 &&
                    role && CFEqual(role,CFSTR("AXSheet"));
                if(role)CFRelease(role);
                if(sheet && ![found containsObject:(id)child])[found addObject:(id)child];
            }
        }
        if(children)CFRelease(children);
    }
    return (CFArrayRef)[found copy];
}
static BOOL PESheetRect(AXUIElementRef e, CGRect *r) {
    CFTypeRef p=NULL,s=NULL; BOOL ok=NO;
    if(AXUIElementCopyAttributeValue(e,kAXPositionAttribute,&p)==0 && p &&
       AXUIElementCopyAttributeValue(e,kAXSizeAttribute,&s)==0 && s &&
       CFGetTypeID(p)==AXValueGetTypeID() && CFGetTypeID(s)==AXValueGetTypeID()) {
        ok=AXValueGetValue(p,kAXValueCGPointType,&r->origin) && AXValueGetValue(s,kAXValueCGSizeType,&r->size);
    }
    if(p)CFRelease(p);if(s)CFRelease(s);return ok;
}
static void PEAppendSheets(AXUIElementRef parent, NSMutableArray *windows, int depth) {
    if(depth>=4 || [windows count]>=128)return;
    CFArrayRef sheets=PECopySheets(parent);
    if(sheets) {
        int i;for(i=0;i<CFArrayGetCount(sheets) && [windows count]<128;i++) {
            AXUIElementRef child=(AXUIElementRef)CFArrayGetValueAtIndex(sheets,i);
            if(CFGetTypeID(child)!=AXUIElementGetTypeID() || [windows containsObject:(id)child])continue;
            [windows addObject:(id)child];PEAppendSheets(child,windows,depth+1);
        }
    }
    if(sheets)CFRelease(sheets);
}
static int PESheetWindowID(AXUIElementRef e,int *ids,int count) {
    CGRect r;int i,found=0;
    if(!PESheetRect(e,&r))return 0;
    for(i=0;i<count;i++) {
        CGRect g;
        if(CGSGetScreenRectForWindow(_CGSDefaultConnection(),ids[i],&g)==0 &&
           fabs(g.origin.x-r.origin.x)<=4 && fabs(g.origin.y-r.origin.y)<=4 &&
           fabs(g.size.width-r.size.width)<=4 && fabs(g.size.height-r.size.height)<=4) {
            if(found)return 0; /* Ambiguous identity must not attach a window. */
            found=ids[i];
        }
    }
    return found;
}
static void PEReportSheetChildren(AXUIElementRef parent,int *ids,int count,NSMutableString *out,int depth) {
    if(depth>=4)return;
    int parentID=PESheetWindowID(parent,ids,count);
    CFArrayRef sheets=PECopySheets(parent);
    if(sheets) {
        int i;for(i=0;i<CFArrayGetCount(sheets) && i<16;i++) {
            AXUIElementRef child=(AXUIElementRef)CFArrayGetValueAtIndex(sheets,i);
            if(CFGetTypeID(child)!=AXUIElementGetTypeID())continue;
            int childID=PESheetWindowID(child,ids,count);
            if(parentID && childID && childID!=parentID)[out appendFormat:@"%d,%d;",childID,parentID];
            PEReportSheetChildren(child,ids,count,out,depth+1);
        }
    }
    if(sheets)CFRelease(sheets);
}
static NSString *PESheetReportWithPalettes(NSMutableString *palettes) {
    NSMutableString *out=[NSMutableString string];
    if(!AXAPIEnabled())return out;
    ProcessSerialNumber psn={0,kNoProcess};
    while(GetNextProcess(&psn)==noErr) {
        pid_t pid=0;int owner=0,ids[128],count=0;
        if(GetProcessPID(&psn,&pid)!=noErr || pid<=0 ||
           CGSGetConnectionIDForPSN(_CGSDefaultConnection(),&psn,&owner)!=0 ||
           CGSGetOnScreenWindowList(_CGSDefaultConnection(),owner,128,ids,&count)!=0 || !count)continue;
        AXUIElementRef app=AXUIElementCreateApplication(pid);CFTypeRef windows=NULL;
        if(AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&windows)==0 && windows && CFGetTypeID(windows)==CFArrayGetTypeID()) {
            int i;for(i=0;i<CFArrayGetCount(windows) && i<64;i++) {
                AXUIElementRef window=(AXUIElementRef)CFArrayGetValueAtIndex(windows,i);
                if(CFGetTypeID(window)!=AXUIElementGetTypeID())continue;
                PEReportSheetChildren(window,ids,count,out,0);
                if(palettes) {
                    CFTypeRef role=NULL,subrole=NULL;
                    int wid=PESheetWindowID(window,ids,count);
                    CGRect before,after;
                    BOOL valid=wid>0 && CGSGetScreenRectForWindow(_CGSDefaultConnection(),wid,&before)==0 &&
                        AXUIElementCopyAttributeValue(window,kAXRoleAttribute,&role)==0 && role && CFEqual(role,CFSTR("AXWindow")) &&
                        AXUIElementCopyAttributeValue(window,CFSTR("AXSubrole"),&subrole)==0 && subrole && CFEqual(subrole,CFSTR("AXFloatingWindow"));
                    int currentOwner=0,currentPID=0,windowOwner=0;
                    if(valid && GetProcessPID(&psn,&currentPID)==noErr && currentPID==pid &&
                       CGSGetConnectionIDForPSN(_CGSDefaultConnection(),&psn,&currentOwner)==0 && currentOwner==owner &&
                       CGSGetWindowOwner(_CGSDefaultConnection(),wid,&windowOwner)==0 && windowOwner==owner &&
                       CGSGetScreenRectForWindow(_CGSDefaultConnection(),wid,&after)==0 && CGRectEqualToRect(before,after) &&
                       PESheetWindowID(window,ids,count)==wid)
                        [palettes appendFormat:@"%d,%d;",wid,(int)pid];
                    if(role)CFRelease(role);if(subrole)CFRelease(subrole);
                }
            }
        }
        if(windows)CFRelease(windows);CFRelease(app);
    }
    return out;
}
static BOOL PESheetBelongsToFocus(AXUIElementRef target,AXUIElementRef focused) {
    NSMutableArray *sheets=[NSMutableArray array];PEAppendSheets(focused,sheets,0);
    return [sheets containsObject:(id)target];
}
static BOOL PEIsFloatingWindow(AXUIElementRef window) {
    CFTypeRef subrole=NULL;
    BOOL floating=AXUIElementCopyAttributeValue(window,CFSTR("AXSubrole"),&subrole)==0 && subrole &&
        CFEqual(subrole,CFSTR("AXFloatingWindow"));
    if(subrole)CFRelease(subrole);
    return floating;
}
/* Focus moves between a document and its floating palettes only when a click
 * lands: Word keeps it on the palette's font field until the document is
 * clicked, and a palette button never takes it at all. Waiting for focus to
 * move first means that click is never delivered, so within the front
 * application either side being a palette is ready for input. */
static BOOL PEPaletteSharesFocus(AXUIElementRef target,AXUIElementRef focused) {
    return !CFEqual(target,focused) && (PEIsFloatingWindow(focused) || PEIsFloatingWindow(target));
}
