import Foundation

// Appends a timestamped line to ~/Library/Logs/VPNTime.log.
func appLog(_ message: String) {
    let path = NSString(string: "~/Library/Logs/VPNTime.log").expandingTildeInPath
    let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"

    guard let data = line.data(using: .utf8) else {
        return
    }

    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
