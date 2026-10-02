import Foundation

public struct WorkdayRecord: Hashable {
    public let day: String
    public let start: Date
    public let end: Date?
    public let source: WorkdayStartSource

    public init(day: String, start: Date, end: Date?, source: WorkdayStartSource) {
        self.day = day
        self.start = start
        self.end = end
        self.source = source
    }

    public var duration: Int? {
        end.map { max(0, Int($0.timeIntervalSince(start))) }
    }
}

// One row per day with the start and end of work: ~/.vpn-workdays.csv
// (date,start_iso,end_iso,source). Read by vpn-report.sh. Rows written before
// the end column existed (date,start_iso,source) are still read.
public final class WorkdayHistory {
    private let path: String
    private let calendar: Calendar
    private let header = "date,start_iso,end_iso,source"

    private lazy var dayFormat: DateFormatter = formatter("yyyy-MM-dd")
    private lazy var timestampFormat: DateFormatter = formatter("yyyy-MM-dd HH:mm:ss")

    public init(
        path: String = NSString(string: "~/.vpn-workdays.csv").expandingTildeInPath,
        calendar: Calendar = .vpnTimeISO
    ) {
        self.path = path
        self.calendar = calendar
    }

    public func key(for day: Date) -> String {
        dayFormat.string(from: day)
    }

    public func entries() -> [String: WorkdayRecord] {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }

        var result: [String: WorkdayRecord] = [:]

        for line in raw.split(separator: "\n").dropFirst() {
            if let record = record(from: line) {
                result[record.day] = record
            }
        }

        return result
    }

    // Newest first, for display.
    public func records() -> [WorkdayRecord] {
        entries().values.sorted { $0.day > $1.day }
    }

    // Stores today's start and end (the planned end, or one set by hand), or
    // drops the row when there is no start. Leaves the file alone when nothing
    // changed.
    public func record(_ start: WorkdayStart?, end: Date?, day: Date) {
        var all = entries()
        let key = key(for: day)
        let updated = start.map {
            WorkdayRecord(day: key, start: $0.date, end: end, source: $0.source)
        }

        if all[key] == updated {
            return
        }

        all[key] = updated
        write(all)
    }

    // A correction from the form. Edited rows are never touched by backfill.
    public func set(day: Date, start: Date, end: Date?) {
        var all = entries()
        let key = key(for: day)
        all[key] = WorkdayRecord(day: key, start: start, end: end, source: .edited)
        write(all)
    }

    public func remove(day: Date) {
        var all = entries()

        guard all.removeValue(forKey: key(for: day)) != nil else {
            return
        }

        write(all)
    }

    // Fills in past days that have VPN or activity data but no row yet, and
    // the end of past detected days once the day is over. The end is the end
    // of the day's last VPN session. Days with activity and no VPN are not
    // workdays and are skipped.
    public func backfill(
        detector: WorkdayStartDetector,
        streaks: [ActivityStreak],
        sessions: [Session],
        today: Date
    ) {
        var all = entries()
        let todayStart = calendar.startOfDay(for: today)
        let vpnStarts = sessions.map(\.start)
        let days = Set((streaks.map(\.start) + vpnStarts).map { calendar.startOfDay(for: $0) })
        var changed = false

        for day in days where day < todayStart {
            let key = key(for: day)
            let existing = all[key]

            if existing?.source == .edited || existing?.end != nil {
                continue
            }

            let start = existing.map { WorkdayStart(date: $0.start, source: $0.source) }
                ?? detector.detect(day: day, streaks: streaks, vpnStarts: vpnStarts)

            guard let start, !start.provisional else {
                continue
            }

            all[key] = WorkdayRecord(
                day: key,
                start: start.date,
                end: lastSessionEnd(on: day, sessions: sessions),
                source: start.source
            )
            changed = changed || all[key] != existing
        }

        if changed {
            write(all)
        }
    }

    private func lastSessionEnd(on day: Date, sessions: [Session]) -> Date? {
        sessions
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .map { $0.start.addingTimeInterval(TimeInterval($0.duration)) }
            .max()
    }

    private func record(from line: Substring) -> WorkdayRecord? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        guard fields.count >= 3, let start = timestampFormat.date(from: fields[1]) else {
            return nil
        }

        let end = fields.count >= 4 ? timestampFormat.date(from: fields[2]) : nil

        guard let source = WorkdayStartSource(rawValue: fields[fields.count >= 4 ? 3 : 2]) else {
            return nil
        }

        return WorkdayRecord(day: fields[0], start: start, end: end, source: source)
    }

    private func write(_ all: [String: WorkdayRecord]) {
        let rows = all.keys.sorted().compactMap { key -> String? in
            guard let record = all[key] else {
                return nil
            }

            let end = record.end.map { timestampFormat.string(from: $0) } ?? ""
            return "\(key),\(timestampFormat.string(from: record.start)),\(end),\(record.source.rawValue)"
        }

        let body = ([header] + rows).joined(separator: "\n") + "\n"
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        return formatter
    }
}
