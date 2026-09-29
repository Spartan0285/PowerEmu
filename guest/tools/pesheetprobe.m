#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
static void dump(AXUIElementRef e,int depth) {
    if(depth>3)return;
    CFTypeRef role=NULL,pos=NULL,size=NULL,modal=NULL,kids=NULL;
    AXUIElementCopyAttributeValue(e,kAXRoleAttribute,&role);
    AXUIElementCopyAttributeValue(e,kAXPositionAttribute,&pos);
    AXUIElementCopyAttributeValue(e,kAXSizeAttribute,&size);
    AXUIElementCopyAttributeValue(e,CFSTR("AXModal"),&modal);
    CGRect rect=CGRectZero;PESheetRect(e,&rect);
    CFArrayRef attrs=NULL;AXUIElementCopyAttributeNames(e,&attrs);
    NSLog(@"depth=%d role=%@ rect=%g,%g %gx%g modal=%@ attrs=%@",depth,role,rect.origin.x,rect.origin.y,rect.size.width,rect.size.height,modal,attrs);
    if(attrs)CFRelease(attrs);
    if(AXUIElementCopyAttributeValue(e,CFSTR("AXChildren"),&kids)==0 && kids) {
        int i;for(i=0;i<CFArrayGetCount(kids);i++)dump((AXUIElementRef)CFArrayGetValueAtIndex(kids,i),depth+1);
        CFRelease(kids);
    }
    if(role)CFRelease(role);if(pos)CFRelease(pos);if(size)CFRelease(size);if(modal)CFRelease(modal);
}
int main(int argc,char **argv) {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init]; NSApplicationLoad();
    int target=0;
    FILE *targetFile=fopen("/tmp/pesheet-target", "r");
    if(targetFile){fscanf(targetFile,"%d",&target);fclose(targetFile);}
    if(argc>1 && argv[1][0]!='-')target=atoi(argv[1]);
    freopen("/tmp/pesheet-probe.log","w",stderr);
    freopen("/tmp/pesheet-probe.log","a",stdout);
    AXUIElementRef app=AXUIElementCreateApplication(target);CFTypeRef wins=NULL;
    AXError err=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&wins);
    NSLog(@"AX enabled=%d windowsError=%d windows=%@",AXAPIEnabled(),err,wins);
    if(wins){int i;for(i=0;i<CFArrayGetCount(wins);i++)dump((AXUIElementRef)CFArrayGetValueAtIndex(wins,i),0);CFRelease(wins);}
    int ids[256],n=0,i;CGSGetOnScreenWindowList(_CGSDefaultConnection(),0,256,ids,&n);
    for(i=0;i<n;i++){CGRect r;int level;CGSGetScreenRectForWindow(_CGSDefaultConnection(),ids[i],&r);CGSGetWindowLevel(_CGSDefaultConnection(),ids[i],&level);if(level>=0&&level<20)printf("CGS %d level=%d %g,%g %gx%g\n",ids[i],level,r.origin.x,r.origin.y,r.size.width,r.size.height);}
    NSLog(@"SHEETS=%@",PESheetReport());[pool release];return 0;
}
