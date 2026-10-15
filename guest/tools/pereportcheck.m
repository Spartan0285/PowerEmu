/* Read-only matched report controls; no input, focus or window changes. */
#define main poweremuAgentMain
#include "../src/PEAgent.m"
#undef main
@interface PEReportCheck : PEAgent { @public NSString *windows; NSString *focus; }
- (void)native;
@end
@implementation PEReportCheck
- (void)native { completeCaptureMode=YES; nativeReport12=YES; }
- (void)send:(NSString *)verb data:(NSData *)payload {
 if([verb isEqualToString:@"WINDOWS"]) { [windows release];windows=[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]; }
 if([verb isEqualToString:@"FOCUSED"]) { [focus release];focus=[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]; }
}
@end
int main(void) {
 NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init]; NSApplicationLoad();
 PEReportCheck *agent=[[PEReportCheck alloc] init];[agent native];
 NSString *expected=nil,*expectedFocus=nil;int phase,i,failures=0;
 for(phase=0;phase<3;phase++) {
  if(phase==1)unsetenv("PE_CAPTURE_REPORT_OCCLUDERS");else setenv("PE_CAPTURE_REPORT_OCCLUDERS","1",1);
  for(i=0;i<24;i++) {
   CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();[agent reportWindows:nil];
   if(!expected && agent->windows) {expected=[agent->windows copy];expectedFocus=[agent->focus copy];}
   if(!agent->windows || ![expected isEqualToString:agent->windows] || ![expectedFocus isEqualToString:agent->focus])failures++;
   printf("phase=%d sample=%d elapsedMS=%.3f\n",phase,i,(CFAbsoluteTimeGetCurrent()-start)*1000);
  }
 }
 printf("report metadata failures=%d\n",failures);[pool drain];return failures?1:0;
}
