import AppKit
import Observation
import ActivityCore

/// The unread badges hub: reads the followed apps' Dock badges on triggers, publishes them as the passive "badges"
/// activity and announces increases with a short "Teams · 3" notice. Decreases and clears are silent.
///
/// macOS sends no badge change event, so nothing is read in a loop. Triggers: an app activated or deactivated
/// (merged, 0.5 s later), a followed app launched (plus one read 15 s later, its baseline) or quit, the island
/// opening, the screen coming back (wake, unlock, session return), a Settings change, and the optional minute check
/// ("Check every minute", off by default).
///
/// A read only touches the followed apps that run: their pids are kept from launch / quit events (seeded with
/// per-bundle-id lookups), so it never walks `NSWorkspace.runningApplications`, which costs 5–7 ms per pass inside a
/// running app (AppKit refetches every process's info). A badge read costs ≈ 0.02 ms per app on the main thread.
/// All running regular apps are walked only when the Settings list appears. Badge data stays in memory.
@MainActor @Observable
final class BadgesStore {
    static let shared = BadgesStore()

    enum Status: Equatable {
        case off
        case running
        case unavailable(String)
        #if DEBUG
        /// `-debugBadges` fixture: every trigger and read checks `.running`, so nothing overwrites it.
        case debug
        #endif
    }

    /// One row of the Settings list.
    struct ListedApp: Identifiable, Equatable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// A followed app that runs, by pid.
    private struct RunningApp {
        let bundleID: String
        let name: String
        /// Launched recently and its own follow-up read hasn't run yet: what it shows is its state, not news.
        var isSettling = false
    }

    private(set) var status: Status = .off
    /// Badges of the followed running apps: most recent increase first, then by name.
    private(set) var badges: [AppBadge] = []
    /// Badges of the running apps that aren't followed, by bundle id (read when the Settings list appears).
    private(set) var otherLabels: [String: String] = [:]
    /// Settings list: known or followed installed apps, plus running apps showing a badge.
    private(set) var listedApps: [ListedApp] = []

    let activity = BadgesActivity()

    /// Last read's cost and number of apps read (diagnostics).
    @ObservationIgnored private(set) var lastSweepDuration: TimeInterval = 0
    @ObservationIgnored private(set) var lastSweepReads = 0

    @ObservationIgnored private var running: [pid_t: RunningApp] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    /// When each badged app last went up (cleared with its badge).
    @ObservationIgnored private var increasedAt: [String: Date] = [:]
    /// The first read only sets the baseline: what apps show at launch isn't news.
    @ObservationIgnored private var hasBaseline = false
    /// Whether the pending read announces increases (every merged request must agree).
    @ObservationIgnored private var pendingAnnounces = true
    @ObservationIgnored private var settingsViewers = 0
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private let scheduler = ActivityScheduler.shared

    private static let sweepKey = "badges.sweep"
    /// One follow-up per launch (`badges.launch.<pid>`), so a second launch never moves the first one's.
    private static let launchKeyPrefix = "badges.launch."
    private static let periodicKey = "badges.periodic"
    /// App switches come as activate + deactivate pairs, and the app being read often clears its badge just after.
    private static let switchDelay: TimeInterval = 0.5
    /// A launching app sets its badge while it loads: it stays silent until this read after its launch, its baseline.
    private static let launchFollowUp: TimeInterval = 15
    private static let periodicInterval: TimeInterval = 60
    private static let periodicLeeway: Duration = .seconds(15)

    private var settings: BadgesSettings { .shared }

    private init() {}

    // MARK: Lifecycle

    func install() {
        guard status == .off else { return }
        #if DEBUG
        if let spec = UserDefaults.standard.string(forKey: "debugBadges") {
            showDebugBadges(spec)
            return
        }
        #endif
        guard BadgeReader.shared != nil else {
            status = .unavailable("This version of macOS no longer shares Dock badges with other apps.")
            return
        }
        status = .running
        observe()
        seedRunningApps()
        requestSweep(after: 1, announces: false)
    }

