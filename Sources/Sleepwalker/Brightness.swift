import CoreGraphics
import Foundation

/// Built-in display brightness via the private DisplayServices framework
/// (the only API that works on Apple Silicon; it's what the `brightness` CLI uses).
enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let fns: (get: GetFn, set: SetFn)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(handle, "DisplayServicesGetBrightness"),
              let s = dlsym(handle, "DisplayServicesSetBrightness")
        else { return nil }
        return (unsafeBitCast(g, to: GetFn.self), unsafeBitCast(s, to: SetFn.self))
    }()

    static var isAvailable: Bool { fns != nil && builtInDisplay != nil }

    private static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    /// 0...1, or nil if unavailable.
    static func get() -> Float? {
        guard let fns, let id = builtInDisplay else { return nil }
        var value: Float = 0
        return fns.get(id, &value) == 0 ? value : nil
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let fns, let id = builtInDisplay else { return false }
        return fns.set(id, max(0, min(1, value))) == 0
    }
}
