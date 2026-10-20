import Foundation

public struct WorkdayRecord: Hashable {
    public let day: String
    public let start: Date
    public let end: Date?
    public let source: WorkdayStartSource
    public let endSource: WorkdayEndSource?

    public init(
        day: String,
        start: Date,
        end: Date?,
        source: WorkdayStartSource,
        endSource: WorkdayEndSource? = nil
    ) {
        self.day = day
        self.start = start
        self.end = end
        self.source = source
        self.endSource = endSource
    }

    public var duration: Int? {
        end.map { max(0, Int($0.timeIntervalSince(start))) }
    }
}

// One row per day with the start and end of work: ~/.vpn-workdays.csv
// (date,start_iso,end_iso,source,end_source). Read by vpn-report.sh, which
// looks only at the first four fields. Rows written before the end column
// existed (date,start_iso,source) or before the end source did
// (date,start_iso,end_iso,source) are still read.
public final class WorkdayHistory {
    private let path: String
    private let calendar: Calendar
    private let header = "date,start_iso,end_iso,source,end_source"

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
    public func record(_ start: WorkdayStart?, end: WorkdayEndPoint?, day: Date) {
        var all = entries()
        let key = key(for: day)
        let updated = start.map {
            WorkdayRecord(day: key, start: $0.date, end: end?.date, source: $0.source, endSource: end?.source)
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
        all[key] = WorkdayRecord(
            day: key,
            start: start,
            end: end,
            source: .edited,
            endSource: end == nil ? nil : .edited
        )
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
    // the end of past days once the day is over. The end is the day's last
    // VPN session, extended over the activity that followed it. Ends that are
    // already final (detected, from the question, typed or edited) stay; only
    // a missing end or the rule's planned guess is replaced.
    public func backfill(
        detector: WorkdayStartDetector,
        endDetector: WorkdayEndDetector,
        useActivityForEnd: Bool,
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

            if existing?.source == .edited {
                continue
            }

            // A row written before end sources existed counts as final once
            // it has an end.
            if let existing, existing.end != nil, existing.endSource != .planned {
                continue
            }

            let start = existing.map { WorkdayStart(date: $0.start, source: $0.source) }
                ?? detector.detect(day: day, streaks: streaks, vpnStarts: vpnStarts)

            guard let start, !start.provisional else {
                continue
            }

            // Without a VPN session that day there is nothing to detect; a
            // planned guess then keeps its end rather than losing it.
            // An end before the start (a manual start after the day's only
            // VPN session) is no end at all.
            let endPoint = endDetector.detect(
                day: day,
                sessions: sessions,
                streaks: streaks,
                useActivity: useActivityForEnd
            ).flatMap { $0.date > start.date ? $0 : nil } ?? existing.flatMap {
                $0.endSource == .planned ? $0.end.map { WorkdayEndPoint(date: $0, source: .planned) } : nil
            }

            all[key] = WorkdayRecord(
                day: key,
                start: start.date,
                end: endPoint?.date,
                source: start.source,
                endSource: endPoint?.source
            )
            changed = changed || all[key] != existing
        }

        if changed {
            write(all)
        }
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

        let endSource = fields.count >= 5 ? WorkdayEndSource(rawValue: fields[4]) : nil

        return WorkdayRecord(day: fields[0], start: start, end: end, source: source, endSource: endSource)
    }

    private func write(_ all: [String: WorkdayRecord]) {
        let rows = all.keys.sorted().compactMap { key -> String? in
            guard let record = all[key] else {
                return nil
            }

            let end = record.end.map { timestampFormat.string(from: $0) } ?? ""
            let endSource = record.endSource?.rawValue ?? ""
            return "\(key),\(timestampFormat.string(from: record.start)),\(end),\(record.source.rawValue),\(endSource)"
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

public extension WorkdayRecord {
    // Time worked as of `now`: a day still in progress (no end yet, or an end
    // still ahead) counts up to now; a past day without an end counts as 0.
    func worked(now: Date, calendar: Calendar) -> Int {
        guard calendar.isDate(start, inSameDayAs: now) else {
            return duration ?? 0
        }

        let until = min(end ?? now, now)
        return max(0, Int(until.timeIntervalSince(start)))
    }
}

public struct WorkdayTotals {
    private let calendar: Calendar
    private let now: Date

    public init(calendar: Calendar = .vpnTimeISO, now: Date = Date()) {
        self.calendar = calendar
        self.now = now
    }

    public func total(_ bucket: Bucket, records: [WorkdayRecord]) -> Int {
        records
            .filter { record in
                switch bucket {
                case .today:
                    return calendar.isDate(record.start, inSameDayAs: now)
                case .week:
                    return calendar.isDate(record.start, equalTo: now, toGranularity: .weekOfYear)
                case .month:
                    return calendar.isDate(record.start, equalTo: now, toGranularity: .month)
                }
            }
            .reduce(0) { $0 + $1.worked(now: now, calendar: calendar) }
    }
}
