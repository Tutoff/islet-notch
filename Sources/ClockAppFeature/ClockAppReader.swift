import Foundation
import SQLite3

/// Reads mobiletimerd's CoreData store with the SQLite C API: read-only, one short connection per read (opened,
/// read, closed: no WAL is held and nothing is ever checkpointed or written). Checks the expected tables and columns
/// on every read, so a store changed by a macOS update fails safe instead of being misread.
///
/// With a `-wal` file present (the usual case, mobiletimerd keeps one), a normal read-only WAL reader
/// (`immutable=0`). Without one (the last writer closed cleanly and SQLite checkpointed everything into the main file),
/// the system SQLite refuses a read-only WAL reader (it can't create the `-wal`: SQLITE_CANTOPEN, ENOENT), so the
/// main file is read with `immutable=1`: no lock, no `-shm` / `-wal` created, nothing touched. The next commit
/// recreates the WAL, which the watcher sees and reads normally.
///
/// Foundation + SQLite only; safe on any thread (each call has its own connection).
enum ClockAppReader {
    /// Where mobiletimerd keeps its store (readable without any permission, see the connectors research).
    static var realDatabasePath: String {
        NSHomeDirectory() + "/Library/Group Containers/group.com.apple.mobiletimerd/local.sqlite"
    }

    /// The storage version this mirror understands (MTTimerStorageVersion / MTAlarmStorageVersion, a float).
    static let expectedStorageVersion = 3.1

    static let timerColumns: Set<String> = [
        "Z_PK", "ZMTID", "ZSTATE", "ZDURATION", "ZTITLE", "ZFIRETIME", "ZFIREDDATE", "ZDISMISSEDDATE", "ZLASTMODIFIEDDATE",
    ]
    static let alarmColumns: Set<String> = [
        "Z_PK", "ZMTID", "ZENABLED", "ZHOUR", "ZMINUTE", "ZTITLE", "ZREPEATSCHEDULE", "ZSNOOZEDURATION", "ZFIREDDATE",
        "ZDISMISSEDDATE", "ZSNOOZEFIREDATE", "ZKEEPOFFUNTILDATE",
    ]

    // MARK: Storage version

    /// Checks mobiletimerd's preferences (real store only: a test copy has no plist of its own). Re-read from disk:
    /// mobiletimerd may have written them since the last check.
    static func storageVersionProblem() -> ClockAppFailure? {
        let domain = "com.apple.mobiletimerd" as CFString
        CFPreferencesAppSynchronize(domain)
        return storageVersionProblem(timer: CFPreferencesCopyAppValue("MTTimerStorageVersion" as CFString, domain),
                                     alarm: CFPreferencesCopyAppValue("MTAlarmStorageVersion" as CFString, domain))
    }

    /// Only a version that is present and different fails. Absent keys mean mobiletimerd hasn't created (or
    /// migrated) its store yet: not a newer format, and the schema check on every read still guards the format.
    static func storageVersionProblem(timer: Any?, alarm: Any?) -> ClockAppFailure? {
        for case let value? in [timer, alarm] {
            guard let number = value as? NSNumber else { return .unsupportedVersion("\(value)") }
            guard abs(number.doubleValue - expectedStorageVersion) < 0.0001 else {
                return .unsupportedVersion("\(number)")
            }
        }
        return nil
    }

    // MARK: Sane values

    /// Longest duration this mirror accepts: the Clock app's timers stop at 23:59:59. Anything longer is corrupt
    /// or in units this mirror doesn't know.
    static let maxDuration: TimeInterval = 7 * 86400
    /// CoreData dates farther than this from 2001 (about ±126 years) are treated as missing.
    static let maxReferenceSeconds: TimeInterval = 4e9

    /// A stored duration in 0...maxDuration, else nil.
    static func saneDuration(_ seconds: Double) -> TimeInterval? {
        seconds.isFinite && (0...maxDuration).contains(seconds) ? seconds : nil
    }

    /// A stored date within ±maxReferenceSeconds of 2001, else nil.
    static func saneDate(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let t = date.timeIntervalSinceReferenceDate
        return t.isFinite && abs(t) < maxReferenceSeconds ? date : nil
    }

