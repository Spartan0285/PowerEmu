import Foundation
import CoreGraphics
func check(_ ok: Bool) { if !ok { fputs("pixel oracle FAIL\n",stderr); exit(1) } }
func image(_ count: Int, flipped: Bool, corrupt: Bool = false) -> CGImage {
 let h = 422; var pixels = Data(repeating:255,count:640*h*4)
 for y in 0..<400 { for x in 0..<640 {
  let byte = y < 24 ? (count & 1 == 0 ? 0xa6 : 0x59) : count ^ (count & 1 == 0 ? 0 : 255)
  let v: UInt8 = byte & (1 << (7-x/80)) != 0 ? 0 : 255
  let row = flipped ? h-1-y : y; let pos = (row*640+x)*4
  for c in 0..<3 { pixels[pos+c] = corrupt ? 125 : v }
 } }
 return CGImage(width:640,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:640*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:pixels as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}
for n in 0..<65 { for flip in [false,true] { check(HarmonyPixelLatency.counter(image(n,flipped:flip)) == n) } }
check(HarmonyPixelLatency.counter(image(1,flipped:false,corrupt:true)) == nil)
print("PASS exact fixture counter0...64, both row orientations, invalid contrast rejection")
let owner = NSObject(), replacement = NSObject()
var timing = HarmonyPixelLatency(enabled:true)
let identity = ObjectIdentifier(owner)
timing.observe(id:1, identity:identity, image:image(0,flipped:false), now:0)
timing.click(id:1, identity:identity, now:1)
timing.observe(id:1, identity:identity, image:image(0,flipped:false), now:1.1)
timing.observe(id:1, identity:identity, image:image(1,flipped:false), now:1.2)
let good = timing.finish()
check(good.count == 2 && good[0].contains("sent=1 rows=1 skipped=0 pending=0 unpaired=0 invalidated=0"))
timing.observe(id:1, identity:identity, image:image(0,flipped:false), now:2)
timing.click(id:1, identity:identity, now:3)
timing.observe(id:1, identity:ObjectIdentifier(replacement), image:image(1,flipped:false), now:4)
let stale = timing.finish()
check(stale.count == 1 && stale[0].contains("rows=0") && stale[0].contains("invalidated=1"))
timing.observe(id:1, identity:identity, image:image(1,flipped:false), now:5)
check(timing.finish()[0].contains("target=0 sent=0 rows=0"))
print("PASS click pairing, unchanged-frame exclusion, proxy-reuse rejection and session reset")
