import AppKit
import Darwin
func harmonyDebug(_ text:String) {}
struct HarmonyMenuItem { var path:String;var title:String;var enabled:Bool;var key:String;var modifiers:Int;var mark:String;var hasSubmenu:Bool }
@MainActor final class Comparison {
 let agent:GuestAgent;let output:URL
 var directFirst=false
 var rows=[[String:Any]]();var reference:Data?;var target=0;var sequence=0;var began=0.0;var ended=false;var awaiting=false
 init(socket:String,output:URL) {agent=GuestAgent(socketPath:socket);self.output=output}
 func start()throws {
  agent.shareClipboard=false
  agent.onConnect={ [weak self] in guard let self else{return};self.agent.send("CAPTUREMODE","1");self.agent.send("REPORTMODE","12");self.agent.send("HARMONY","1") }
  agent.onWindows={ [weak self] windows in
   guard let self,self.target==0,let window=windows.first(where:{$0.rect.width>250 && $0.rect.height>150}) else{return}
   self.target=window.id
   DispatchQueue.main.asyncAfter(deadline:.now()+2){self.request()}
  }
  agent.onWindowFrame={ [weak self] data in self?.received(data) }
  agent.onDisconnect={ [weak self] in guard let self,!self.ended else{return};self.finish("disconnect") }
  try agent.start()
  DispatchQueue.main.asyncAfter(deadline:.now()+70){[weak self] in self?.finish("deadline")}
 }
 func request() {
  guard !ended else{return}
  if rows.count==60 {finish(nil);return}
  sequence+=1;agent.preferDirectCaptureRequests=directFirst ? (rows.count/20) != 1 : (rows.count/20)==1
  if agent.preferDirectCaptureRequests && !agent.hasDirectCaptureChannel {finish("missing direct channel");return}
  began=ProcessInfo.processInfo.systemUptime;awaiting=true
  agent.send("WINDOWFRAME","\(target) \(sequence) 0 rle32 tiles32")
  let expected=sequence
  DispatchQueue.main.asyncAfter(deadline:.now()+3){[weak self] in guard let self,self.awaiting,self.sequence==expected else{return};self.finish("request timeout")}
 }
 func received(_ data:Data) {
  let elapsed=(ProcessInfo.processInfo.systemUptime-began)*1000
  guard awaiting,let frame=HarmonyWindowFrame.decode(data),frame.id==target,frame.sequence==sequence,let pixels=frame.image.dataProvider?.data else {finish("invalid frame");return}
  awaiting=false;let bytes=pixels as Data
  if reference==nil {reference=bytes}
  rows.append(["sequence":sequence,"mode":agent.preferDirectCaptureRequests ? "direct":"control","roundTripMS":elapsed,"width":frame.image.width,"height":frame.image.height,"samePixels":reference==bytes,"bytes":data.count])
  DispatchQueue.main.asyncAfter(deadline:.now()+0.01){self.request()}
 }
 func finish(_ error:String?) {
  guard !ended else{return};ended=true
  agent.send("HARMONY","0");agent.send("CAPTUREMODE","0")
  do {try JSONSerialization.data(withJSONObject:["error":error as Any? ?? NSNull(),"rows":rows],options:[.prettyPrinted,.sortedKeys]).write(to:output)}catch{fputs("summary failure\n",stderr)}
  DispatchQueue.main.asyncAfter(deadline:.now()+0.5){self.agent.stop();exit(error==nil ? 0:1)}
 }
}
@main struct Entry {
 @MainActor static func main()throws {
  guard (3...4).contains(CommandLine.arguments.count) else{exit(2)};setenv("POWEREMU_DIRECT_CAPTURE","1",1)
  let comparison=Comparison(socket:CommandLine.arguments[1],output:URL(fileURLWithPath:CommandLine.arguments[2]));comparison.directFirst=CommandLine.arguments.count==4;try comparison.start()
  RunLoop.current.run()
 }
}
