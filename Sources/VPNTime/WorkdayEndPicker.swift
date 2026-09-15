import AppKit
import VPNTimeCore

final class WorkdayEndPicker: NSObject, NSWindowDelegate {
    private let calendar: Calendar
    private var panel: NSPanel?
    private var picker: NSDatePicker?
    private var commit: ((WorkdayEnd?) -> Void)?

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    func show(current: WorkdayEnd?, commit: @escaping (WorkdayEnd?) -> Void) {
        self.commit = commit

        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.hourMinute]
        picker.datePickerMode = .single
        picker.setAccessibilityIdentifier("workdayEndPicker")
        picker.dateValue = date(for: current ?? WorkdayEnd(hour: 17, minute: 0))
        self.picker = picker

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Koniec pracy"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = content(picker: picker)
        panel.center()
        self.panel = panel

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func content(picker: NSDatePicker) -> NSView {
        let caption = NSTextField(labelWithString: "O której zamknąć Tunnelblicka?")
        caption.font = .systemFont(ofSize: 13, weight: .semibold)

        let hint = NSTextField(
            labelWithString: "Zadziała tylko przy aktywnym VPN-ie, raz dziennie."
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let set = NSButton(title: "Ustaw", target: self, action: #selector(apply))
        set.keyEquivalent = "\r"
        set.setAccessibilityIdentifier("workdayEndSet")

        let disable = NSButton(title: "Wyłącz", target: self, action: #selector(disable))
        disable.setAccessibilityIdentifier("workdayEndDisable")

        let buttons = NSStackView(views: [disable, set])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [caption, picker, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        return stack
    }

    private func date(for end: WorkdayEnd) -> Date {
        calendar.date(bySettingHour: end.hour, minute: end.minute, second: 0, of: Date()) ?? Date()
    }

    @objc private func apply() {
        guard let picker else {
            return
        }

        let parts = calendar.dateComponents([.hour, .minute], from: picker.dateValue)

        guard let hour = parts.hour, let minute = parts.minute else {
            return
        }

        finish(with: WorkdayEnd(hour: hour, minute: minute))
    }

    @objc private func disable() {
        finish(with: nil)
    }

    private func finish(with end: WorkdayEnd?) {
        commit?(end)
        panel?.close()
    }
}
