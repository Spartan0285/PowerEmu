import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    if owner.contains("qemu") {
        print(w[kCGWindowNumber as String]!, owner, w[kCGWindowName as String] ?? "")
    }
}
