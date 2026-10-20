import AppKit
import EventKit
import Observation
import ActivityCore

/// UserDefaults keys of the calendar feature.
enum CalendarDefaults {
    /// The user connected the calendar (set after a successful grant, cleared by Disconnect).
    static let connected = "calendar.connected"
    /// Minutes before a meeting it appears: 5, 10 or 15.
    static let leadMinutes = "calendar.leadMinutes"
    /// Calendars the user unchecked (storing exclusions keeps "all" as the default, new calendars included).
    static let excludedCalendars = "calendar.excludedCalendars"
    /// Dismissed occurrence ids → when to forget them (their end).
    static let dismissed = "calendar.dismissed"

    static let leadChoices = [5, 10, 15]
}

/// A calendar row for the Settings picker.
struct CalendarInfo: Identifiable, Equatable {
    var id: String
    var title: String
    var source: String
    var color: MeetingColor
}

/// EventKit access and event fetching. No `EKEventStore` exists until the user connects (it costs ≈ 1 MB);
/// afterwards everything is event-driven: store changes (debounced) and the scheduler's resync (wake, clock,
/// time zone, day change), which also moves the 24 h window forward.
@MainActor @Observable
final class CalendarService {
    static let shared = CalendarService()

    enum Access: Equatable {
        case notDetermined, denied, restricted, writeOnly, fullAccess
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    /// Last known authorization (refreshed on connect, on launch when connected, and when Settings shows).
    private(set) var access: Access = .notDetermined
    private(set) var isConnected: Bool
    private(set) var isRunning = false
    private(set) var isRequesting = false
    /// A problem to show in Settings (request failed, missing usage description).
    private(set) var problem: String?
    private(set) var calendars: [CalendarInfo] = []
    /// Eligible events of the next 24 h, by start (dismissed ones included; the controller filters them).
    private(set) var events: [MeetingEvent] = []

    var leadMinutes: Int {
        didSet {
            guard leadMinutes != oldValue else { return }
            defaults.set(leadMinutes, forKey: CalendarDefaults.leadMinutes)
            MeetingController.shared.reevaluate()
        }
    }

