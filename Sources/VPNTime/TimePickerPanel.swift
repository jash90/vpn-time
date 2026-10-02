import AppKit

// Shared building blocks for the small floating panels behind the
// "Początek pracy" and "Koniec pracy" menu items.
enum TimePickerPanel {
    static func picker(identifier: String, calendar: Calendar) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.hourMinute]
        picker.datePickerMode = .single
        // A 24-hour locale, so a duration like 08:00 never reads as "8:00 AM".
        picker.locale = Locale(identifier: "pl_PL")
        picker.calendar = calendar
        picker.timeZone = calendar.timeZone
        picker.setAccessibilityIdentifier(identifier)
        return picker
    }

    static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 280
        return label
    }

    static func buttons(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    static func panel(title: String, views: [NSView], delegate: NSWindowDelegate) -> NSPanel {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = delegate
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        panel.center()
        return panel
    }

    static func present(_ panel: NSPanel) {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func minutes(of picker: NSDatePicker, calendar: Calendar) -> Int? {
        let parts = calendar.dateComponents([.hour, .minute], from: picker.dateValue)

        guard let hour = parts.hour, let minute = parts.minute else {
            return nil
        }

        return hour * 60 + minute
    }

    static func date(minutes: Int, calendar: Calendar, on day: Date = Date()) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }
}