    func prepareForTermination() {
        for key in [Self.sweepKey, Self.periodicKey] { scheduler.cancel(key) }
        scheduler.cancelAll(prefix: Self.launchKeyPrefix)
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        status = .off
    }

    // MARK: Triggers

    /// The island opened: read now. An increase found here updates the island without a notice (it is on screen).
    func islandDidOpen() {
        guard status == .running, !running.isEmpty else { return }
        requestSweep(after: 0, announces: false)
    }

    /// A followed app or the minute check changed: newly followed apps start from their current badge, silently.
    func settingsChanged() {
        guard status == .running else { return }
        seedRunningApps()
        requestSweep(after: 0, announces: false)
        if settingsViewers > 0 { discoverForSettings() }
    }

    /// The Settings list appeared: lists the apps, with every running regular app's badge.
    func settingsDidAppear() {
        settingsViewers += 1
        if status == .running { sweep(announces: true) }
        discoverForSettings()
    }

    func settingsDidDisappear() {
        settingsViewers = max(0, settingsViewers - 1)
        if settingsViewers == 0, !otherLabels.isEmpty { otherLabels = [:] }
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        add(workspace, NSWorkspace.didActivateApplicationNotification) { store, _ in store.refreshSoon() }
        add(workspace, NSWorkspace.didDeactivateApplicationNotification) { store, _ in store.refreshSoon() }
        add(workspace, NSWorkspace.didLaunchApplicationNotification) { store, app in store.appLaunched(app) }
        add(workspace, NSWorkspace.didTerminateApplicationNotification) { store, app in store.appTerminated(app) }
        // Display wake, unlock, session return: whatever arrived meanwhile.
        add(.default, DisplayVisibility.didChangeNotification) { store, _ in
            guard DisplayVisibility.shared.isVisible else { return }
            store.refreshSoon()
        }
    }

