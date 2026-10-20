import Foundation

enum PomodoroPhase: String, Codable, Equatable {
    case focus
    case shortBreak
    case longBreak

    var isBreak: Bool { self != .focus }

    var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        }
    }
}

struct PomodoroConfig: Equatable {
    var focus: TimeInterval = 25 * 60
    var shortBreak: TimeInterval = 5 * 60
    var longBreak: TimeInterval = 15 * 60
    /// A long break follows every Nth focus session.
    var sessionsBeforeLongBreak = 4
    var autoStartBreaks = true
    var autoStartFocus = false

    func duration(of phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .focus: return focus
        case .shortBreak: return shortBreak
        case .longBreak: return longBreak
        }
    }
}

/// Pomodoro session, stored as dates. Pure state machine: callers pass `now` and the config.
struct PomodoroState: Codable, Equatable {
    enum Outcome: Equatable {
        /// The next phase started on its own.
        case autoStarted(PomodoroPhase)
        /// The next phase waits for the user. `away`: idle for over half of the focus that just ended.
        case awaiting(next: PomodoroPhase, away: Bool)
    }

    var phase: PomodoroPhase
    /// Focus sessions completed in the current cycle (the session dots).
    var completedInCycle: Int
    var endDate: Date?
    var pausedRemaining: TimeInterval?
    /// Length of the current phase (ring denominator).
    var phaseTotal: TimeInterval
    /// `phase` has not started yet: the previous one ended and auto-start was off (or the user was away).
    var awaiting: Bool
    /// The focus that just ended was spent away from the Mac.
    var wasAway: Bool
    var startedAt: Date
    /// When the previous phase ended (for "Finished at" and the restore transient).
    var lastPhaseEnd: Date?

    static func start(config: PomodoroConfig, now: Date) -> PomodoroState {
        PomodoroState(phase: .focus, completedInCycle: 0, endDate: now.addingTimeInterval(config.focus).roundedToSecond,
                      pausedRemaining: nil, phaseTotal: config.focus, awaiting: false, wasAway: false,
                      startedAt: now, lastPhaseEnd: nil)
    }

    var isRunning: Bool { !awaiting && pausedRemaining == nil && endDate != nil }
    var isPaused: Bool { !awaiting && pausedRemaining != nil }

    func remaining(at now: Date) -> TimeInterval {
        if awaiting { return phaseTotal }
        if let pausedRemaining { return pausedRemaining }
        return max(0, (endDate ?? now).timeIntervalSince(now))
    }

    func fraction(at now: Date) -> Double {
        guard phaseTotal > 0 else { return 0 }
        return min(1, max(0, remaining(at: now) / phaseTotal))
    }

    /// The phase that follows `phase` (focus counted or not).
    func phaseAfterCurrent(config: PomodoroConfig, countingFocus: Bool) -> PomodoroPhase {
        guard phase == .focus else { return .focus }
        let count = completedInCycle + (countingFocus ? 1 : 0)
        let every = max(1, config.sessionsBeforeLongBreak)
        return countingFocus && count % every == 0 ? .longBreak : .shortBreak
    }

    /// The running phase reached its end. `idle`: seconds since the last user input, read at the boundary.
    /// Returns what happens next and whether a focus session was counted.
    mutating func phaseEnded(config: PomodoroConfig, now: Date, idle: TimeInterval) -> (outcome: Outcome, countedFocus: Bool) {
        let ended = phase
        let away = idle > phaseTotal / 2
        lastPhaseEnd = endDate.map { min($0, now) } ?? now
        wasAway = false

        if ended == .focus {
            if away {
                // Not counted: offer to restart the focus.
                wait(for: .focus, config: config)
                wasAway = true
                return (.awaiting(next: .focus, away: true), false)
            }
            let next = phaseAfterCurrent(config: config, countingFocus: true)
            completedInCycle += 1
            if config.autoStartBreaks {
                begin(next, config: config, now: now)
                return (.autoStarted(next), true)
            }
            wait(for: next, config: config)
            return (.awaiting(next: next, away: false), true)
        }

        if ended == .longBreak { completedInCycle = 0 }
        // Nobody is there to start a focus: wait for them even with auto-start on.
        if config.autoStartFocus && !away {
            begin(.focus, config: config, now: now)
            return (.autoStarted(.focus), false)
        }
        wait(for: .focus, config: config)
        return (.awaiting(next: .focus, away: false), false)
    }

    /// Starts the awaited phase.
    mutating func startAwaited(config: PomodoroConfig, now: Date) {
        guard awaiting else { return }
        begin(phase, config: config, now: now)
    }

    /// Ends the current phase without counting it and starts the next one now.
    mutating func skip(config: PomodoroConfig, now: Date) {
        if awaiting {
            // Skipping an awaited break goes straight to focus; an awaited focus just starts.
            if phase == .longBreak { completedInCycle = 0 }
            begin(.focus, config: config, now: now)
            return
        }
        if phase == .longBreak { completedInCycle = 0 }
        let next = phaseAfterCurrent(config: config, countingFocus: false)
        lastPhaseEnd = now
        begin(next, config: config, now: now)
    }

    /// Starts `next` right away (e.g. "Start Break" after an away focus).
    mutating func begin(_ next: PomodoroPhase, config: PomodoroConfig, now: Date) {
        phase = next
        phaseTotal = config.duration(of: next)
        endDate = now.addingTimeInterval(phaseTotal).roundedToSecond
        pausedRemaining = nil
        awaiting = false
        wasAway = false
    }

    mutating func pause(now: Date) {
        guard isRunning else { return }
        pausedRemaining = max(1, remaining(at: now))
        endDate = nil
    }

    mutating func resume(now: Date) {
        guard isPaused, let left = pausedRemaining else { return }
        endDate = now.addingTimeInterval(left).roundedToSecond
        pausedRemaining = nil
    }

    private mutating func wait(for next: PomodoroPhase, config: PomodoroConfig) {
        phase = next
        phaseTotal = config.duration(of: next)
        endDate = nil
        pausedRemaining = nil
        awaiting = true
    }
}
