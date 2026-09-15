import AppKit
import VPNTimeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = VPNStore()
    private let calendar = Calendar.vpnTimeISO
    private let agentLabel = "com.redge.vpntimebar"
    private let workdayEndKey = "workdayEndMinutes"
    private let workdayEndLastFiredKey = "workdayEndLastFired"
    private var timer: Timer?
    private lazy var workdayEndPicker = WorkdayEndPicker(calendar: calendar)

    private var agentPath: String {
        NSString(string: "~/Library/LaunchAgents/\(agentLabel).plist").expandingTildeInPath
    }

    private lazy var clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageLeading
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func refresh() {
        let sessions = store.sessions()
        let active = store.activeSession()

        if let active {
            statusItem.button?.image = MenuBarIcon.connected
            statusItem.button?.title = counter(Int(Date().timeIntervalSince(active.0)))
            statusItem.button?.toolTip = "VPN aktywny: \(active.1)"
        } else {
            statusItem.button?.image = MenuBarIcon.disconnected
            statusItem.button?.title = ""
            statusItem.button?.toolTip = "VPN rozłączony"
        }

        rebuildMenu(sessions: sessions, active: active)
        endWorkdayIfDue(active: active)
    }

    private func rebuildMenu(sessions: [Session], active: (Date, String)?) {
        let totals = Totals(calendar: calendar, now: Date())
        let menu = NSMenu()

        menu.addItem(disabled("Czas na VPN"))
        menu.addItem(.separator())
        menu.addItem(disabled("Dziś:            " + hoursMinutes(totals.total(.today, sessions: sessions, active: active))))
        menu.addItem(disabled("Ten tydzień:  " + hoursMinutes(totals.total(.week, sessions: sessions, active: active))))
        menu.addItem(disabled("Ten miesiąc: " + hoursMinutes(totals.total(.month, sessions: sessions, active: active))))
        menu.addItem(.separator())

        if let active {
            menu.addItem(disabled("● Połączony (\(active.1)) od \(clock.string(from: active.0))"))
        } else {
            menu.addItem(disabled("○ Rozłączony"))
        }

        menu.addItem(.separator())

        let autostart = NSMenuItem(
            title: "Uruchamiaj przy logowaniu",
            action: #selector(toggleAutostart),
            keyEquivalent: ""
        )
        autostart.target = self
        autostart.state = autostartEnabled() ? .on : .off
        menu.addItem(autostart)
        menu.addItem(workdayEndItem())

        menu.addItem(.separator())
        menu.addItem(action("Pokaż plik z historią", #selector(revealCSV)))
        menu.addItem(action("Odśwież", #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(action("Zakończ", #selector(quit)))

        statusItem.menu = menu
    }

    private var workdayEnd: WorkdayEnd? {
        guard let minutes = UserDefaults.standard.object(forKey: workdayEndKey) as? Int else {
            return nil
        }

        return WorkdayEnd(minutesOfDay: minutes)
    }

    private func workdayEndItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Koniec pracy: " + (workdayEnd?.label ?? "wyłączony"),
            action: #selector(openWorkdayEndPicker),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    @objc private func openWorkdayEndPicker() {
        workdayEndPicker.show(current: workdayEnd) { [weak self] end in
            self?.applyWorkdayEnd(end)
        }
    }

    private func applyWorkdayEnd(_ end: WorkdayEnd?) {
        if let end {
            UserDefaults.standard.set(end.minutesOfDay, forKey: workdayEndKey)
        } else {
            UserDefaults.standard.removeObject(forKey: workdayEndKey)
        }

        let alreadyPassedToday = end?.shouldFire(
            now: Date(),
            lastFired: nil,
            calendar: calendar
        ) ?? false

        if alreadyPassedToday {
            UserDefaults.standard.set(Date(), forKey: workdayEndLastFiredKey)
        } else {
            UserDefaults.standard.removeObject(forKey: workdayEndLastFiredKey)
        }

        refresh()
    }

    private func endWorkdayIfDue(active: (Date, String)?) {
        guard active != nil, let end = workdayEnd else {
            return
        }

        let lastFired = UserDefaults.standard.object(forKey: workdayEndLastFiredKey) as? Date

        guard end.shouldFire(now: Date(), lastFired: lastFired, calendar: calendar) else {
            return
        }

        UserDefaults.standard.set(Date(), forKey: workdayEndLastFiredKey)
        quitTunnelblick()
    }

    // Quitting Tunnelblick does NOT tear down an established tunnel: its openvpn
    // processes are root daemons that outlive it, so the tracker would keep the
    // session open forever. Disconnect first, wait for the configurations to
    // report EXITING, and only then quit.
    //
    // The outer timeout turns a hang into a logged failure instead of an osascript
    // process left running until the next reboot.
    private static let quitTunnelblickScript = """
    with timeout of 120 seconds
        tell application "Tunnelblick"
            disconnect all

            set waited to 0
            repeat while waited < 60
                if (count of (configurations whose state is not "EXITING")) is 0 then exit repeat
                delay 1
                set waited to waited + 1
            end repeat

            set stuck to (count of (configurations whose state is not "EXITING"))
            set summary to "disconnect took " & waited & "s, still connected: " & stuck
            quit
            return summary
        end tell
    end timeout
    """

    private func quitTunnelblick() {
        let process = Process()
        let errors = Pipe()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.quitTunnelblickScript]
        process.standardError = errors
        process.standardOutput = output
        process.terminationHandler = { [weak self] finished in
            let report = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if finished.terminationStatus == 0 {
                self?.log("workday end: \(report.isEmpty ? "closed Tunnelblick" : report)")
            } else {
                self?.log("workday end: osascript exit \(finished.terminationStatus): \(message)")
            }
        }

        do {
            try process.run()
        } catch {
            log("workday end: could not run osascript: \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
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

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func autostartEnabled() -> Bool {
        FileManager.default.fileExists(atPath: agentPath)
    }

    @objc private func toggleAutostart() {
        if autostartEnabled() {
            runLaunchctl(["unload", agentPath])
            try? FileManager.default.removeItem(atPath: agentPath)
        } else {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(agentLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/bin/open</string>
                    <string>\(Bundle.main.bundlePath)</string>
                </array>
                <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: agentPath, atomically: true, encoding: .utf8)
            runLaunchctl(["load", agentPath])
        }

        refresh()
    }

    private func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try? process.run()
    }

    @objc private func revealCSV() {
        let path = NSString(string: "~/.vpn-sessions.csv").expandingTildeInPath
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
