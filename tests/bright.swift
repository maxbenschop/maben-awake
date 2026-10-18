import CoreGraphics
import Foundation
typealias G = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
let g = unsafeBitCast(dlsym(h, "DisplayServicesGetBrightness"), to: G.self)
var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
CGGetOnlineDisplayList(8, &ids, &n)
let id = ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
var v: Float = -1
let rc = g(id, &v)
print(rc == 0 ? String(format: "%.2f", v) : "n/a(rc=\(rc),online=\(n))")
