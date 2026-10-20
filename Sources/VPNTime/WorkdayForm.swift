import AppKit
import VPNTimeCore

struct WorkdaySettings {
    // Today's manual start; nil means "use detection".
    var manualStart: Date?
    var detectionEnabled: Bool
    var endRule: WorkdayEndRule?
    var endDetectionEnabled: Bool
    var idleThreshold: TimeInterval
    var idleRepeat: TimeInterval
    var idleGrace: TimeInterval
}

// The "Czas pracy" window: today's start and end settings with a live preview.
// The recorded days live in their own window, WorkdayDays.
final class WorkdayForm: NSObject, NSWindowDelegate {
    private let calendar: Calendar
    private var panel: NSPanel?
    private var save: ((WorkdaySettings) -> Void)?
    private var detected: WorkdayStart?

    private let startAuto = NSButton(radioButtonWithTitle: "Automatycznie", target: nil, action: nil)
    private let startManual = NSButton(radioButtonWithTitle: "Ręcznie", target: nil, action: nil)
    private let detectedLabel = NSTextField(labelWithString: "")
    private let detection = NSButton(checkboxWithTitle: "Wykrywaj początek pracy", target: nil, action: nil)
    private let endDetection = NSButton(checkboxWithTitle: "Wykrywaj koniec pracy", target: nil, action: nil)
    private let endOff = NSButton(radioButtonWithTitle: "Wyłączony", target: nil, action: nil)
    private let endAt = NSButton(radioButtonWithTitle: "O godzinie", target: nil, action: nil)
    private let endAfter = NSButton(radioButtonWithTitle: "Po", target: nil, action: nil)
    private let preview = NSTextField(labelWithString: "")
    private lazy var startPicker = TimePickerPanel.picker(identifier: "workdayStartPicker", calendar: calendar)
    private lazy var endTimePicker = TimePickerPanel.picker(identifier: "workdayEndPicker", calendar: calendar)
    private lazy var durationPicker = TimePickerPanel.picker(identifier: "workdayEndDurationPicker", calendar: calendar)
    private lazy var idleThresholdPicker = TimePickerPanel.picker(identifier: "idleThresholdPicker", calendar: calendar)
    private lazy var idleRepeatPicker = TimePickerPanel.picker(identifier: "idleRepeatPicker", calendar: calendar)
    private lazy var idleGracePicker = TimePickerPanel.picker(identifier: "idleGracePicker", calendar: calendar)

