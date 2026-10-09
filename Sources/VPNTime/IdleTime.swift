import Foundation
import IOKit

// Seconds since the last keyboard or mouse input (HIDIdleTime), the same
// value the poller reads. VPNTIME_IDLE_FILE, when set, names a file holding
// the value instead, so the idle flow can be exercised without waiting.
enum IdleTime {
    static func seconds() -> TimeInterval? {
        if let path = ProcessInfo.processInfo.environment["VPNTIME_IDLE_FILE"] {
            let raw = try? String(contentsOfFile: path, encoding: .utf8)
            return raw.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))

        guard service != 0 else {
            return nil
        }

        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else {
            return nil
        }

        return value.doubleValue / 1_000_000_000
    }
}