    var excludedCalendarIDs: Set<String> {
        didSet {
            guard excludedCalendarIDs != oldValue else { return }
            defaults.set(Array(excludedCalendarIDs).sorted(), forKey: CalendarDefaults.excludedCalendars)
            refetch()
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Islet sent the user to System Settings to allow access: coming back with access connects.
    @ObservationIgnored private var awaitingGrant = false
    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var fetchGeneration = 0
    @ObservationIgnored private let fetchQueue = DispatchQueue(label: "dev.islet.calendar.fetch", qos: .utility)

    private static let refetchKey = "calendar.refetch"
    private static let horizonKey = "calendar.horizon"
    private static let changeDebounce: TimeInterval = 1.5
    private static let window: TimeInterval = 24 * 3600

    private init() {
        defaults.register(defaults: [
            CalendarDefaults.connected: false,
            CalendarDefaults.leadMinutes: 10,
        ])
        isConnected = defaults.bool(forKey: CalendarDefaults.connected)
        let lead = defaults.integer(forKey: CalendarDefaults.leadMinutes)
        leadMinutes = CalendarDefaults.leadChoices.contains(lead) ? lead : 10
        excludedCalendarIDs = Set(defaults.stringArray(forKey: CalendarDefaults.excludedCalendars) ?? [])
    }

    /// The first meeting still to come or under way (for the launcher and Settings).
    var nextEvent: MeetingEvent? {
        let now = Date()
        let dismissed = MeetingController.shared.dismissed
        return events.first { $0.removal > now && dismissed[$0.id] == nil }
    }

    // MARK: Access

    /// Reads the authorization status: no prompt, no store.
    func refreshAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let value: Access
        switch status {
        case .notDetermined: value = .notDetermined
        case .restricted: value = .restricted
        case .denied: value = .denied
        case .writeOnly: value = .writeOnly
        case .fullAccess: value = .fullAccess
        @unknown default: value = .denied
        }
        if access != value { access = value }
    }

    /// Launch: resumes only if the user connected earlier and full access is still granted (never prompts).
    func resumeIfConnected() {
        guard isConnected else { return }
        refreshAccess()
        if access == .fullAccess { start() }
    }

    /// "Connect Calendar…": the only place the calendar prompt can appear.
    func connect() {
        guard !isRequesting, !isRunning else { return }
        problem = nil
        refreshAccess()
        switch access {
        case .fullAccess:
            setConnected(true)
            start()
        case .denied, .writeOnly:
            openPrivacySettings()
        case .restricted:
            break
        case .notDetermined:
            requestAccess()
        }
    }

    func openPrivacySettings() {
        awaitingGrant = true
        NSWorkspace.shared.open(Self.privacySettingsURL)
    }

    /// Islet became active again (e.g. back from System Settings): picks up a grant without another click.
    func accessMayHaveChanged() {
        refreshAccess()
        guard !isRunning, !isRequesting, access == .fullAccess, isConnected || awaitingGrant else { return }
        awaitingGrant = false
        setConnected(true)
        start()
    }

    /// Stops reading the calendar and releases the store. Access stays granted in System Settings.
    func disconnect() {
        setConnected(false)
        stop()
    }

    private func requestAccess() {
        // Without the usage description TCC kills the app instead of prompting (e.g. an unbundled dev build).
        guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil else {
            problem = "This build of Islet can't ask for calendar access (missing usage description)."
            return
        }
        isRequesting = true
        let store = EKEventStore()
        self.store = store
        store.requestFullAccessToEvents { granted, error in
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    CalendarService.shared.finishRequest(granted: granted, error: message)
                }
            }
        }
    }

    private func finishRequest(granted: Bool, error: String?) {
        isRequesting = false
        refreshAccess()
        if granted && access == .fullAccess {
            setConnected(true)
            start()
        } else {
            if let error, access == .notDetermined { problem = error }
            if !isRunning { store = nil }
        }
    }

    private func setConnected(_ value: Bool) {
        guard isConnected != value else { return }
        isConnected = value
        defaults.set(value, forKey: CalendarDefaults.connected)
    }

    // MARK: Lifecycle

