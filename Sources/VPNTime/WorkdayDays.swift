import AppKit
import VPNTimeCore

// The "Dni pracy" window: the recorded workdays with their start, end and
// length, totals for today / this week / this month, and editing of any day.
final class WorkdayDays: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let calendar: Calendar
    private let history: WorkdayHistory
    private var panel: NSPanel?
    private var saveTodayDay: ((Date, Date) -> Void)?
    private var rows: [WorkdayRecord] = []

    private let table = NSTableView()
    private let totals = NSTextField(labelWithString: "")
    private let dayStatus = NSTextField(labelWithString: "")
    private lazy var dayPicker = Self.dayPicker(calendar: calendar)
    private lazy var startPicker = TimePickerPanel.picker(identifier: "pastStartPicker", calendar: calendar)
    private lazy var endPicker = TimePickerPanel.picker(identifier: "pastEndPicker", calendar: calendar)

    private lazy var clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        return formatter
    }()

    init(calendar: Calendar, history: WorkdayHistory) {
        self.calendar = calendar
        self.history = history
    }

    // `saveToday` applies an edit of today's row: today's row is rebuilt from
    // the settings on every refresh, so it goes through them.
    func show(saveToday: @escaping (Date, Date) -> Void) {
        saveTodayDay = saveToday

        if panel == nil {
            build()
        }

        reloadDays()

        if let panel {
            TimePickerPanel.present(panel)
        }
    }

    // Called on the app's refresh so an open window follows today's row.
    func refreshIfOpen() {
        guard let panel, panel.isVisible else {
            return
        }

        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].day : nil
        rows = history.records()
        table.reloadData()
        updateTotals()

        if let selected, let index = rows.firstIndex(where: { $0.day == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func reloadDays() {
        rows = history.records()
        table.reloadData()
        updateTotals()
        dayPicker.maxDate = Date()

        if let first = rows.first {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            loadDay(first)
        } else {
            dayPicker.dateValue = dayPicker.maxDate ?? Date()
            dayStatus.stringValue = L("days.empty")
        }
    }

    private func updateTotals() {
        let totals = WorkdayTotals(calendar: calendar, now: Date())
        self.totals.stringValue = L(
            "days.totals",
            hoursMinutes(totals.total(.today, records: rows)),
            hoursMinutes(totals.total(.week, records: rows)),
            hoursMinutes(totals.total(.month, records: rows))
        )
    }

    private func loadDay(_ record: WorkdayRecord) {
        dayPicker.dateValue = record.start
        startPicker.dateValue = record.start
        endPicker.dateValue = record.end ?? record.start.addingTimeInterval(8 * 3600)
        dayStatus.stringValue = record.end == nil ? L("days.endUnknown") : ""
    }

    @objc private func dayChanged() {
        let key = history.key(for: dayPicker.dateValue)

        if let index = rows.firstIndex(where: { $0.day == key }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            loadDay(rows[index])
        } else {
            table.deselectAll(nil)
            dayStatus.stringValue = L("days.newDay")
        }
    }

    @objc private func saveDay() {
        let day = dayPicker.dateValue

        guard let startMinutes = TimePickerPanel.minutes(of: startPicker, calendar: calendar),
              let endMinutes = TimePickerPanel.minutes(of: endPicker, calendar: calendar) else {
            return
        }

        guard endMinutes > startMinutes else {
            dayStatus.stringValue = L("days.endBeforeStart")
            NSSound.beep()
            return
        }

        let start = TimePickerPanel.date(minutes: startMinutes, calendar: calendar, on: day)
        let end = TimePickerPanel.date(minutes: endMinutes, calendar: calendar, on: day)

        if calendar.isDateInToday(day) {
            saveTodayDay?(start, end)
        } else {
            history.set(day: day, start: start, end: end)
        }

        let key = history.key(for: day)
        reloadDays()

        if let index = rows.firstIndex(where: { $0.day == key }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            loadDay(rows[index])
        }

        dayStatus.stringValue = L("days.saved", key)
    }

    @objc private func removeDay() {
        let key = history.key(for: dayPicker.dateValue)

        if calendar.isDateInToday(dayPicker.dateValue) {
            dayStatus.stringValue = L("days.cannotRemoveToday")
            NSSound.beep()
            return
        }

        guard rows.contains(where: { $0.day == key }) else {
            NSSound.beep()
            return
        }

        history.remove(day: dayPicker.dateValue)
        reloadDays()
        dayStatus.stringValue = L("days.removed", key)
    }

    @objc private func close() {
        panel?.close()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = rows[row]
        let now = Date()
        let isToday = record.day == history.key(for: now)
        let text: String

        switch tableColumn?.identifier.rawValue {
        case "day":
            text = isToday ? L("days.today") : record.day
        case "start":
            text = clock.string(from: record.start)
        case "end":
            text = record.end.map { clock.string(from: $0) } ?? "—"
        case "length":
            if isToday {
                text = hoursMinutes(record.worked(now: now, calendar: calendar))
            } else {
                text = record.duration.map(hoursMinutes) ?? "—"
            }
        default:
            text = WorkdayForm.label(for: WorkdayStart(date: record.start, source: record.source))
        }

        let cell = NSTextField(labelWithString: text)
        cell.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else {
            return
        }

        loadDay(rows[table.selectedRow])
    }

    private static func dayPicker(calendar: Calendar) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay]
        picker.locale = Locale.current
        picker.calendar = calendar
        picker.timeZone = calendar.timeZone
        picker.setAccessibilityIdentifier("pastDayPicker")
        return picker
    }

    private func build() {
        dayPicker.target = self
        dayPicker.action = #selector(dayChanged)
        totals.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        totals.setAccessibilityIdentifier("workdayTotals")
        dayStatus.textColor = .secondaryLabelColor
        dayStatus.font = .systemFont(ofSize: 11)

        let saveDay = NSButton(title: L("days.saveDay"), target: self, action: #selector(saveDay))
        saveDay.keyEquivalent = "\r"
        saveDay.setAccessibilityIdentifier("pastDaySave")
        let removeDay = NSButton(title: L("days.removeDay"), target: self, action: #selector(removeDay))
        removeDay.setAccessibilityIdentifier("pastDayRemove")
        let close = NSButton(title: L("button.close"), target: self, action: #selector(close))
        close.keyEquivalent = "\u{1b}"

        let edit = NSStackView(views: [
            NSTextField(labelWithString: L("days.day")), dayPicker,
            NSTextField(labelWithString: L("days.from")), startPicker,
            NSTextField(labelWithString: L("days.to")), endPicker,
        ])
        edit.orientation = .horizontal
        edit.spacing = 8

        let panel = TimePickerPanel.panel(
            title: L("days.title"),
            views: [
                totals,
                tableView(),
                edit,
                dayStatus,
                TimePickerPanel.hint(L("days.hint")),
                TimePickerPanel.buttons([close, removeDay, saveDay]),
            ],
            delegate: self
        )
        // A timesheet stays open next to other apps: an ordinary window that
        // does not hide when another app becomes active.
        panel.level = .normal
        panel.hidesOnDeactivate = false
        self.panel = panel
    }

    private func tableView() -> NSView {
        let columns: [(String, String, CGFloat)] = [
            ("day", L("days.column.day"), 90),
            ("start", L("days.column.start"), 65),
            ("end", L("days.column.end"), 65),
            ("length", L("days.column.length"), 70),
            ("source", L("days.column.source"), 90),
        ]

        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }

        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.setAccessibilityIdentifier("pastDaysTable")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 460).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        return scroll
    }
}
