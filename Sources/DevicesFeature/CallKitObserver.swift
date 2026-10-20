import Foundation

/// Optional call source: CallKit's `CXCallObserver`, reached through the Objective-C runtime (the headers mark
/// it unavailable on macOS, but the class is present on macOS 26 and connects to callservicesd with no
/// entitlement and no prompt). It should list FaceTime calls, iPhone calls relayed by Continuity and CallKit
/// VoIP apps. Its events are unverified (no call could be placed while building it), so it is off unless
/// `devices.calls.callKit` is set. Measured cost of the observer: +240 KB, 0 wakeups while idle.
///
/// Every selector and key is checked before use: if the class or a property goes away, it reports no calls.
@MainActor
final class CallKitObserver: NSObject {
    static let defaultsKey = "devices.calls.callKit"

    /// A call has connected and hasn't ended.
    private(set) var hasConnectedCall = false
    /// Called on the main thread when `hasConnectedCall` changes.
    var onChange: ((Bool) -> Void)?

    private var observer: NSObject?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// Creates the observer. False if CallKit or `CXCallObserver` isn't available.
    @discardableResult
    func start() -> Bool {
        guard observer == nil else { return true }
        guard dlopen("/System/Library/Frameworks/CallKit.framework/CallKit", RTLD_NOW) != nil,
              let type = NSClassFromString("CXCallObserver") as? NSObject.Type else { return false }
        let setDelegate = NSSelectorFromString("setDelegate:queue:")
        let instance = type.init()
        guard instance.responds(to: setDelegate), instance.responds(to: NSSelectorFromString("calls")) else { return false }
        _ = instance.perform(setDelegate, with: self, with: DispatchQueue.main)
        observer = instance
        refresh()
        return true
    }

    func stop() {
        guard let observer else { return }
        _ = observer.perform(NSSelectorFromString("setDelegate:queue:"), with: nil, with: nil)
        self.observer = nil
        set(false)
    }

    /// `CXCallObserverDelegate`, called on the queue passed to `setDelegate:queue:` (main).
    @objc(callObserver:callChanged:)
    nonisolated func callObserver(_ observer: NSObject, callChanged call: NSObject) {
        MainActor.assumeIsolated { self.refresh() }
    }

    private func refresh() {
        let calls = observer?.value(forKey: "calls") as? [NSObject] ?? []
        set(calls.contains { Self.flag($0, "hasConnected") && !Self.flag($0, "hasEnded") })
    }

    private static func flag(_ call: NSObject, _ key: String) -> Bool {
        guard call.responds(to: NSSelectorFromString(key)) else { return false }
        return (call.value(forKey: key) as? Bool) ?? false
    }

    private func set(_ connected: Bool) {
        guard connected != hasConnectedCall else { return }
        hasConnectedCall = connected
        onChange?(connected)
    }
}
