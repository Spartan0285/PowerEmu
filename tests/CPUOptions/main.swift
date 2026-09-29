import Foundation
import CryptoKit

// The existing config's unrelated shared-folder value type.
struct SharedFolder: Codable, Hashable, Identifiable {
    var id = UUID(); var path: String; var name: String; var readOnly = false
}
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}
func rejects(_ message: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Expected rejection: \(message)") } catch {}
}
let decoder = PropertyListDecoder()
let legacy = try PropertyListSerialization.data(fromPropertyList: ["name":"Legacy"], format: .xml, options: 0)
check(try! decoder.decode(VMConfig.self, from: legacy).cpuCount == 1, "Old packages default to one CPU")
var config = VMConfig(name: "Dual"); config.cpuCount = 2
let encoded = try PropertyListEncoder().encode(config)
check(try! decoder.decode(VMConfig.self, from: encoded).cpuCount == 2, "Choice survives save/load")
for count in [-1, 0, 3, 128] {
    let data = try PropertyListSerialization.data(fromPropertyList: ["name":"Invalid", "cpuCount":count], format:.xml, options:0)
    rejects("invalid decoded CPU count") { _ = try decoder.decode(VMConfig.self, from:data) }
    rejects("invalid runtime CPU count") { _ = try CPUOptions.arguments(count:count,smpCapable:true) }
}
rejects("dual CPU with legacy helper") { _ = try CPUOptions.arguments(count:2,smpCapable:false) }
let single = try CPUOptions.arguments(count:1,smpCapable:true)
let dual = try CPUOptions.arguments(count:2,smpCapable:true)
check(single.contains("cpus=1,sockets=1,cores=1,threads=1"), "One CPU topology")
check(single.contains("7400") && !single.contains("tcg,thread=multi,tb-size=512"), "PPC64 one-CPU fallback")
check(dual.contains("cpus=2,sockets=2,cores=1,threads=1") && dual.contains("tcg,thread=multi,tb-size=512") && dual.contains("7400"), "Dual CPU configuration")
let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:temp) }
let helper=temp.appendingPathComponent("Contents/Helpers/Helper.app")
let backend=helper.appendingPathComponent("Contents/MacOS/qemu-system-ppc")
let firmware=helper.appendingPathComponent("Contents/Resources/firmware/openbios-ppc")
for file in [backend,firmware] { try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true) }
let b=Data("backend".utf8),f=Data("firmware".utf8)
try b.write(to:backend);try f.write(to:firmware)
func hash(_ d:Data)->String { SHA256.hash(data:d).map { String(format:"%02x",$0) }.joined() }
let caps=SMPCapabilities(version:1,backendSHA256:hash(b),firmwareSHA256:hash(f))
check(SMPCapabilities.load(helper:helper)==nil,"Missing capability record")
try FileManager.default.createDirectory(at: SMPCapabilities.recordURL(helper: helper).deletingLastPathComponent(), withIntermediateDirectories: true)
try JSONEncoder().encode(caps).write(to:SMPCapabilities.recordURL(helper: helper))
try SMPCapabilities.load(helper:helper)!.verify(helper:helper)
try Data("wrong firmware".utf8).write(to:firmware)
rejects("mismatched firmware") { try caps.verify(helper:helper) }
try f.write(to:firmware);try Data("wrong backend".utf8).write(to:backend)
rejects("mismatched backend") { try caps.verify(helper:helper) }
print("PASS: legacy config, persistence, invalid counts, fallback, dual topology and backend/firmware matching")
