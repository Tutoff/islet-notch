import AppKit

/// Whether anything Islet draws can be seen at all: false while the displays sleep, the screen is locked or
/// the user's session is switched out. Display-only refreshers (`SecondClock`, scheduler entries marked
/// `displayOnly`) park while it is false; completions and alerts never look at it.
///
/// Event-driven only: NSWorkspace display-sleep and session notifications plus the exact-name
/// `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications, registered once on
/// first use. Seeded from the current display and session state.
@MainActor
public final class DisplayVisibility {
    public static let shared = DisplayVisibility()

    /// Posted on the main thread when `isVisible` changes.
    public static let didChangeNotification = Notification.Name("IsletDisplayVisibilityDidChange")

    public var isVisible: Bool { !displaysAsleep && !screenLocked && sessionActive }

    private var displaysAsleep: Bool
    private var screenLocked: Bool
    private var sessionActive: Bool
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        let session = Self.sessionState()
        displaysAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        screenLocked = session.locked
        sessionActive = session.onConsole
        observe()
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        add(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        add(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        add(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionActive = false }
        add(workspace, NSWorkspace.sessionDidBecomeActiveNotification) {
            $0.sessionActive = true
            // Coming back through the login window may not post an unlock. Only ever clears: a stale read
            // must not re-lock after the unlock notification already arrived.
            if !Self.sessionState().locked { $0.screenLocked = false }
        }
        // Exact names: observing with a nil name delivers nothing on macOS 26.
        let distributed = DistributedNotificationCenter.default()
        add(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        add(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
    }

    private func add(_ center: NotificationCenter, _ name: Notification.Name,
                     _ change: @escaping @MainActor (DisplayVisibility) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasVisible = self.isVisible
                change(self)
                guard self.isVisible != wasVisible else { return }
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
        observers.append((center, token))
    }

    /// Lock and console state of this login session (no permission needed).
    private static func sessionState() -> (locked: Bool, onConsole: Bool) {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return (false, true) }
        return ((session["CGSSessionScreenIsLocked"] as? Bool) ?? false,
                (session["kCGSSessionOnConsoleKey"] as? Bool) ?? true)
    }
}
