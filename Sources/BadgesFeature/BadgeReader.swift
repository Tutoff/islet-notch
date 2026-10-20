import Foundation
import Darwin

/// Reads the badge an app shows on its Dock icon ("3", "•", "!") from LaunchServices' `StatusLabel` item, through
/// the private `_LSASNCreateWithPid` + `_LSCopyApplicationInformationItem` found with dlsym: no permission, no extra
/// process, ≈ 0.02 ms per app. LaunchServices sends no change event for this item (verified), so callers read on
/// triggers. `shared` is nil when macOS no longer exports these functions; there is deliberately no fallback (never
/// `lsappinfo` in a loop).
struct BadgeReader: @unchecked Sendable {
    private typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    static let shared = BadgeReader()

    /// `kLSDefaultSessionID`.
    private static let defaultSession: Int32 = -2
    private static let statusLabel = "StatusLabel" as CFString

    private let createASN: CreateASN
    private let copyItem: CopyItem

    private init?() {
        // CoreServices is already loaded by AppKit: this only returns its handle.
        let path = "/System/Library/Frameworks/CoreServices.framework/CoreServices"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD) ?? dlopen(path, RTLD_LAZY),
              let create = dlsym(handle, "_LSASNCreateWithPid"),
              let copy = dlsym(handle, "_LSCopyApplicationInformationItem") else { return nil }
        createASN = unsafeBitCast(create, to: CreateASN.self)
        copyItem = unsafeBitCast(copy, to: CopyItem.self)
    }

    /// The raw badge text of the app running as `pid`; nil when it shows none or isn't running.
    func label(pid: pid_t) -> String? {
        guard pid > 0,
              let asn = createASN(kCFAllocatorDefault, pid)?.takeRetainedValue(),
              let item = copyItem(Self.defaultSession, asn, Self.statusLabel)?.takeRetainedValue() else { return nil }
        // `{ label = "3" }`, or `{ label = <null> }` once cleared.
        if let dictionary = item as? [String: Any] { return dictionary["label"] as? String }
        return item as? String
    }
}
