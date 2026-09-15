import AppKit
import VPNTimeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = VPNStore()
    private let calendar = Calendar.vpnTimeISO
    private let agentLabel = "com.redge.vpntimebar"
    private var timer: Timer?

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

        menu.addItem(.separator())
        menu.addItem(action("Pokaż plik z historią", #selector(revealCSV)))
        menu.addItem(action("Odśwież", #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(action("Zakończ", #selector(quit)))

        statusItem.menu = menu
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