    private lazy var clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        return formatter
    }()

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    func show(
        settings: WorkdaySettings,
        detected: WorkdayStart?,
        save: @escaping (WorkdaySettings) -> Void
    ) {
        self.save = save
        self.detected = detected

        if panel == nil {
            build()
        }

        load(settings)

        if let panel {
            TimePickerPanel.present(panel)
        }
    }

    // Shows the stored settings again in an open form, after today's row was
    // saved in "Dni pracy".
    func reloadIfOpen(settings: WorkdaySettings, detected: WorkdayStart?) {
        guard let panel, panel.isVisible else {
            return
        }

        self.detected = detected
        load(settings)
    }

    // MARK: - Today

    private func load(_ settings: WorkdaySettings) {
        detectedLabel.stringValue = detected.map {
            "wykryto \(clock.string(from: $0.date)) (\(Self.label(for: $0)))"
        } ?? "nic jeszcze nie wykryto"

        startPicker.dateValue = settings.manualStart ?? detected?.date ?? Date()
        select(settings.manualStart == nil ? startAuto : startManual, among: [startAuto, startManual])
        detection.state = settings.detectionEnabled ? .on : .off
        endDetection.state = settings.endDetectionEnabled ? .on : .off
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

    private var current: WorkdaySettings {
        let manual = startManual.state == .on
            ? TimePickerPanel.minutes(of: startPicker, calendar: calendar).map {
                TimePickerPanel.date(minutes: $0, calendar: calendar)
            }
            : nil

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

        return WorkdaySettings(
            manualStart: manual,
            detectionEnabled: detection.state == .on,
            endRule: rule,
            endDetectionEnabled: endDetection.state == .on,
            idleThreshold: duration(of: idleThresholdPicker),
            idleRepeat: duration(of: idleRepeatPicker),
            idleGrace: duration(of: idleGracePicker)
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
        startPicker.isEnabled = startManual.state == .on
        endTimePicker.isEnabled = endAt.state == .on
        durationPicker.isEnabled = endAfter.state == .on
        let detecting = endDetection.state == .on
        idleThresholdPicker.isEnabled = detecting
        idleRepeatPicker.isEnabled = detecting
        idleGracePicker.isEnabled = detecting

        let settings = current
        let start = settings.manualStart ?? (settings.detectionEnabled ? detected?.date : nil)

        guard let start else {
            preview.stringValue = "Dziś: początek nieznany"
            return
        }

        guard let end = settings.endRule?.trigger(now: Date(), start: start, calendar: calendar) else {
            preview.stringValue = "Dziś: od \(clock.string(from: start)), bez końca"
            return
        }

        guard end > start else {
            preview.stringValue = "Dziś: od \(clock.string(from: start)), koniec \(clock.string(from: end)) jest przed początkiem"
            return
        }

        let length = Int(end.timeIntervalSince(start))
        preview.stringValue = "Dziś: \(clock.string(from: start)) → \(clock.string(from: end)) (\(hoursMinutes(length)))"
    }

    @objc private func chooseStart(_ sender: NSButton) {
        select(sender, among: [startAuto, startManual])
        changed()
    }

    @objc private func chooseEnd(_ sender: NSButton) {
        select(sender, among: endRadios)
        changed()
    }

    // The radios sit in different rows, so AppKit does not group them.
    private func select(_ radio: NSButton, among group: [NSButton]) {
        group.forEach { $0.state = $0 === radio ? .on : .off }
    }

    @objc private func saveToday() {
        save?(current)
        panel?.close()
    }

    @objc private func close() {
        panel?.close()
    }

    // MARK: - Layout

    static func label(for start: WorkdayStart) -> String {
        switch start.source {
        case .manual:
            return "ręcznie"
        case .vpn:
            return "VPN"
        case .activity:
            return start.provisional ? "bez VPN" : "aktywność"
        case .edited:
            return "poprawiony"
        }
    }

    static func label(for end: WorkdayEndSource?) -> String {
        switch end {
        case .vpn:
            return "VPN"
        case .activity:
            return "aktywność"
        case .idle:
            return "bezczynność"
        case .manual:
            return "ręcznie"
        case .planned:
            return "plan"
        case .edited:
            return "poprawiony"
        case nil:
            return "—"
        }
    }

    private func build() {
        [startAuto, startManual].forEach { $0.target = self; $0.action = #selector(chooseStart(_:)) }
        endRadios.forEach { $0.target = self; $0.action = #selector(chooseEnd(_:)) }
        detection.target = self
        detection.action = #selector(changed)
        endDetection.target = self
        endDetection.action = #selector(changed)
        [startPicker, endTimePicker, durationPicker, idleThresholdPicker, idleRepeatPicker, idleGracePicker]
            .forEach { $0.target = self; $0.action = #selector(changed) }

        detectedLabel.textColor = .secondaryLabelColor
        endDetection.setAccessibilityIdentifier("endDetection")
        preview.font = .systemFont(ofSize: 13, weight: .medium)
        preview.setAccessibilityIdentifier("workdayPreview")

        let save = NSButton(title: "Zapisz", target: self, action: #selector(saveToday))
        save.keyEquivalent = "\r"
        save.setAccessibilityIdentifier("workdaySave")
        let close = NSButton(title: "Zamknij", target: self, action: #selector(close))
        close.keyEquivalent = "\u{1b}"

        panel = TimePickerPanel.panel(
            title: "Czas pracy",
            views: [
                TimePickerPanel.caption("Początek pracy dziś"),
                row(startAuto, detectedLabel),
                row(startManual, startPicker),
                detection,
                TimePickerPanel.caption("Koniec pracy (zamyka Tunnelblicka)"),
                endOff,
                row(endAt, endTimePicker),
                row(endAfter, durationPicker, NSTextField(labelWithString: "od początku pracy")),
                TimePickerPanel.caption("Wykrywanie końca pracy"),
                endDetection,
                row(NSTextField(labelWithString: "Koniec po"), idleThresholdPicker, NSTextField(labelWithString: "bez aktywności")),
                row(NSTextField(labelWithString: "Pytaj ponownie co"), idleRepeatPicker),
                row(NSTextField(labelWithString: "Czas na odpowiedź"), idleGracePicker),
                preview,
                TimePickerPanel.hint(
                    "Ręczny początek obowiązuje tylko dziś. Zamknięcie Tunnelblicka działa przy aktywnym VPN-ie, raz dziennie. "
                        + "Bez aktywności przez ustawiony czas apka pyta, czy to już koniec; "
                        + "brak odpowiedzi kończy dzień w chwili, gdy zaczęła się bezczynność."
                ),
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
