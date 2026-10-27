import AppKit
import VPNTimeCore

struct AppSettings {
    var launchAtLogin: Bool
    var detectionEnabled: Bool
    var endRule: WorkdayEndRule?
    var endDetectionEnabled: Bool
    var idleThreshold: TimeInterval
    var idleRepeat: TimeInterval
    var idleGrace: TimeInterval
    var idleDisconnect: Bool
}

// The "Ustawienia" window: the persistent settings — login, detection and
// the end of work. Today's start lives in its own window, WorkdayForm.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let calendar: Calendar
    private var panel: NSPanel?
    private var save: ((AppSettings) -> Void)?

    private let launchAtLogin = NSButton(checkboxWithTitle: L("menu.launchAtLogin"), target: nil, action: nil)
    private let detection = NSButton(checkboxWithTitle: L("menu.detectStart"), target: nil, action: nil)
    private let endDetection = NSButton(checkboxWithTitle: L("menu.detectEnd"), target: nil, action: nil)
    private let idleDisconnect = NSButton(checkboxWithTitle: L("settings.idleDisconnect"), target: nil, action: nil)
    private let endOff = NSButton(radioButtonWithTitle: L("form.end.off"), target: nil, action: nil)
    private let endAt = NSButton(radioButtonWithTitle: L("form.end.at"), target: nil, action: nil)
    private let endAfter = NSButton(radioButtonWithTitle: L("form.end.after"), target: nil, action: nil)
    private lazy var endTimePicker = TimePickerPanel.picker(identifier: "workdayEndPicker", calendar: calendar)
    private lazy var durationPicker = TimePickerPanel.picker(identifier: "workdayEndDurationPicker", calendar: calendar)
    private lazy var idleThresholdPicker = TimePickerPanel.picker(identifier: "idleThresholdPicker", calendar: calendar)
    private lazy var idleRepeatPicker = TimePickerPanel.picker(identifier: "idleRepeatPicker", calendar: calendar)
    private lazy var idleGracePicker = TimePickerPanel.picker(identifier: "idleGracePicker", calendar: calendar)

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    func show(settings: AppSettings, save: @escaping (AppSettings) -> Void) {
        self.save = save

        if panel == nil {
            build()
        }

        load(settings)

        if let panel {
            TimePickerPanel.present(panel)
        }
    }

    // MARK: - Settings

    private func load(_ settings: AppSettings) {
        launchAtLogin.state = settings.launchAtLogin ? .on : .off
        detection.state = settings.detectionEnabled ? .on : .off
        endDetection.state = settings.endDetectionEnabled ? .on : .off
        idleDisconnect.state = settings.idleDisconnect ? .on : .off
        idleThresholdPicker.dateValue = durationDate(settings.idleThreshold)
        idleRepeatPicker.dateValue = durationDate(settings.idleRepeat)
        idleGracePicker.dateValue = durationDate(settings.idleGrace)

        var time = WorkdayEnd(hour: 17, minute: 0).minutesOfDay
        var duration = 8 * 60

        switch settings.endRule {
        case .fixed(let end):
            time = end.minutesOfDay
            select(endAt, among: endRadios)
        case .afterStart(let minutes):
            duration = minutes
            select(endAfter, among: endRadios)
        case nil:
            select(endOff, among: endRadios)
        }

        endTimePicker.dateValue = TimePickerPanel.date(minutes: time, calendar: calendar)
        durationPicker.dateValue = TimePickerPanel.date(minutes: duration, calendar: calendar)
        changed()
    }

    private var endRadios: [NSButton] {
        [endOff, endAt, endAfter]
    }

    private var current: AppSettings {
        var rule: WorkdayEndRule?

        if endAt.state == .on,
           let minutes = TimePickerPanel.minutes(of: endTimePicker, calendar: calendar),
           let end = WorkdayEnd(minutesOfDay: minutes) {
            rule = .fixed(end)
        } else if endAfter.state == .on,
                  let minutes = TimePickerPanel.minutes(of: durationPicker, calendar: calendar),
                  minutes > 0 {
            rule = .afterStart(minutes: minutes)
        }

        return AppSettings(
            launchAtLogin: launchAtLogin.state == .on,
            detectionEnabled: detection.state == .on,
            endRule: rule,
            endDetectionEnabled: endDetection.state == .on,
            idleThreshold: duration(of: idleThresholdPicker),
            idleRepeat: duration(of: idleRepeatPicker),
            idleGrace: duration(of: idleGracePicker),
            idleDisconnect: idleDisconnect.state == .on
        )
    }

    // The duration pickers show hh:mm, so a setting lands on whole minutes.
    // An hh:mm picker holds 00:01–23:59; values outside (a few seconds set
    // for testing, say) are shown at the nearest end.
    private func durationDate(_ seconds: TimeInterval) -> Date {
        TimePickerPanel.date(minutes: min(max(1, Int(seconds / 60)), 1439), calendar: calendar)
    }

    // A picker left at 00:00 still means one minute: without a floor the
    // question could never fire.
    private func duration(of picker: NSDatePicker) -> TimeInterval {
        let minutes = TimePickerPanel.minutes(of: picker, calendar: calendar) ?? 0
        return TimeInterval(max(1, minutes) * 60)
    }

    @objc private func changed() {
        endTimePicker.isEnabled = endAt.state == .on
        durationPicker.isEnabled = endAfter.state == .on
        let detecting = endDetection.state == .on
        idleThresholdPicker.isEnabled = detecting
        idleRepeatPicker.isEnabled = detecting
        idleGracePicker.isEnabled = detecting
        idleDisconnect.isEnabled = detecting
    }

    @objc private func chooseEnd(_ sender: NSButton) {
        select(sender, among: endRadios)
        changed()
    }

    // The radios sit in different rows, so AppKit does not group them.
    private func select(_ radio: NSButton, among group: [NSButton]) {
        group.forEach { $0.state = $0 === radio ? .on : .off }
    }

    @objc private func saveSettings() {
        save?(current)
        panel?.close()
    }

    @objc private func close() {
        panel?.close()
    }

    // MARK: - Layout

    private func build() {
        [launchAtLogin, detection, endDetection, idleDisconnect].forEach { $0.target = self; $0.action = #selector(changed) }
        endRadios.forEach { $0.target = self; $0.action = #selector(chooseEnd(_:)) }
        [endTimePicker, durationPicker, idleThresholdPicker, idleRepeatPicker, idleGracePicker]
            .forEach { $0.target = self; $0.action = #selector(changed) }

        endDetection.setAccessibilityIdentifier("endDetection")
        idleDisconnect.setAccessibilityIdentifier("idleDisconnect")

        let save = NSButton(title: L("button.save"), target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        save.setAccessibilityIdentifier("settingsSave")
        let close = NSButton(title: L("button.close"), target: self, action: #selector(close))
        close.keyEquivalent = "\u{1b}"

        panel = TimePickerPanel.panel(
            title: L("settings.title"),
            views: [
                TimePickerPanel.caption(L("settings.generalCaption")),
                launchAtLogin,
                TimePickerPanel.caption(L("settings.startCaption")),
                detection,
                TimePickerPanel.caption(L("form.endCaption")),
                endOff,
                row(endAt, endTimePicker),
                row(endAfter, durationPicker, NSTextField(labelWithString: L("form.end.afterSuffix"))),
                TimePickerPanel.caption(L("form.endDetectionCaption")),
                endDetection,
                row(
                    NSTextField(labelWithString: L("form.idle.threshold")),
                    idleThresholdPicker,
                    NSTextField(labelWithString: L("form.idle.thresholdSuffix"))
                ),
                row(NSTextField(labelWithString: L("form.idle.repeat")), idleRepeatPicker),
                row(NSTextField(labelWithString: L("form.idle.grace")), idleGracePicker),
                idleDisconnect,
                TimePickerPanel.hint(L("settings.hint")),
                TimePickerPanel.buttons([close, save]),
            ],
            delegate: self
        )
    }

    private func row(_ views: NSView...) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
}
