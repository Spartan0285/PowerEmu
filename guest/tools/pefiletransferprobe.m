/* Run only in the isolated integration guest. Reports real Finder CGS IDs. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
int main(int argc,char **argv) {
 NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];[NSApplication sharedApplication];
 PEAgent *agent=[[PEAgent alloc] init];CGSWindowID ids[256];int n=0,i;
 CGSGetOnScreenWindowList(_CGSDefaultConnection(),0,256,ids,&n);
 for(i=0;i<n;i++) {
  printf("owner %d %d\n",ids[i],[agent fileWindowPID:ids[i]]);
  NSString *path=[agent fileFinderFolder:ids[i] selection:NO];
  if(path)printf("%d\t%s\n",ids[i],[path UTF8String]);
 }
 NSLog(@"DRAG %@ %@",[[NSPasteboard pasteboardWithName:NSDragPboard] types],[[NSPasteboard pasteboardWithName:NSDragPboard] propertyListForType:NSFilenamesPboardType]);
 [pool release];return 0;
}