    private func start() {
        guard !isRunning, access == .fullAccess else { return }
        let store = self.store ?? EKEventStore()
        self.store = store
        isRunning = true

        let center = NotificationCenter.default
        observers = [
            // Fires in bursts while accounts sync.
            center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarService.shared.scheduleRefetch() }
            },
            // Wake, clock, time zone and day changes: re-plan now, then refetch once sync settles.
            center.addObserver(forName: ActivityScheduler.resyncNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    MeetingController.shared.reevaluate()
                    CalendarService.shared.scheduleRefetch()
                }
            },
        ]
        refetch()
    }

    private func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        ActivityScheduler.shared.cancel(Self.refetchKey)
        ActivityScheduler.shared.cancel(Self.horizonKey)
        fetchGeneration += 1                    // drops a fetch in flight
        store = nil
        isRunning = false
        calendars = []
        events = []
        MeetingController.shared.update(events: [])
    }

    func prepareForTermination() {
        ActivityScheduler.shared.cancel(Self.refetchKey)
        ActivityScheduler.shared.cancel(Self.horizonKey)
    }

    // MARK: Fetching

    private func scheduleRefetch() {
        ActivityScheduler.shared.schedule(Self.refetchKey, at: Date().addingTimeInterval(Self.changeDebounce)) {
            CalendarService.shared.refetch()
        }
    }

    func refetch() {
        guard isRunning, let store else { return }
        refreshAccess()
        guard access == .fullAccess else {
            // Revoked in System Settings: keep "connected" so Settings explains what happened.
            stop()
            return
        }

        let all = store.calendars(for: .event)
        let infos = all.map(CalendarInfo.init).sorted {
            ($0.source.localizedLowercase, $0.title.localizedLowercase) < ($1.source.localizedLowercase, $1.title.localizedLowercase)
        }
        if infos != calendars { calendars = infos }

        let now = Date()
        fetchGeneration += 1
        let generation = fetchGeneration
        let selected = all.filter { !excludedCalendarIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else {
            apply(FetchResult(events: [], isTruncated: false), generation: generation)
            return
        }
        // EventKit fetches are synchronous: run them off the main thread, hand back value types.
        let request = FetchRequest(store: store, calendars: selected, start: now, end: now.addingTimeInterval(Self.window))
        fetchQueue.async {
            let result = request.run()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CalendarService.shared.apply(result, generation: generation) }
            }
        }
    }

    private func apply(_ result: FetchResult, generation: Int) {
        guard generation == fetchGeneration, isRunning else { return }
        if result.events != events { events = result.events }
        MeetingController.shared.update(events: result.events)
        // Only a truncated fetch (a very busy day) needs to look further before the next resync.
        if result.isTruncated, let last = result.events.last {
            let date = max(Date().addingTimeInterval(300), last.start.addingTimeInterval(-15 * 60))
            ActivityScheduler.shared.schedule(Self.horizonKey, at: date, leeway: .seconds(60)) {
                CalendarService.shared.refetch()
            }
        } else {
            ActivityScheduler.shared.cancel(Self.horizonKey)
        }
    }
}

private struct FetchResult: Sendable {
    var events: [MeetingEvent]
    /// More eligible events than `MeetingPlanner.maxEvents`: the latest ones were left out.
    var isTruncated: Bool
}

/// One fetch, carried to the fetch queue. EventKit objects stay inside it.
private struct FetchRequest: @unchecked Sendable {
    let store: EKEventStore
    let calendars: [EKCalendar]
    let start: Date
    let end: Date

    func run() -> FetchResult {
        autoreleasepool {
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            let events = store.events(matching: predicate).compactMap(MeetingEvent.init(event:))
                .filter { $0.removal > start }
                .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            return FetchResult(events: Array(events.prefix(MeetingPlanner.maxEvents)),
                               isTruncated: events.count > MeetingPlanner.maxEvents)
        }
    }
}

private extension MeetingEvent {
    init?(event: EKEvent) {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let traits = MeetingTraits(
            isAllDay: event.isAllDay,
            isFree: event.availability == .free,
            isDeclined: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false,
            isCanceled: event.status == .canceled
        )
        guard traits.isEligible else { return nil }

        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare link is what the Join button is for; keep room names and addresses.
        let displayLocation = location.flatMap { $0.isEmpty || $0.contains("://") ? nil : $0 }
        let joinURL = JoinLinkDetector.joinURL(in: [event.url?.absoluteString, location, event.notes])
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            id: "\(event.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))",
            eventIdentifier: event.eventIdentifier,
            title: title.isEmpty ? "Meeting" : title,
            start: start,
            end: end,
            location: displayLocation,
            calendarTitle: event.calendar?.title ?? "",
            color: MeetingColor(event.calendar?.cgColor),
            joinURL: joinURL
        )
    }
}

private extension CalendarInfo {
    init(_ calendar: EKCalendar) {
        self.init(id: calendar.calendarIdentifier, title: calendar.title,
                  source: calendar.source?.title ?? "Other", color: MeetingColor(calendar.cgColor))
    }
}

extension MeetingColor {
    /// Calendar colors come in various color spaces; falls back to a neutral red.
    init(_ cgColor: CGColor?) {
        let fallback = MeetingColor(red: 1.0, green: 0.33, blue: 0.33)
        guard let cgColor, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else {
            self = fallback
            return
        }
        self.init(red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]))
    }
}
