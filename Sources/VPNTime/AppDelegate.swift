import AppKit
import VPNTimeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = VPNStore(
        csvPath: dataPath(".vpn-sessions.csv"),
        statePath: dataPath(".vpn-sessions.state"),
        activityCSVPath: dataPath(".vpn-activity.csv"),
        activityStatePath: dataPath(".vpn-activity.state")
    )
    private let calendar = Calendar.vpnTimeISO
    private let agentLabel = "com.redge.vpntimebar"
    private let workdayEndKey = "workdayEndMinutes"
    private let workdayEndModeKey = "workdayEndMode"
    private let workdayEndAfterKey = "workdayEndAfterMinutes"
    private let workdayEndLastFiredKey = "workdayEndLastFired"
    private let workdayStartManualKey = "workdayStartManual"
    private let workdayStartDetectionKey = "workdayStartDetection"
    private let workdayEndManualKey = "workdayEndManual"
    private let updateLastCheckKey = "updateLastCheck"
    private let idleThresholdKey = "idleThresholdSeconds"
    private let idleGraceKey = "idleGraceSeconds"
    private var timer: Timer?
    private var idleTimer: Timer?
    private var idlePromptState: IdleWatch.Prompt?
    private var idleAnsweredAt: Date?
    private let idlePrompt = IdlePrompt()
    private let updater = Updater()
    private var updateState = UpdateState.idle

    private enum UpdateState {
        case idle
        case checking(manual: Bool)
        case available(AvailableUpdate)
        case installing
    }
    private var workdayStart: WorkdayStart?
    private lazy var detector = WorkdayStartDetector(calendar: calendar)
    private lazy var history = WorkdayHistory(path: Self.dataPath(".vpn-workdays.csv"), calendar: calendar)
    private lazy var workdayForm = WorkdayForm(calendar: calendar)
    private lazy var workdayDays = WorkdayDays(calendar: calendar, history: history)

    // The data files live in the home folder. VPNTIME_DATA_DIR points the app
    // at another folder, so it can be exercised without touching real data.
    private static func dataPath(_ name: String) -> String {
        let folder = ProcessInfo.processInfo.environment["VPNTIME_DATA_DIR"] ?? NSHomeDirectory()
        return (folder as NSString).appendingPathComponent(name)
    }

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
        backfillHistory()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Common modes, so the countdown also runs while a menu or alert is open.
        let idleTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.watchIdle()
        }
        RunLoop.main.add(idleTimer, forMode: .common)
        self.idleTimer = idleTimer
    }

    @objc private func refresh() {
        let sessions = store.sessions()
        let active = store.activeSession()

        workdayStart = resolveStart(sessions: sessions, active: active)
        history.record(workdayStart.flatMap { $0.provisional ? nil : $0 }, end: todayEnd, day: Date())

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
        workdayDays.refreshIfOpen()
        endWorkdayIfDue(active: active)
        checkForUpdatesIfDue()
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

        menu.addItem(disabled(workedLine()))

        menu.addItem(.separator())

        let autostart = NSMenuItem(
            title: "Uruchamiaj przy logowaniu",
            action: #selector(toggleAutostart),
            keyEquivalent: ""
        )
        autostart.target = self
        autostart.state = autostartEnabled() ? .on : .off
        menu.addItem(autostart)
        menu.addItem(action(
            "Początek pracy: " + (manualStart.map { "ręcznie " + clock.string(from: $0) } ?? "auto"),
            #selector(openWorkdayForm)
        ))

        let detection = action("Wykrywaj początek pracy", #selector(toggleDetection))
        detection.state = detectionEnabled ? .on : .off
        menu.addItem(detection)
        menu.addItem(workdayEndItem())
        menu.addItem(action("Dni pracy…", #selector(openWorkdayDays)))

        menu.addItem(.separator())
        menu.addItem(action("Pokaż plik z historią", #selector(revealCSV)))
        menu.addItem(action("Odśwież", #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(disabled("Wersja \(updater.currentVersionString)"))
        menu.addItem(updateItem())
        menu.addItem(.separator())
        menu.addItem(action("Zakończ", #selector(quit)))

        statusItem.menu = menu
    }

    private func vpnStarts(sessions: [Session], active: (Date, String)?) -> [Date] {
        sessions.map(\.start) + (active.map { [$0.0] } ?? [])
    }

    private func resolveStart(sessions: [Session], active: (Date, String)?) -> WorkdayStart? {
        detector.resolve(
            now: Date(),
            manual: manualStart,
            detectionEnabled: detectionEnabled,
            streaks: store.activityStreaks(),
            vpnStarts: vpnStarts(sessions: sessions, active: active)
        )
    }

    private func backfillHistory() {
        guard detectionEnabled else {
            return
        }

        history.backfill(
            detector: detector,
            streaks: store.activityStreaks(),
            sessions: store.sessions(),
            today: Date()
        )
    }

    // Wall-clock time since the start; breaks are not subtracted.
    private func workedLine() -> String {
        guard let start = workdayStart else {
            return "Praca: nie wykryto"
        }

        let source = WorkdayForm.label(for: start)

        if let end = stoppedAt {
            let worked = max(0, Int(end.timeIntervalSince(start.date)))
            return "Praca \(clock.string(from: start.date))–\(clock.string(from: end)) (\(source)) · " + hoursMinutes(worked)
        }

        let worked = max(0, Int(Date().timeIntervalSince(start.date)))
        return "Praca od \(clock.string(from: start.date)) (\(source)) · " + hoursMinutes(worked)
    }

    // Today's end set by hand (the days table, or an unanswered inactivity
    // question) once it has passed: the workday is over and its counter stops.
    private var stoppedAt: Date? {
        today(workdayEndManualKey).flatMap { $0 <= Date() ? $0 : nil }
    }

    // Only today's manual values count; older ones are left in the defaults
    // and simply ignored until they are overwritten.
    private func today(_ key: String) -> Date? {
        guard let date = UserDefaults.standard.object(forKey: key) as? Date,
              calendar.isDate(date, inSameDayAs: Date()) else {
            return nil
        }

        return date
    }

    private var manualStart: Date? {
        today(workdayStartManualKey)
    }

    // The end written to today's history row: one set by hand in the days
    // table, otherwise the one the end rule plans. It only feeds the history;
    // closing Tunnelblick still follows the rule.
    private var todayEnd: Date? {
        if let manual = today(workdayEndManualKey) {
            return manual
        }

        guard let start = workdayStart?.date,
              let planned = workdayEndRule?.trigger(now: Date(), start: start, calendar: calendar),
              planned > start else {
            return nil
        }

        return planned
    }

    private var detectionEnabled: Bool {
        UserDefaults.standard.object(forKey: workdayStartDetectionKey) as? Bool ?? true
    }

    @objc private func toggleDetection() {
        UserDefaults.standard.set(!detectionEnabled, forKey: workdayStartDetectionKey)
        refresh()
    }

    @objc private func openWorkdayForm() {
        let sessions = store.sessions()
        let active = store.activeSession()
        let detected = detector.resolve(
            now: Date(),
            manual: nil,
            detectionEnabled: true,
            streaks: store.activityStreaks(),
            vpnStarts: vpnStarts(sessions: sessions, active: active)
        )
        let settings = WorkdaySettings(
            manualStart: manualStart,
            detectionEnabled: detectionEnabled,
            endRule: workdayEndRule
        )

        workdayForm.show(
            settings: settings,
            detected: detected,
            save: { [weak self] settings in self?.applyWorkdaySettings(settings) }
        )
    }

    @objc private func openWorkdayDays() {
        workdayDays.show(saveToday: { [weak self] start, end in self?.applyToday(start: start, end: end) })
    }

    // MARK: - Inactivity

    private var idleWatch: IdleWatch {
        let defaults = UserDefaults.standard
        return IdleWatch(
            threshold: defaults.object(forKey: idleThresholdKey) as? Double ?? IdleWatch.defaultThreshold,
            grace: defaults.object(forKey: idleGraceKey) as? Double ?? IdleWatch.defaultGrace
        )
    }

    // Watches only during a VPN session inside a workday that is still running.
    private func watchIdle() {
        guard let idle = IdleTime.seconds() else {
            return
        }

        let now = Date()
        let watch = idleWatch
        let start = workdayStart.flatMap { $0.provisional ? nil : $0.date }
        let watching = store.activeSession() != nil && start != nil && stoppedAt == nil

        switch watch.evaluate(
            now: now,
            idleSeconds: idle,
            watching: watching,
            workdayStart: start,
            prompt: idlePromptState,
            answeredAt: idleAnsweredAt
        ) {
        case .none:
            break
        case .ask(let idleSince):
            let prompt = IdleWatch.Prompt(shownAt: now, idleSince: idleSince)
            idlePromptState = prompt
            appLog("idle: no input since \(clock.string(from: idleSince)), asking")
            idlePrompt.show(
                idleSince: idleSince,
                stopAt: max(idleSince, start ?? idleSince),
                deadline: watch.deadline(of: prompt),
                keepWorking: { [weak self] in self?.keepWorking() },
                endNow: { [weak self] in
                    self?.stopWorkday(at: max(idleSince, start ?? idleSince), reason: "ended from the question")
                }
            )
        case .stop(let end):
            stopWorkday(at: end, reason: "no answer in \(Int(watch.grace))s")
        case .withdraw:
            appLog("idle: question withdrawn (VPN gone or workday over)")
            idlePromptState = nil
            idlePrompt.dismiss()
        }
    }

    private func keepWorking() {
        appLog("idle: still working")
        idlePromptState = nil
        idleAnsweredAt = Date()
    }

    // Ends today at `end`: the end becomes today's manual end, so the menu
    // counter stops and the history row gets it. The VPN stays connected.
    private func stopWorkday(at end: Date, reason: String) {
        appLog("idle: workday stopped at \(clock.string(from: end)) (\(reason))")
        idlePromptState = nil
        idlePrompt.dismiss()
        UserDefaults.standard.set(end, forKey: workdayEndManualKey)
        refresh()
    }

    private func applyWorkdaySettings(_ settings: WorkdaySettings) {
        let defaults = UserDefaults.standard
        let ruleChanged = settings.endRule != workdayEndRule

        if let start = settings.manualStart {
            defaults.set(start, forKey: workdayStartManualKey)
        } else {
            defaults.removeObject(forKey: workdayStartManualKey)
        }

        defaults.set(settings.detectionEnabled, forKey: workdayStartDetectionKey)
        // The settings define the planned end again; an end typed into the
        // days table for today no longer applies.
        defaults.removeObject(forKey: workdayEndManualKey)

        switch settings.endRule {
        case .fixed(let end):
            defaults.set("fixed", forKey: workdayEndModeKey)
            defaults.set(end.minutesOfDay, forKey: workdayEndKey)
        case .afterStart(let minutes):
            defaults.set("afterStart", forKey: workdayEndModeKey)
            defaults.set(minutes, forKey: workdayEndAfterKey)
        case nil:
            defaults.removeObject(forKey: workdayEndModeKey)
            defaults.removeObject(forKey: workdayEndKey)
            defaults.removeObject(forKey: workdayEndAfterKey)
        }

        // Saving must not close the VPN on the spot: an end that has already
        // passed with the new settings only takes effect tomorrow. A new end
        // rule may fire again today; moving only the start may not.
        if ruleChanged {
            defaults.removeObject(forKey: workdayEndLastFiredKey)
        }

        workdayStart = resolveStart(sessions: store.sessions(), active: store.activeSession())
        markWorkdayEndFiredIfPassed()
        refresh()
    }

    // Today's row edited in the days table: its start becomes today's manual
    // start, its end is kept for the history.
    private func applyToday(start: Date, end: Date) {
        UserDefaults.standard.set(start, forKey: workdayStartManualKey)
        UserDefaults.standard.set(end, forKey: workdayEndManualKey)
        workdayStart = resolveStart(sessions: store.sessions(), active: store.activeSession())
        markWorkdayEndFiredIfPassed()
        refresh()
    }

    private var workdayEndRule: WorkdayEndRule? {
        let defaults = UserDefaults.standard

        if defaults.string(forKey: workdayEndModeKey) == "afterStart" {
            return (defaults.object(forKey: workdayEndAfterKey) as? Int).map { .afterStart(minutes: $0) }
        }

        guard let minutes = defaults.object(forKey: workdayEndKey) as? Int,
              let end = WorkdayEnd(minutesOfDay: minutes) else {
            return nil
        }

        return .fixed(end)
    }

    private func workdayEndItem() -> NSMenuItem {
        action(
            "Koniec pracy: " + (workdayEndRule?.label ?? "wyłączony"),
            #selector(openWorkdayForm)
        )
    }

    private func markWorkdayEndFiredIfPassed() {
        let passed = workdayEndRule?.shouldFire(
            now: Date(),
            start: workdayStart?.date,
            lastFired: nil,
            calendar: calendar
        ) ?? false

        if passed {
            UserDefaults.standard.set(Date(), forKey: workdayEndLastFiredKey)
        }
    }

    private func endWorkdayIfDue(active: (Date, String)?) {
        guard active != nil, let rule = workdayEndRule else {
            return
        }

        let lastFired = UserDefaults.standard.object(forKey: workdayEndLastFiredKey) as? Date

        guard rule.shouldFire(now: Date(), start: workdayStart?.date, lastFired: lastFired, calendar: calendar) else {
            return
        }

        UserDefaults.standard.set(Date(), forKey: workdayEndLastFiredKey)
        quitTunnelblick()
    }

    // Quitting Tunnelblick does NOT tear down an established tunnel: its openvpn
    // processes are root daemons that outlive it, so the tracker would keep the
    // session open forever. Disconnect first, wait for the daemons to actually go
    // away, and only then quit.
    //
    // The wait watches the process list rather than Tunnelblick's own scripting
    // state, which cannot be counted or iterated over from AppleScript.
    private func quitTunnelblick() {
        DispatchQueue.global(qos: .utility).async {
            let disconnect = Self.runScript("tell application \"Tunnelblick\" to disconnect all")

            guard disconnect.isEmpty else {
                appLog("workday end: disconnect failed: \(disconnect)")
                return
            }

            var waited = 0

            while waited < 60, Self.tunnelIsUp() {
                Thread.sleep(forTimeInterval: 1)
                waited += 1
            }

            let stuck = Self.tunnelIsUp()
            let quit = Self.runScript("tell application \"Tunnelblick\" to quit")

            if quit.isEmpty {
                appLog("workday end: disconnected in \(waited)s, still up: \(stuck), Tunnelblick closed")
            } else {
                appLog("workday end: disconnected in \(waited)s, quit failed: \(quit)")
            }
        }
    }

    private static func tunnelIsUp() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "Tunnelblick.app/Contents/Resources/openvpn"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // Returns an empty string on success, otherwise the failure to log.
    private static func runScript(_ source: String) -> String {
        let process = Process()
        let errors = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "with timeout of 90 seconds\n\(source)\nend timeout"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }

        let message = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return ""
        }

        return message.isEmpty ? "exit \(process.terminationStatus)" : message
    }

    private func updateItem() -> NSMenuItem {
        switch updateState {
        case .idle:
            return action("Sprawdź aktualizacje…", #selector(checkForUpdates))
        case .checking:
            return disabled("Sprawdzanie aktualizacji…")
        case .available(let update):
            return action("Zainstaluj aktualizację \(update.tag)…", #selector(offerUpdate))
        case .installing:
            return disabled("Pobieranie aktualizacji…")
        }
    }

    // The quiet daily check only changes the menu item; it never shows a dialog.
    private func checkForUpdatesIfDue() {
        switch updateState {
        case .idle, .available:
            break
        case .checking, .installing:
            return
        }

        guard Update.isDue(lastCheck: UserDefaults.standard.object(forKey: updateLastCheckKey) as? Date, now: Date()) else {
            return
        }

        startCheck(manual: false)
    }

    @objc private func checkForUpdates() {
        startCheck(manual: true)
    }

    private func startCheck(manual: Bool) {
        let previous = updateState
        updateState = .checking(manual: manual)
        refresh()

        updater.check { [weak self] result in
            guard let self else {
                return
            }

            // Stored after every finished check, failed ones too, so being
            // offline does not trigger a new check on every refresh.
            UserDefaults.standard.set(Date(), forKey: self.updateLastCheckKey)

            switch result {
            case .success(.available(let update)):
                appLog("update: \(update.tag) available")
                self.updateState = .available(update)
                self.refresh()

                if manual {
                    self.offerUpdate()
                }
            case .success(.upToDate):
                self.updateState = .idle
                self.refresh()

                if manual {
                    self.alert("Masz najnowszą wersję (\(self.updater.currentVersionString)).")
                }
            case .success(.unverifiable(let tag, let pageURL)):
                // Never installed from here, so the quiet check only logs it.
                appLog("update: \(tag) available but unverifiable (no archive or sha256 digest)")
                self.updateState = .idle
                self.refresh()

                if manual {
                    self.offerManualInstall(tag: tag, pageURL: pageURL)
                }
            case .failure(let error):
                appLog("update: check failed: \(error.localizedDescription)")
                // A quiet check that fails (offline, say) keeps an update
                // found earlier on offer.
                if !manual, case .available = previous {
                    self.updateState = previous
                } else {
                    self.updateState = .idle
                }
                self.refresh()

                if manual {
                    self.alert("Nie udało się sprawdzić aktualizacji.", info: error.localizedDescription)
                }
            }
        }
    }

    @objc private func offerUpdate() {
        guard case .available(let update) = updateState else {
            return
        }

        let notes = update.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortNotes = notes.count > 600 ? String(notes.prefix(600)) + "…" : notes
        let alert = NSAlert()
        alert.messageText = "Dostępna wersja \(update.tag)"
        alert.informativeText = "Zainstalowana: \(updater.currentVersionString)."
            + (shortNotes.isEmpty ? "" : "\n\n" + shortNotes)
            + "\n\nPo instalacji aplikacja uruchomi się ponownie."
        alert.addButton(withTitle: "Zainstaluj")
        alert.addButton(withTitle: "Później")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        updateState = .installing
        refresh()

        // A failed install goes back to a fresh check: the release may have
        // been fixed or superseded in the meantime.
        updater.install(update) { [weak self] error in
            self?.updateState = .idle
            self?.refresh()
            self?.alert("Nie udało się zainstalować aktualizacji.", info: error.localizedDescription)
        }
    }

    private func offerManualInstall(tag: String, pageURL: URL?) {
        let alert = NSAlert()
        alert.messageText = "Dostępna wersja \(tag), ale nie da się jej zweryfikować"
        alert.informativeText = "W wydaniu brakuje archiwum aplikacji albo jego sumy SHA-256, więc "
            + "VPN Time nie zainstaluje go sam. Pobierz je ręcznie ze strony wydania."
        alert.addButton(withTitle: "Otwórz stronę wydania")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)

        let page = pageURL ?? URL(string: "https://github.com/jash90/vpn-time/releases")!

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(page)
        }
    }

    private func alert(_ message: String, info: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        NSWorkspace.shared.selectFile(Self.dataPath(".vpn-sessions.csv"), inFileViewerRootedAtPath: "")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
