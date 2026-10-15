import AppKit
import Darwin
func harmonyDebug(_ text:String) {}

// Only menu value storage is needed by GuestAgent's parser in this fixture.
struct HarmonyMenuItem { var path:String;var title:String;var enabled:Bool;var key:String;var modifiers:Int;var mark:String;var hasSubmenu:Bool }
final class ResultBox: @unchecked Sendable { let lock=NSLock();var done=false;var error:String?
 func finish(_ error:String?=nil){lock.lock();self.error=error;done=true;lock.unlock()}
 func snapshot()->(Bool,String?){lock.lock();defer{lock.unlock()};return(done,error)} }
func connectSocket(_ path:String)throws->Int32 {
 let fd=socket(AF_UNIX,SOCK_STREAM,0);var a=sockaddr_un();a.sun_family=sa_family_t(AF_UNIX)
 withUnsafeMutableBytes(of:&a.sun_path){b in for(i,v) in path.utf8.enumerated(){b[i]=v}}
 let status=withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
 guard status==0 else{Darwin.close(fd);throw NSError(domain:"connect",code:Int(errno))}
 var timeout=timeval(tv_sec:2,tv_usec:0);setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size));return fd
}
func sendFrame(_ fd:Int32,_ verb:String,_ text:String)throws{
 let d=Data("\(verb) \(text.utf8.count)\n\(text)".utf8)
 let n=d.withUnsafeBytes{Darwin.write(fd,$0.baseAddress!,d.count)}
 guard n==d.count else{throw NSError(domain:"write",code:1)}
}
func receiveFrame(_ fd:Int32)throws->(String,String){
 var h=[UInt8]();var byte:UInt8=0
 while h.count<128 {guard read(fd,&byte,1)==1 else{throw NSError(domain:"read",code:1)};if byte==10{break};h.append(byte)}
 let f=String(decoding:h,as:UTF8.self).split(separator:" ");guard f.count==2,let n=Int(f[1]),n<4096 else{throw NSError(domain:"header",code:1)}
 var bytes=[UInt8](repeating:0,count:n)
 for i in 0..<n {guard read(fd,&bytes[i],1)==1 else{throw NSError(domain:"payload",code:1)}}
 return(String(f[0]),String(decoding:bytes,as:UTF8.self))
}
func rejected(_ fd:Int32)throws {var x:UInt8=0;guard read(fd,&x,1)==0 else{throw NSError(domain:"not-rejected",code:1)}}
@main struct Fixture {
 @MainActor static func main()throws {
  let path="/tmp/pe-direct-"+UUID().uuidString;setenv("POWEREMU_DIRECT_CAPTURE","1",1)
  let agent=GuestAgent(socketPath:path);agent.shareClipboard=false;try agent.start();let result=ResultBox()
  Task.detached {
   do {
    let control=try connectSocket(path);defer{Darwin.close(control)}
    try sendFrame(control,"HELLO","2.23\t10.4.11\tfixture")
    let hello=try receiveFrame(control);guard hello.0=="HELLO",let session=hello.1.split(separator:" ").last else{throw NSError(domain:"hello",code:1)}
    let bad=try connectSocket(path);try sendFrame(bad,"CAPTUREHELLO","wrong");try rejected(bad);Darwin.close(bad)
    let direct=try connectSocket(path);defer{Darwin.close(direct)};try sendFrame(direct,"CAPTUREHELLO",String(session))
    let deadline=Date().addingTimeInterval(3)
    while !(await MainActor.run{agent.hasDirectCaptureChannel}) {guard Date()<deadline else{throw NSError(domain:"classification",code:1)};try await Task.sleep(nanoseconds:10_000_000)}
    await MainActor.run{agent.send("WINDOWFRAME","12 1 0 rle32 tiles32")}
    let frame=try receiveFrame(direct);guard frame.0=="WINDOWFRAME",frame.1=="12 1 0 rle32 tiles32" else{throw NSError(domain:"routing",code:1)}
    let replacement=try connectSocket(path);defer{Darwin.close(replacement)};try sendFrame(replacement,"HELLO","2.23\t10.4.11\tfixture")
    _=try receiveFrame(replacement);try rejected(direct)
    let stale=try connectSocket(path);try sendFrame(stale,"CAPTUREHELLO",String(session));try rejected(stale);Darwin.close(stale)
    await MainActor.run{agent.send("WINDOWFRAME","12 2 1 rle32 tiles32")}
    let fallback=try receiveFrame(replacement);guard fallback.0=="WINDOWFRAME",fallback.1=="12 2 1 rle32 tiles32" else{throw NSError(domain:"fallback",code:1)}
    result.finish()
   }catch{result.finish(String(describing:error))}
  }
  let deadline=Date().addingTimeInterval(12)
  while !result.snapshot().0 && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
  agent.stop();let status=result.snapshot();guard status.0,status.1==nil else{fatalError("host fixture: \(status)")}
  print("PASS host capture identity/routing, stale-session teardown/rejection, legacy fallback")
 }
}