    private func add(_ center: NotificationCenter, _ name: Notification.Name,
                     _ handler: @escaping @MainActor (BadgesStore, NSRunningApplication?) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, app)
            }
        }
        observers.append((center, token))
    }

    /// An app switch or the screen coming back: read 0.5 s later, if a followed app runs.
    private func refreshSoon() {
        guard !running.isEmpty else { return }
        requestSweep(after: Self.switchDelay, announces: true)
    }

    private func appLaunched(_ app: NSRunningApplication?) {
        guard let app, let id = app.bundleIdentifier, settings.isEnabled(id) else { return }
        let pid = app.processIdentifier
        running[pid] = RunningApp(bundleID: id, name: app.localizedName ?? id, isSettling: true)
        scheduleFollowUp(pid: pid, at: Date().addingTimeInterval(Self.launchFollowUp))
        requestSweep(after: Self.switchDelay, announces: true)
    }

    /// The launched app's baseline read: still silent for it (settling during the read), then it counts. Read now
    /// rather than merged so the flag clears after it; a pending silent request (island opening) keeps it silent.
    private func scheduleFollowUp(pid: pid_t, at date: Date) {
        scheduler.schedule(Self.launchKeyPrefix + "\(pid)", at: date, leeway: .seconds(2)) { [weak self] in
            guard let self else { return }
            self.sweep(announces: self.scheduler.scheduledDate(for: Self.sweepKey) == nil || self.pendingAnnounces)
            self.running[pid]?.isSettling = false
        }
    }

    private func appTerminated(_ app: NSRunningApplication?) {
        guard let pid = app?.processIdentifier, running.removeValue(forKey: pid) != nil else { return }
        scheduler.cancel(Self.launchKeyPrefix + "\(pid)")
        requestSweep(after: 0, announces: true)
    }

    /// The followed apps that run right now (one lookup per followed bundle id, no process walk). Known pids keep
    /// their state; a new one launched less than `launchFollowUp` ago (just before Islet, as at login) settles like
    /// a launch, with its follow-up a full `launchFollowUp` from now.
    private func seedRunningApps() {
        var apps: [pid_t: RunningApp] = [:]
        let now = Date()
        for id in settings.enabledIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where !app.isTerminated {
                let pid = app.processIdentifier
                if let known = running[pid] {
                    apps[pid] = known
                } else if let launched = app.launchDate, now.timeIntervalSince(launched) < Self.launchFollowUp {
                    apps[pid] = RunningApp(bundleID: id, name: app.localizedName ?? id, isSettling: true)
                    scheduleFollowUp(pid: pid, at: now.addingTimeInterval(Self.launchFollowUp))
                } else {
                    apps[pid] = RunningApp(bundleID: id, name: app.localizedName ?? id)
                }
            }
        }
        for pid in running.keys where apps[pid] == nil { scheduler.cancel(Self.launchKeyPrefix + "\(pid)") }
        running = apps
    }

    /// Reads after `delay`, merged with a pending read (the earlier date wins). The merged read announces increases
    /// only if every request did: one from the opening island keeps it silent.
    private func requestSweep(after delay: TimeInterval, announces: Bool) {
        let due = Date().addingTimeInterval(max(0, delay))
        if let pending = scheduler.scheduledDate(for: Self.sweepKey) {
            pendingAnnounces = pendingAnnounces && announces
            if pending <= due { return }
        } else {
            pendingAnnounces = announces
        }
        scheduler.schedule(Self.sweepKey, at: due, leeway: .milliseconds(200)) { [weak self] in
            guard let self else { return }
            self.sweep(announces: self.pendingAnnounces)
        }
    }

    // MARK: Reading

    /// Reads the followed running apps' badges, publishes them, announces increases and re-arms the minute check.
    func sweep(announces: Bool) {
        guard status == .running, let reader = BadgeReader.shared else { return }
        scheduler.cancel(Self.sweepKey)
        let started = DispatchTime.now().uptimeNanoseconds
        let now = Date()
        var found: [String: AppBadge] = [:]
        var launching: Set<String> = []
        for (pid, app) in running {
            guard let label = BadgeText.normalized(reader.label(pid: pid)) else { continue }
            guard found[app.bundleID] == nil else { continue }   // a second instance: one badge per app
            found[app.bundleID] = AppBadge(bundleID: app.bundleID, name: app.name, label: label)
            if app.isSettling { launching.insert(app.bundleID) }
        }
        lastSweepReads = running.count
        lastSweepDuration = TimeInterval(DispatchTime.now().uptimeNanoseconds - started) / 1e9

        var increased: [AppBadge] = []
        if hasBaseline {
            let previous = Dictionary(badges.map { ($0.bundleID, $0.label) }, uniquingKeysWith: { first, _ in first })
            for badge in found.values where BadgeText.isIncrease(from: previous[badge.bundleID], to: badge.label) {
                increasedAt[badge.bundleID] = now
                if announces, !launching.contains(badge.bundleID) { increased.append(badge) }
            }
        }
        hasBaseline = true
        increasedAt = increasedAt.filter { found[$0.key] != nil }
        let sorted = found.values.sorted { lhs, rhs in
            let left = increasedAt[lhs.bundleID] ?? .distantPast, right = increasedAt[rhs.bundleID] ?? .distantPast
            if left != right { return left > right }
            return Self.byName(lhs.name, lhs.bundleID, rhs.name, rhs.bundleID)
        }
        if sorted != badges {
            badges = sorted
            #if DEBUG
            NSLog("Islet debug: badges → %@", sorted.map { "\($0.name) \($0.label)" }.joined(separator: ", "))
            #endif
        }

        syncActivity()
        announce(increased)
        armMinuteCheck()
    }

    /// The passive activity runs while a followed app shows a badge.
    private func syncActivity() {
        let center = ActivityCenter.shared
        let isRunning = center.activity(id: BadgesActivity.activityID) != nil
        if !badges.isEmpty, !isRunning {
            activity.startedAt = Date()
            center.start(activity)
        } else if badges.isEmpty, isRunning {
            center.end(id: BadgesActivity.activityID)
        }
    }

    private func announce(_ increased: [AppBadge]) {
        guard !increased.isEmpty else { return }
        let ordered = increased.sorted { Self.byName($0.name, $0.bundleID, $1.name, $1.bundleID) }
        ActivityCenter.shared.showTransient(BadgeTransient.make(for: ordered))
    }

    /// The minute check: 60 s after the last read, only while a followed app runs, with a generous leeway, and
    /// display-only (it neither wakes the Mac nor fires while the screen is off; it fires when the screen is back).
    private func armMinuteCheck() {
        guard settings.checksEveryMinute, !running.isEmpty, status == .running else {
            scheduler.cancel(Self.periodicKey)
            return
        }
        scheduler.schedule(Self.periodicKey, at: Date().addingTimeInterval(Self.periodicInterval),
                           leeway: Self.periodicLeeway, displayOnly: true) { [weak self] in
            self?.requestSweep(after: 0, announces: true)
        }
    }

    // MARK: Apps

    /// Total shown in the wings: "12", "999+", "•".
    var totalText: String? { BadgeText.total(badges) }

    /// The app whose badge went up last (the closed island's icon).
    var latest: AppBadge? { badges.first }

    func label(for bundleID: String) -> String? {
        badges.first { $0.bundleID == bundleID }?.label ?? otherLabels[bundleID]
    }

    /// The app's icon, cached.
    func icon(for bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
                NSWorkspace.shared.icon(forFile: $0.path)
            }
        icons[bundleID] = icon
        return icon
    }

    /// Brings the app forward (launching it if it quit meanwhile).
    func open(_ bundleID: String) {
        let url = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard let url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    /// Settings only: reads every running regular app that isn't followed (one process walk), then rebuilds the list.
    private func discoverForSettings() {
        var others: [String: String] = [:]
        var names: [String: String] = [:]
        if status == .running, let reader = BadgeReader.shared {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let id = app.bundleIdentifier, !settings.isEnabled(id),
                      let label = BadgeText.normalized(reader.label(pid: app.processIdentifier)) else { continue }
                others[id] = label
                names[id] = app.localizedName ?? id
            }
        }
        if others != otherLabels { otherLabels = others }
        refreshListedApps(runningNames: names)
    }

    /// Installed catalog apps, followed apps, and running apps showing a badge, by name.
    private func refreshListedApps(runningNames: [String: String]) {
        let workspace = NSWorkspace.shared
        var names: [String: String] = [:]
        for app in BadgeCatalog.apps where workspace.urlForApplication(withBundleIdentifier: app.bundleID) != nil {
            names[app.bundleID] = app.name
        }
        for id in settings.enabledIDs where names[id] == nil {
            guard let url = workspace.urlForApplication(withBundleIdentifier: id) else { continue }
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            names[id] = name
        }
        for badge in badges where names[badge.bundleID] == nil { names[badge.bundleID] = badge.name }
        for (id, name) in runningNames where names[id] == nil { names[id] = name }
        let listed = names.map { ListedApp(bundleID: $0.key, name: $0.value) }
            .sorted { Self.byName($0.name, $0.bundleID, $1.name, $1.bundleID) }
        if listed != listedApps { listedApps = listed }
    }

    #if DEBUG
    /// `-debugBadges "com.microsoft.teams2=3,com.apple.MobileSMS=12"`: shows these badges (first = latest increase)
    /// instead of reading the Dock, for renders. Nothing is read or observed, and `.debug` keeps every trigger
    /// (Settings, island opening) from reading over them.
    private func showDebugBadges(_ spec: String) {
        status = .debug
        badges = spec.split(separator: ",").compactMap { item in
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let label = BadgeText.normalized(parts[1]) else { return nil }
            let id = parts[0]
            let name = BadgeCatalog.apps.first { $0.bundleID == id }?.name
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    .map { FileManager.default.displayName(atPath: $0.deletingPathExtension().path) } ?? id
            return AppBadge(bundleID: id, name: name, label: label)
        }
        syncActivity()
    }
    #endif

    private static func byName(_ lhsName: String, _ lhsID: String, _ rhsName: String, _ rhsID: String) -> Bool {
        let order = lhsName.localizedStandardCompare(rhsName)
        return order == .orderedSame ? lhsID < rhsID : order == .orderedAscending
    }
}
