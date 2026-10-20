import AppKit
import VPNTimeCore

// The "Dziś" window: today's start with a live preview. The persistent
// settings live in their own window, SettingsWindow; the recorded days in
// WorkdayDays.
final class WorkdayForm: NSObject, NSWindowDelegate {
    private let calendar: Calendar
    private var panel: NSPanel?
    private var save: ((Date?) -> Void)?
    private var detected: WorkdayStart?
    // Read-only context for the preview; only the start is edited here.
    private var detectionEnabled = true
    private var endRule: WorkdayEndRule?

    private let startAuto = NSButton(radioButtonWithTitle: L("form.start.auto"), target: nil, action: nil)
    private let startManual = NSButton(radioButtonWithTitle: L("form.start.manual"), target: nil, action: nil)
    private let detectedLabel = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")
    private lazy var startPicker = TimePickerPanel.picker(identifier: "workdayStartPicker", calendar: calendar)

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
        manualStart: Date?,
        detectionEnabled: Bool,
        endRule: WorkdayEndRule?,
        detected: WorkdayStart?,
        save: @escaping (Date?) -> Void
    ) {
        self.save = save
        self.detected = detected
        self.detectionEnabled = detectionEnabled
        self.endRule = endRule

        if panel == nil {
            build()
        }

        load(manualStart)

        if let panel {
            TimePickerPanel.present(panel)
        }
    }

    // Shows the stored start again in an open form, after today's row was
    // saved in "Dni pracy".
    func reloadIfOpen(manualStart: Date?, detectionEnabled: Bool, endRule: WorkdayEndRule?, detected: WorkdayStart?) {
        guard let panel, panel.isVisible else {
            return
        }

        self.detected = detected
        self.detectionEnabled = detectionEnabled
        self.endRule = endRule
        load(manualStart)
    }

    // The settings changed while the window is open: only the preview
    // follows, so an unsaved start choice is kept.
    func updatePreviewIfOpen(detectionEnabled: Bool, endRule: WorkdayEndRule?) {
        guard let panel, panel.isVisible else {
            return
        }

        self.detectionEnabled = detectionEnabled
        self.endRule = endRule
        changed()
    }

    // MARK: - Today

    private func load(_ manualStart: Date?) {
        detectedLabel.stringValue = detected.map {
            L("form.detected", clock.string(from: $0.date), Self.label(for: $0))
        } ?? L("form.detected.none")

        startPicker.dateValue = manualStart ?? detected?.date ?? Date()
        select(manualStart == nil ? startAuto : startManual, among: [startAuto, startManual])
        changed()

        // The window was sized before the detected start was filled in, and
        // that line is often its widest.
        if let panel, let content = panel.contentView {
            panel.setContentSize(content.fittingSize)
        }
    }

    private var currentStart: Date? {
        startManual.state == .on
            ? TimePickerPanel.minutes(of: startPicker, calendar: calendar).map {
                TimePickerPanel.date(minutes: $0, calendar: calendar)
            }
            : nil
    }

    @objc private func changed() {
        startPicker.isEnabled = startManual.state == .on

        let start = currentStart ?? (detectionEnabled ? detected?.date : nil)

        guard let start else {
            preview.stringValue = L("form.preview.unknown")
            return
        }

        guard let end = endRule?.trigger(now: Date(), start: start, calendar: calendar) else {
            preview.stringValue = L("form.preview.noEnd", clock.string(from: start))
            return
        }

        guard end > start else {
            preview.stringValue = L("form.preview.endBeforeStart", clock.string(from: start), clock.string(from: end))
            return
        }

        let length = Int(end.timeIntervalSince(start))
        preview.stringValue = L("form.preview.range", clock.string(from: start), clock.string(from: end), hoursMinutes(length))
    }

    @objc private func chooseStart(_ sender: NSButton) {
        select(sender, among: [startAuto, startManual])
        changed()
    }

    // The radios sit in different rows, so AppKit does not group them.
    private func select(_ radio: NSButton, among group: [NSButton]) {
        group.forEach { $0.state = $0 === radio ? .on : .off }
    }

    @objc private func saveToday() {
        save?(currentStart)
        panel?.close()
    }

    @objc private func close() {
        panel?.close()
    }

    // MARK: - Layout

    static func label(for start: WorkdayStart) -> String {
        switch start.source {
        case .manual:
            return L("source.manual")
        case .vpn:
            return L("source.vpn")
        case .activity:
            return start.provisional ? L("source.noVpn") : L("source.activity")
        case .edited:
            return L("source.edited")
        }
    }

    static func label(for end: WorkdayEndSource?) -> String {
        switch end {
        case .vpn:
            return L("source.vpn")
        case .activity:
            return L("source.activity")
        case .idle:
            return L("endSource.idle")
        case .manual:
            return L("source.manual")
        case .planned:
            return L("endSource.planned")
        case .edited:
            return L("source.edited")
        case nil:
            return "—"
        }
    }

    private func build() {
        [startAuto, startManual].forEach { $0.target = self; $0.action = #selector(chooseStart(_:)) }
        startPicker.target = self
        startPicker.action = #selector(changed)

        detectedLabel.textColor = .secondaryLabelColor
        preview.font = .systemFont(ofSize: 13, weight: .medium)
        preview.setAccessibilityIdentifier("workdayPreview")

        let save = NSButton(title: L("button.save"), target: self, action: #selector(saveToday))
        save.keyEquivalent = "\r"
        save.setAccessibilityIdentifier("workdaySave")
        let close = NSButton(title: L("button.close"), target: self, action: #selector(close))
        close.keyEquivalent = "\u{1b}"

        panel = TimePickerPanel.panel(
            title: L("form.title"),
            views: [
                TimePickerPanel.caption(L("form.startCaption")),
                row(startAuto, detectedLabel),
                row(startManual, startPicker),
                preview,
                TimePickerPanel.hint(L("form.hint")),
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
