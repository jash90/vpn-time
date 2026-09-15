import Foundation

public final class VPNStore {
    private let csvPath: String
    private let statePath: String

    private let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    public init(
        csvPath: String = NSString(string: "~/.vpn-sessions.csv").expandingTildeInPath,
        statePath: String = NSString(string: "~/.vpn-sessions.state").expandingTildeInPath
    ) {
        self.csvPath = csvPath
        self.statePath = statePath
    }

    public func sessions() -> [Session] {
        guard let raw = try? String(contentsOfFile: csvPath, encoding: .utf8) else {
            return []
        }

        return raw
            .split(separator: "\n")
            .dropFirst()
            .compactMap(session(from:))
    }

    public func activeSession() -> (Date, String)? {
        guard let raw = try? String(contentsOfFile: statePath, encoding: .utf8) else {
            return nil
        }

        let fields = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")

        guard fields.count >= 2, let epoch = TimeInterval(fields[0]) else {
            return nil
        }

        return (Date(timeIntervalSince1970: epoch), String(fields[1]))
    }

    private func session(from line: Substring) -> Session? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)

        guard fields.count >= 3,
              let start = parser.date(from: String(fields[0])),
              let duration = Int(fields[2]) else {
            return nil
        }

        return Session(start: start, duration: duration)
    }
}