    /// ZSNOOZEDURATION in minutes, clamped to 1...60 (9 when missing).
    static func saneSnoozeMinutes(_ minutes: Int?) -> Int {
        min(max(minutes ?? 9, 1), 60)
    }

    // MARK: Read

    static func read(databasePath: String) -> Result<ClockAppSnapshot, ClockAppFailure> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: databasePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .failure(.notFound)
        }
        let hasWAL = FileManager.default.fileExists(atPath: databasePath + "-wal")
        let name = hasWAL ? databasePath : URL(fileURLWithPath: databasePath).absoluteString + "?immutable=1"
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(name, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil)
        // A handle is returned even when opening fails: always close it.
        defer { sqlite3_close_v2(handle) }
        guard opened == SQLITE_OK, let db = handle else { return .failure(failure(handle, code: opened)) }
        // A writer may hold the WAL index for a moment (recovery): wait a little rather than fail.
        sqlite3_busy_timeout(db, 250)

        do {
            try requireColumns(db, table: "ZMTCDTIMER", columns: timerColumns)
            try requireColumns(db, table: "ZMTCDALARM", columns: alarmColumns)
            return .success(ClockAppSnapshot(timers: try readTimers(db), alarms: try readAlarms(db)))
        } catch let failure as ClockAppFailure {
            return .failure(failure)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    // MARK: Private

    private static func requireColumns(_ db: OpaquePointer, table: String, columns: Set<String>) throws {
        var found = Set<String>()
        try query(db, "PRAGMA table_info(\(table))") { statement in
            if let name = text(statement, 1) { found.insert(name) }
        }
        guard !found.isEmpty else { throw ClockAppFailure.unsupportedSchema("no \(table) table") }
        let missing = columns.subtracting(found).sorted()
        guard missing.isEmpty else {
            throw ClockAppFailure.unsupportedSchema("\(table) has no \(missing.joined(separator: ", "))")
        }
    }

    private static func readTimers(_ db: OpaquePointer) throws -> [ClockAppTimer] {
        var timers: [ClockAppTimer] = []
        // The CURRENT_TIMER row is a placeholder (stopped, 900 s, no dates), not a timer.
        let sql = """
            SELECT Z_PK, hex(ZMTID), ZSTATE, ZDURATION, ZTITLE, ZFIRETIME, ZFIREDDATE, ZDISMISSEDDATE, ZLASTMODIFIEDDATE
            FROM ZMTCDTIMER WHERE ZTITLE IS NULL OR ZTITLE != 'CURRENT_TIMER'
            """
        try query(db, sql) { s in
            let row = sqlite3_column_int64(s, 0)
            let fireTime: (date: Date?, interval: TimeInterval?) = blob(s, 5).map(decodeFireTime) ?? (nil, nil)
            timers.append(ClockAppTimer(
                id: identifier(text(s, 1), row: row),
                state: integer(s, 2).flatMap { ClockAppTimerState(rawValue: $0) },
                duration: saneDuration(sqlite3_column_double(s, 3)) ?? 0,
                title: text(s, 4),
                fireDate: fireTime.date,
                remaining: fireTime.interval,
                firedDate: date(s, 6),
                dismissedDate: date(s, 7),
                lastModified: date(s, 8),
                rowID: row
            ))
        }
        return timers
    }

    private static func readAlarms(_ db: OpaquePointer) throws -> [ClockAppAlarm] {
        var alarms: [ClockAppAlarm] = []
        let sql = """
            SELECT Z_PK, hex(ZMTID), ZENABLED, ZHOUR, ZMINUTE, ZTITLE, ZREPEATSCHEDULE, ZSNOOZEDURATION, ZFIREDDATE,
                   ZDISMISSEDDATE, ZSNOOZEFIREDATE, ZKEEPOFFUNTILDATE
            FROM ZMTCDALARM
            """
        try query(db, sql) { s in
            let row = sqlite3_column_int64(s, 0)
            alarms.append(ClockAppAlarm(
                id: identifier(text(s, 1), row: row),
                isEnabled: (integer(s, 2) ?? 0) != 0,
                hour: integer(s, 3) ?? -1,
                minute: integer(s, 4) ?? -1,
                title: text(s, 5),
                repeatSchedule: integer(s, 6) ?? 0,
                snoozeMinutes: saneSnoozeMinutes(integer(s, 7)),
                firedDate: date(s, 8),
                dismissedDate: date(s, 9),
                snoozeFireDate: date(s, 10),
                keepOffUntil: date(s, 11),
                rowID: row
            ))
        }
        return alarms
    }

    /// Runs `sql`, calling `row` for each result row. The statement is finalized before returning, which ends
    /// the read transaction.
    private static func query(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK, let statement else { throw failure(db, code: prepared) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw failure(db, code: step) }
            try row(statement)
        }
    }

    private static func failure(_ db: OpaquePointer?, code: Int32) -> ClockAppFailure {
        let systemError = db.map { sqlite3_system_errno($0) } ?? 0
        let primary = code & 0xFF
        if systemError == EPERM || systemError == EACCES || primary == SQLITE_PERM || primary == SQLITE_AUTH {
            return .denied
        }
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(code))
        return .unreadable("SQLite \(code): \(message)")
    }

    // MARK: Columns

    private static func text(_ s: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(s, column) != SQLITE_NULL, let value = sqlite3_column_text(s, column) else { return nil }
        return String(cString: value)
    }

    private static func integer(_ s: OpaquePointer, _ column: Int32) -> Int? {
        sqlite3_column_type(s, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, column))
    }

    /// CoreData timestamps: seconds since 2001-01-01 UTC. Out-of-range values read as missing.
    private static func date(_ s: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(s, column) != SQLITE_NULL else { return nil }
        return saneDate(Date(timeIntervalSinceReferenceDate: sqlite3_column_double(s, column)))
    }

    private static func blob(_ s: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(s, column) == SQLITE_BLOB, let bytes = sqlite3_column_blob(s, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, column)))
    }

    private static func identifier(_ hex: String?, row: Int64) -> String {
        guard let hex, !hex.isEmpty else { return "row\(row)" }
        return hex
    }

    // MARK: ZFIRETIME

    /// ZFIRETIME is an NSKeyedArchiver blob of MTTimerDate (running: `MTTimerTimeDate`, an NSDate) or
    /// MTTimerTimeInterval (paused / stopped: `MTTimerTimeInterval`, seconds). Decoded with secure coding into two
    /// local stand-ins, without the private framework. Out-of-range values read as missing.
    static func decodeFireTime(_ data: Data) -> (date: Date?, interval: TimeInterval?) {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return (nil, nil) }
        defer { unarchiver.finishDecoding() }
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(ClockAppFireDate.self, forClassName: "MTTimerDate")
        unarchiver.setClass(ClockAppFireInterval.self, forClassName: "MTTimerTimeInterval")
        let root = unarchiver.decodeObject(of: [ClockAppFireDate.self, ClockAppFireInterval.self],
                                           forKey: NSKeyedArchiveRootObjectKey)
        switch root {
        case let fire as ClockAppFireDate: return (saneDate(fire.date), nil)
        case let fire as ClockAppFireInterval: return (nil, fire.interval.flatMap(saneDuration))
        default: return (nil, nil)
        }
    }
}

/// Stand-in for MobileTimer's MTTimerDate.
@objc(IsletClockAppFireDate)
final class ClockAppFireDate: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let date: Date?

    init?(coder: NSCoder) {
        date = coder.decodeObject(of: NSDate.self, forKey: "MTTimerTimeDate") as Date?
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(date, forKey: "MTTimerTimeDate")
    }
}

/// Stand-in for MobileTimer's MTTimerTimeInterval.
@objc(IsletClockAppFireInterval)
final class ClockAppFireInterval: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let interval: TimeInterval?

    init?(coder: NSCoder) {
        interval = coder.containsValue(forKey: "MTTimerTimeInterval") ? coder.decodeDouble(forKey: "MTTimerTimeInterval") : nil
        super.init()
    }

    func encode(with coder: NSCoder) {
        if let interval { coder.encode(interval, forKey: "MTTimerTimeInterval") }
    }
}
