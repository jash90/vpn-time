import AppKit
import VPNTimeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = VPNStore(
        csvPath: dataPath(".vpn-sessions.csv"),
        statePath: dataPath(".vpn-sessions.state"),
        activityCSVPath: dataPath(".vpn-activity.csv"),
        activityStatePath: dataPath(".vpn-activity.state"),
        stopPath: dataPath(".vpn-sessions.stop")
    )
    private let calendar = Calendar.vpnTimeISO
    private let agentLabel = "com.redge.vpntimebar"
    private let workdayEndKey = "workdayEndMinutes"
    private let workdayEndModeKey = "workdayEndMode"
    private let workdayEndAfterKey = "workdayEndAfterMinutes"
    private let workdayEndLastFiredKey = "workdayEndLastFired"
    private let workdayStartManualKey = "workdayStartManual"
    private let workdayStartDetectionKey = "workdayStartDetection"
    private let workdayEndDetectionKey = "workdayEndDetection"
    private let workdayEndManualKey = "workdayEndManual"
    private let workdayEndManualSourceKey = "workdayEndManualSource"
    private let updateLastCheckKey = "updateLastCheck"
    private let idleThresholdKey = "idleThresholdSeconds"
    private let idleRepeatKey = "idleRepeatSeconds"
    private let idleGraceKey = "idleGraceSeconds"
    private let idleDisconnectKey = "idleDisconnectVPN"
    // When inactivity ended today's workday (the decision, not the end).
    private let workdayStoppedKey = "workdayStoppedAt"
    // Set once that stop actually took the VPN down.
    private let workdayStopDisconnectedKey = "workdayStopDisconnected"
    private var timer: Timer?
    private var idleTimer: Timer?
    private var idlePromptState: IdleWatch.Prompt?
    private var idleAnsweredAt: Date?
    private var lastInputSeen: Date?
    private var lastBackfillDay: Date?
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
    private lazy var settingsWindow = SettingsWindow(calendar: calendar)

    // The data files live in the home folder. VPNTIME_DATA_DIR points the app
    // at another folder, so it can be exercised without touching real data.
    private static func dataPath(_ name: String) -> String {
        let folder = ProcessInfo.processInfo.environment["VPNTIME_DATA_DIR"] ?? NSHomeDirectory()
        return (folder as NSString).appendingPathComponent(name)
    }

    private var agentPath: String {
        NSString(string: "~/Library/LaunchAgents/\(agentLabel).plist").expandingTildeInPath
    }

    private lazy var dayClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private lazy var clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageLeading
        backfillHistoryIfNewDay()
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
        let (sessions, active) = currentSessions()

        resumeIfReconnected(active: active)
        workdayStart = resolveStart(sessions: sessions, active: active)
        backfillHistoryIfNewDay()
        history.record(
            workdayStart.flatMap { $0.provisional ? nil : $0 },
            end: todayEnd,
            day: Date()
        )

        statusItem.button?.title = menuBarCounter(sessions: sessions, active: active)

        if let active {
            statusItem.button?.image = MenuBarIcon.connected
            statusItem.button?.toolTip = L("tooltip.vpnActive", active.1)
        } else {
            statusItem.button?.image = MenuBarIcon.disconnected
            statusItem.button?.toolTip = L("tooltip.vpnDisconnected")
        }

        rebuildMenu(sessions: sessions, active: active)
        workdayDays.refreshIfOpen()
        endWorkdayIfDue(active: active)
        checkForUpdatesIfDue()
    }

    // The sessions as the menu should count them: one the app has already
    // ended (inactivity) is finished, even before the tracker sees the
    // VPN go down.
    private func currentSessions() -> (sessions: [Session], active: (Date, String)?) {
        StopRequest.settle(sessions: store.sessions(), active: store.activeSession(), stop: store.stopRequest())
    }

    private func currentActive() -> (Date, String)? {
        StopRequest.settle(sessions: [], active: store.activeSession(), stop: store.stopRequest()).active
    }

    // The running workday, which stops with it; without a detected workday,
    // today's time on the VPN while it is up.
    private func menuBarCounter(sessions: [Session], active: (Date, String)?) -> String {
        if let start = workdayStart, !start.provisional {
            let plannedEndPassed = todayEnd.map { $0.source == .planned && $0.date <= Date() } ?? false

            // Without end detection nothing would stop the counter once the
            // VPN is down, so it then stops with the VPN, as it used to.
            guard stoppedAt == nil, !plannedEndPassed, active != nil || endDetectionEnabled else {
                return ""
            }

            return counter(max(0, Int(Date().timeIntervalSince(start.date))))
        }

        guard active != nil else {
            return ""
        }

        return counter(Totals(calendar: calendar, now: Date()).total(.today, sessions: sessions, active: active))
    }

    private func rebuildMenu(sessions: [Session], active: (Date, String)?) {
        let totals = Totals(calendar: calendar, now: Date())
        let menu = NSMenu()

        menu.addItem(disabled(L("menu.title")))
        menu.addItem(.separator())
        menu.addItem(disabled(L("menu.today", hoursMinutes(totals.total(.today, sessions: sessions, active: active)))))
        menu.addItem(disabled(L("menu.thisWeek", hoursMinutes(totals.total(.week, sessions: sessions, active: active)))))
        menu.addItem(disabled(L("menu.thisMonth", hoursMinutes(totals.total(.month, sessions: sessions, active: active)))))
        menu.addItem(.separator())

        if let active {
            // A session from an earlier day names its date.
            let since = calendar.isDateInToday(active.0) ? clock.string(from: active.0) : dayClock.string(from: active.0)
            menu.addItem(disabled(L("menu.connected", active.1, since)))
        } else {
            menu.addItem(disabled(L("menu.disconnected")))
        }

        menu.addItem(disabled(workedLine()))

        menu.addItem(.separator())

        menu.addItem(action(
            L("menu.workStart", manualStart.map { L("menu.workStart.manual", clock.string(from: $0)) } ?? L("menu.workStart.auto")),
            #selector(openWorkdayForm)
        ))
        menu.addItem(workdayEndItem())
        menu.addItem(action(L("menu.workdays"), #selector(openWorkdayDays)))

        menu.addItem(.separator())
        let settings = action(L("menu.settings"), #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(action(L("menu.showHistory"), #selector(revealCSV)))
        menu.addItem(action(L("menu.refresh"), #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(disabled(L("menu.version", updater.currentVersionString)))
        menu.addItem(updateItem())
        menu.addItem(.separator())
        menu.addItem(action(L("menu.quit"), #selector(quit)))

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
            vpnStarts: vpnStarts(sessions: sessions, active: active),
            carriedOver: carriedOver(sessions: sessions, active: active)
        )
    }

    // The session that began before today and ran into it, if any: the one
    // still up, or one closed today (by inactivity, say).
    private func carriedOver(sessions: [Session], active: (Date, String)?) -> DateInterval? {
        let today = calendar.startOfDay(for: Date())

        if let active, active.0 < today {
            return DateInterval(start: active.0, end: max(active.0, Date()))
        }

        return sessions
            .filter { $0.start < today && $0.start.addingTimeInterval(TimeInterval($0.duration)) > today }
            .map { DateInterval(start: $0.start, duration: TimeInterval($0.duration)) }
            .max { $0.end < $1.end }
    }

    private func resolveCurrentStart() -> WorkdayStart? {
        let (sessions, active) = currentSessions()
        return resolveStart(sessions: sessions, active: active)
    }

    private func backfillHistory() {
        guard detectionEnabled else {
            return
        }

        history.backfill(
            detector: detector,
            endDetector: WorkdayEndDetector(calendar: calendar),
            // The end-detection toggle only governs the question; past ends
            // always take the activity after the disconnect into account.
            useActivityForEnd: true,
            streaks: store.activityStreaks(),
            sessions: currentSessions().sessions,
            today: Date()
        )
    }

    // Backfill also runs once per calendar day, so an app left running for
    // days still fills in yesterday's end once the day turns.
    private func backfillHistoryIfNewDay() {
        let today = calendar.startOfDay(for: Date())

        guard lastBackfillDay != today else {
            return
        }

        // A session still running from an earlier day is missing from the
        // closed sessions, so that day's end would be settled too early.
        // Retry on a later refresh, once it has been closed.
        if let active = currentActive(), active.0 < today {
            return
        }

        lastBackfillDay = today
        backfillHistory()
    }

    // Wall-clock time since the start; breaks are not subtracted.
    private func workedLine() -> String {
        guard let start = workdayStart else {
            return L("menu.worked.none")
        }

        let source = WorkdayForm.label(for: start)

        if let end = stoppedAt {
            let worked = max(0, Int(end.timeIntervalSince(start.date)))
            return L("menu.worked.range", clock.string(from: start.date), clock.string(from: end), source, hoursMinutes(worked))
        }

        let worked = max(0, Int(Date().timeIntervalSince(start.date)))
        return L("menu.worked.since", clock.string(from: start.date), source, hoursMinutes(worked))
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
    // table or by the inactivity question, otherwise the one the end rule
    // plans. It only feeds the history; closing Tunnelblick still follows
    // the rule.
    private var todayEnd: WorkdayEndPoint? {
        if let manual = today(workdayEndManualKey) {
            let source = WorkdayEndSource(
                rawValue: UserDefaults.standard.string(forKey: workdayEndManualSourceKey) ?? ""
            ) ?? .manual
            return WorkdayEndPoint(date: manual, source: source)
        }

        guard let start = workdayStart?.date,
              let planned = workdayEndRule?.trigger(now: Date(), start: start, calendar: calendar),
              planned > start else {
            return nil
        }

        return WorkdayEndPoint(date: planned, source: .planned)
    }

    private var detectionEnabled: Bool {
        UserDefaults.standard.object(forKey: workdayStartDetectionKey) as? Bool ?? true
    }

    private var endDetectionEnabled: Bool {
        UserDefaults.standard.object(forKey: workdayEndDetectionKey) as? Bool ?? true
    }

    @objc private func openWorkdayForm() {
        workdayForm.show(
            manualStart: manualStart,
            detectionEnabled: detectionEnabled,
            endRule: workdayEndRule,
            detected: detectedStart(),
            save: { [weak self] start in self?.applyTodayStart(start) }
        )
    }

    @objc private func openSettings() {
        let shown = currentSettings
        settingsWindow.show(
            settings: shown,
            save: { [weak self] settings in self?.applySettings(settings, shown: shown) }
        )
    }

    private var currentSettings: AppSettings {
        let watch = idleWatch
        return AppSettings(
            launchAtLogin: autostartEnabled(),
            detectionEnabled: detectionEnabled,
            endRule: workdayEndRule,
            endDetectionEnabled: endDetectionEnabled,
            idleThreshold: watch.threshold,
            idleRepeat: watch.repeatInterval,
            idleGrace: watch.grace,
            idleDisconnect: idleDisconnectEnabled
        )
    }

    // What detection alone finds today, shown next to "Automatycznie".
    private func detectedStart() -> WorkdayStart? {
        let (sessions, active) = currentSessions()
        return detector.resolve(
            now: Date(),
            manual: nil,
            detectionEnabled: true,
            streaks: store.activityStreaks(),
            vpnStarts: vpnStarts(sessions: sessions, active: active),
            carriedOver: carriedOver(sessions: sessions, active: active)
        )
    }

    @objc private func openWorkdayDays() {
        workdayDays.show(saveToday: { [weak self] start, end in self?.applyToday(start: start, end: end) })
    }

    // MARK: - Inactivity

    private var idleWatch: IdleWatch {
        let defaults = UserDefaults.standard
        let threshold = defaults.object(forKey: idleThresholdKey) as? Double ?? IdleWatch.defaultThreshold
        // Re-asking used to follow the threshold; keep that until it is set.
        return IdleWatch(
            threshold: threshold,
            grace: defaults.object(forKey: idleGraceKey) as? Double ?? IdleWatch.defaultGrace,
            repeatInterval: defaults.object(forKey: idleRepeatKey) as? Double ?? threshold
        )
    }

    private var idleDisconnectEnabled: Bool {
        UserDefaults.standard.object(forKey: idleDisconnectKey) as? Bool ?? true
    }

    // Watches a workday that is still running; the VPN no longer has to be
    // up, so walking away after disconnecting still ends the day. A session
    // still running from an earlier day is watched too.
    private func watchIdle() {
        guard let idle = IdleTime.seconds() else {
            return
        }

        let now = Date()
        let watch = idleWatch
        // The start is refreshed every 15 s, so right after midnight (or a
        // wake from sleep) it can still be yesterday's.
        let start = IdleWatch.watchedStart(
            workdayStart: workdayStart,
            connectedSince: carriedOverSession(),
            now: now,
            calendar: calendar
        )
        let watching = endDetectionEnabled && start != nil && stoppedAt == nil

        // Input from before today's start (yesterday evening, before the lid
        // closed) is no break inside this workday.
        if !watching || lastInputSeen.map({ $0 < start ?? now }) == true {
            lastInputSeen = nil
        }

        switch watch.evaluate(
            now: now,
            idleSeconds: idle,
            watching: watching,
            workdayStart: start,
            prompt: idlePromptState,
            answeredAt: idleAnsweredAt,
            previousInput: lastInputSeen
        ) {
        case .none:
            break
        case .ask(let idleSince):
            let prompt = IdleWatch.Prompt(shownAt: now, idleSince: idleSince)
            idlePromptState = prompt
            appLog("idle: no input since \(clock.string(from: idleSince)), asking")
            // A break noticed only after it ended asks from before the current
            // last input; the question then names the whole window.
            let lastInput = now.addingTimeInterval(-idle)
            idlePrompt.show(
                idleSince: idleSince,
                until: idleSince < lastInput ? lastInput : nil,
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
            appLog("idle: question withdrawn (workday over or detection off)")
            idlePromptState = nil
            idlePrompt.dismiss()
        }

        if watching {
            lastInputSeen = now.addingTimeInterval(-idle)
        }
    }

    private func keepWorking() {
        appLog("idle: still working")
        idlePromptState = nil
        idleAnsweredAt = Date()
    }

    // Ends the workday at `end`: the end becomes today's manual end, so the
    // menu counter stops and the history row gets it. Unless switched off in
    // the settings the VPN goes down too, and its session ends at `end`, so
    // the inactivity is not counted as time on the VPN either.
    private func stopWorkday(at end: Date, reason: String) {
        appLog("idle: workday stopped at \(clock.string(from: end)) (\(reason))")
        idlePromptState = nil
        idlePrompt.dismiss()
        UserDefaults.standard.set(end, forKey: workdayEndManualKey)
        UserDefaults.standard.set(WorkdayEndSource.idle.rawValue, forKey: workdayEndManualSourceKey)
        UserDefaults.standard.set(Date(), forKey: workdayStoppedKey)
        UserDefaults.standard.removeObject(forKey: workdayStopDisconnectedKey)
        disconnectAfterStop(at: end)
        refresh()
    }

    // The start of the running session, unless inactivity has already ended
    // it once: with disconnecting off it keeps running, and must not be asked
    // about again and again.
    private func carriedOverSession() -> Date? {
        guard let start = currentActive()?.0 else {
            return nil
        }

        if let stopped = UserDefaults.standard.object(forKey: workdayStoppedKey) as? Date, stopped > start {
            return nil
        }

        return start
    }

    private func disconnectAfterStop(at end: Date) {
        guard idleDisconnectEnabled, let active = currentActive() else {
            return
        }

        // Written before disconnecting: the tracker may notice the VPN going
        // down before the disconnect call even returns.
        let request = StopRequest(sessionStart: active.0, end: max(end, active.0))
        store.requestStop(request)
        appLog("idle: disconnecting the VPN, session ends at \(clock.string(from: request.end))")

        quitTunnelblick(context: "idle stop") { [weak self] disconnected in
            guard let self else {
                return
            }

            guard !disconnected else {
                UserDefaults.standard.set(true, forKey: self.workdayStopDisconnectedKey)
                return
            }

            // The VPN stayed up, so later work must not be cut off at `end`.
            self.store.clearStopRequest()
            self.refresh()
        }
    }

    // A VPN connection made after inactivity ended today's workday and took
    // the VPN down means the work goes on: the end set by the inactivity is
    // dropped. While the VPN stayed up, a session the poller split at a wake
    // is no reconnect, so nothing resumes then.
    private func resumeIfReconnected(active: (Date, String)?) {
        let defaults = UserDefaults.standard

        guard let active,
              defaults.bool(forKey: workdayStopDisconnectedKey),
              let stopped = defaults.object(forKey: workdayStoppedKey) as? Date,
              calendar.isDate(stopped, inSameDayAs: Date()),
              active.0 > stopped,
              today(workdayEndManualKey) != nil,
              defaults.string(forKey: workdayEndManualSourceKey) == WorkdayEndSource.idle.rawValue else {
            return
        }

        appLog("idle: workday resumed, VPN connected at \(clock.string(from: active.0))")
        defaults.removeObject(forKey: workdayEndManualKey)
        defaults.removeObject(forKey: workdayEndManualSourceKey)
        defaults.removeObject(forKey: workdayStoppedKey)
        defaults.removeObject(forKey: workdayStopDisconnectedKey)
    }

    // Saving the "Dziś" form: today's manual start is set (or cleared), and
    // a day the question or the days table already stopped resumes — the
    // settings define the planned end again.
    private func applyTodayStart(_ manualStart: Date?) {
        let defaults = UserDefaults.standard

        if let start = manualStart {
            defaults.set(start, forKey: workdayStartManualKey)
        } else {
            defaults.removeObject(forKey: workdayStartManualKey)
        }

        defaults.removeObject(forKey: workdayEndManualKey)
        defaults.removeObject(forKey: workdayEndManualSourceKey)

        workdayStart = resolveCurrentStart()
        markWorkdayEndFiredIfPassed()
        refresh()
    }

    // Saving the settings window. Tuning only the end detection or autostart
    // must not resume a day it already stopped; changing the end rule or the
    // start detection still does.
    // `shown` is what the window loaded: the login item is only touched when
    // its checkbox changed, not when the agent file changed meanwhile.
    private func applySettings(_ settings: AppSettings, shown: AppSettings) {
        let defaults = UserDefaults.standard
        let ruleChanged = settings.endRule != workdayEndRule
        let startDetectionChanged = settings.detectionEnabled != detectionEnabled

        if settings.launchAtLogin != shown.launchAtLogin {
            setAutostart(settings.launchAtLogin)
        }

        defaults.set(settings.detectionEnabled, forKey: workdayStartDetectionKey)
        defaults.set(settings.endDetectionEnabled, forKey: workdayEndDetectionKey)
        defaults.set(settings.idleThreshold, forKey: idleThresholdKey)
        defaults.set(settings.idleRepeat, forKey: idleRepeatKey)
        defaults.set(settings.idleGrace, forKey: idleGraceKey)
        defaults.set(settings.idleDisconnect, forKey: idleDisconnectKey)

        // The settings define the planned end again; an end typed into the
        // days table for today no longer applies.
        if ruleChanged || startDetectionChanged {
            defaults.removeObject(forKey: workdayEndManualKey)
            defaults.removeObject(forKey: workdayEndManualSourceKey)
        }

        // Past rows are filled with the detection that is on now.
        if startDetectionChanged {
            lastBackfillDay = nil
        }

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
        // rule may fire again today.
        if ruleChanged {
            defaults.removeObject(forKey: workdayEndLastFiredKey)
        }

        workdayStart = resolveCurrentStart()
        markWorkdayEndFiredIfPassed()
        // An open "Dziś" window previews with the detection and end rule.
        workdayForm.updatePreviewIfOpen(detectionEnabled: detectionEnabled, endRule: workdayEndRule)
        refresh()
    }

    // Today's row edited in the days table: its start becomes today's manual
    // start, its end is kept for the history.
    private func applyToday(start: Date, end: Date) {
        UserDefaults.standard.set(start, forKey: workdayStartManualKey)
        UserDefaults.standard.set(end, forKey: workdayEndManualKey)
        UserDefaults.standard.set(WorkdayEndSource.manual.rawValue, forKey: workdayEndManualSourceKey)
        workdayStart = resolveCurrentStart()
        markWorkdayEndFiredIfPassed()
        // An open "Dziś" form would otherwise save its stale start over the
        // one just set, and drop today's end with it.
        workdayForm.reloadIfOpen(
            manualStart: manualStart,
            detectionEnabled: detectionEnabled,
            endRule: workdayEndRule,
            detected: detectedStart()
        )
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
            L("menu.workEnd", workdayEndRule?.label ?? L("menu.workEnd.off")),
            #selector(openSettings)
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
        quitTunnelblick(context: "workday end")
    }

    // Quitting Tunnelblick does NOT tear down an established tunnel: its openvpn
    // processes are root daemons that outlive it, so the tracker would keep the
    // session open forever. Disconnect first, wait for the daemons to actually go
    // away, and only then quit.
    //
    // The wait watches the process list rather than Tunnelblick's own scripting
    // state, which cannot be counted or iterated over from AppleScript.
    // `done` runs on the main queue with whether the tunnel went down.
    private func quitTunnelblick(context: String, done: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let disconnect = Self.runScript("tell application \"Tunnelblick\" to disconnect all")

            guard disconnect.isEmpty else {
                appLog("\(context): disconnect failed: \(disconnect)")
                DispatchQueue.main.async { done?(false) }
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
                appLog("\(context): disconnected in \(waited)s, still up: \(stuck), Tunnelblick closed")
            } else {
                appLog("\(context): disconnected in \(waited)s, quit failed: \(quit)")
            }

            DispatchQueue.main.async { done?(!stuck) }
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
            return action(L("menu.update.check"), #selector(checkForUpdates))
        case .checking:
            return disabled(L("menu.update.checking"))
        case .available(let update):
            return action(L("menu.update.install", update.tag), #selector(offerUpdate))
        case .installing:
            return disabled(L("menu.update.downloading"))
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
                    self.alert(L("alert.upToDate", self.updater.currentVersionString))
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
                    self.alert(L("alert.checkFailed"), info: error.localizedDescription)
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
        alert.messageText = L("alert.update.title", update.tag)
        alert.informativeText = L("alert.update.installed", updater.currentVersionString)
            + (shortNotes.isEmpty ? "" : "\n\n" + shortNotes)
            + "\n\n" + L("alert.update.restart")
        alert.addButton(withTitle: L("button.install"))
        alert.addButton(withTitle: L("button.later"))
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
            self?.alert(L("alert.installFailed"), info: error.localizedDescription)
        }
    }

    private func offerManualInstall(tag: String, pageURL: URL?) {
        let alert = NSAlert()
        alert.messageText = L("alert.unverifiable.title", tag)
        alert.informativeText = L("alert.unverifiable.body")
        alert.addButton(withTitle: L("button.openReleasePage"))
        alert.addButton(withTitle: L("button.ok"))
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

    // Called from the settings window, only when its checkbox changed.
    private func setAutostart(_ enabled: Bool) {
        if enabled {
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
        } else {
            runLaunchctl(["unload", agentPath])
            try? FileManager.default.removeItem(atPath: agentPath)
        }
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
