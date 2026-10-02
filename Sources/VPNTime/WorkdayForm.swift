import AppKit
import VPNTimeCore

struct WorkdaySettings {
    // Today's manual start; nil means "use detection".
    var manualStart: Date?
    var detectionEnabled: Bool
    var endRule: WorkdayEndRule?
}

// The "Czas pracy" window: today's start and end settings with a live preview,
// and a table of past days whose start and end can be corrected by hand.
final class WorkdayForm: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let calendar: Calendar
    private let history: WorkdayHistory
    private var panel: NSPanel?
    private var save: ((WorkdaySettings) -> Void)?
    private var saveTodayDay: ((Date, Date) -> Void)?
    private var detected: WorkdayStart?
    private var rows: [WorkdayRecord] = []

    private let startAuto = NSButton(radioButtonWithTitle: "Automatycznie", target: nil, action: nil)
    private let startManual = NSButton(radioButtonWithTitle: "Ręcznie", target: nil, action: nil)
    private let detectedLabel = NSTextField(labelWithString: "")
    private let detection = NSButton(checkboxWithTitle: "Wykrywaj początek pracy", target: nil, action: nil)
    private let endOff = NSButton(radioButtonWithTitle: "Wyłączony", target: nil, action: nil)
    private let endAt = NSButton(radioButtonWithTitle: "O godzinie", target: nil, action: nil)
    private let endAfter = NSButton(radioButtonWithTitle: "Po", target: nil, action: nil)
    private let preview = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let dayStatus = NSTextField(labelWithString: "")
    private lazy var startPicker = TimePickerPanel.picker(identifier: "workdayStartPicker", calendar: calendar)
    private lazy var endTimePicker = TimePickerPanel.picker(identifier: "workdayEndPicker", calendar: calendar)
    private lazy var durationPicker = TimePickerPanel.picker(identifier: "workdayEndDurationPicker", calendar: calendar)
    private lazy var dayPicker = Self.dayPicker(calendar: calendar)
    private lazy var pastStartPicker = TimePickerPanel.picker(identifier: "pastStartPicker", calendar: calendar)
    private lazy var pastEndPicker = TimePickerPanel.picker(identifier: "pastEndPicker", calendar: calendar)

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

    func show(
        settings: WorkdaySettings,
        detected: WorkdayStart?,
        save: @escaping (WorkdaySettings) -> Void,
        saveToday: @escaping (Date, Date) -> Void
    ) {
        self.save = save
        self.saveTodayDay = saveToday
        self.detected = detected

        if panel == nil {
            build()
        }

        load(settings)
        reloadDays()

        if let panel {
            TimePickerPanel.present(panel)
        }
    }

    // MARK: - Today

    private func load(_ settings: WorkdaySettings) {
        detectedLabel.stringValue = detected.map {
            "wykryto \(clock.string(from: $0.date)) (\(Self.label(for: $0)))"
        } ?? "nic jeszcze nie wykryto"

        startPicker.dateValue = settings.manualStart ?? detected?.date ?? Date()
        select(settings.manualStart == nil ? startAuto : startManual, among: [startAuto, startManual])
        detection.state = settings.detectionEnabled ? .on : .off

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

        return WorkdaySettings(manualStart: manual, detectionEnabled: detection.state == .on, endRule: rule)
    }

    @objc private func changed() {
        startPicker.isEnabled = startManual.state == .on
        endTimePicker.isEnabled = endAt.state == .on
        durationPicker.isEnabled = endAfter.state == .on

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

    // MARK: - Days

    private func reloadDays() {
        rows = history.records()
        table.reloadData()
        dayPicker.maxDate = Date()

        if let first = rows.first {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            loadDay(first)
        } else {
            dayPicker.dateValue = dayPicker.maxDate ?? Date()
            dayStatus.stringValue = "Brak zapisanych dni — wybierz datę, żeby dodać dzień."
        }
    }

    private func loadDay(_ record: WorkdayRecord) {
        dayPicker.dateValue = record.start
        pastStartPicker.dateValue = record.start
        pastEndPicker.dateValue = record.end ?? record.start.addingTimeInterval(8 * 3600)
        dayStatus.stringValue = record.end == nil ? "Koniec nieznany — ustaw go i zapisz." : ""
    }

    @objc private func dayChanged() {
        let key = history.key(for: dayPicker.dateValue)

        if let index = rows.firstIndex(where: { $0.day == key }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            loadDay(rows[index])
        } else {
            table.deselectAll(nil)
            dayStatus.stringValue = "Nowy dzień — zapisz, żeby go dodać."
        }
    }

    @objc private func saveDay() {
        let day = dayPicker.dateValue

        guard let startMinutes = TimePickerPanel.minutes(of: pastStartPicker, calendar: calendar),
              let endMinutes = TimePickerPanel.minutes(of: pastEndPicker, calendar: calendar) else {
            return
        }

        guard endMinutes > startMinutes else {
            dayStatus.stringValue = "Koniec musi być później niż początek."
            NSSound.beep()
            return
        }

        let start = TimePickerPanel.date(minutes: startMinutes, calendar: calendar, on: day)
        let end = TimePickerPanel.date(minutes: endMinutes, calendar: calendar, on: day)

        // Today's row is rebuilt from the settings on every refresh, so it is
        // saved through them rather than straight into the history.
        if calendar.isDateInToday(day) {
            saveTodayDay?(start, end)
            startPicker.dateValue = start
            select(startManual, among: [startAuto, startManual])
            changed()
        } else {
            history.set(day: day, start: start, end: end)
        }

        let key = history.key(for: day)
        reloadDays()

        if let index = rows.firstIndex(where: { $0.day == key }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            loadDay(rows[index])
        }

        dayStatus.stringValue = "Zapisano \(key)."
    }

    @objc private func removeDay() {
        let key = history.key(for: dayPicker.dateValue)

        if calendar.isDateInToday(dayPicker.dateValue) {
            dayStatus.stringValue = "Dzisiejszego dnia nie da się usunąć — ustaw początek na „Automatycznie”."
            NSSound.beep()
            return
        }

        guard rows.contains(where: { $0.day == key }) else {
            NSSound.beep()
            return
        }

        history.remove(day: dayPicker.dateValue)
        reloadDays()
        dayStatus.stringValue = "Usunięto \(key)."
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = rows[row]
        let text: String

        switch tableColumn?.identifier.rawValue {
        case "day":
            text = record.day == history.key(for: Date()) ? "dziś" : record.day
        case "start":
            text = clock.string(from: record.start)
        case "end":
            text = record.end.map { clock.string(from: $0) } ?? "—"
        case "length":
            text = record.duration.map(hoursMinutes) ?? "—"
        default:
            text = Self.label(for: WorkdayStart(date: record.start, source: record.source))
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

    private static func dayPicker(calendar: Calendar) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay]
        picker.locale = Locale(identifier: "pl_PL")
        picker.calendar = calendar
        picker.timeZone = calendar.timeZone
        picker.setAccessibilityIdentifier("pastDayPicker")
        return picker
    }

    private func build() {
        [startAuto, startManual].forEach { $0.target = self; $0.action = #selector(chooseStart(_:)) }
        endRadios.forEach { $0.target = self; $0.action = #selector(chooseEnd(_:)) }
        detection.target = self
        detection.action = #selector(changed)
        [startPicker, endTimePicker, durationPicker].forEach { $0.target = self; $0.action = #selector(changed) }
        dayPicker.target = self
        dayPicker.action = #selector(dayChanged)

        detectedLabel.textColor = .secondaryLabelColor
        preview.font = .systemFont(ofSize: 13, weight: .medium)
        preview.setAccessibilityIdentifier("workdayPreview")
        dayStatus.textColor = .secondaryLabelColor
        dayStatus.font = .systemFont(ofSize: 11)

        let save = NSButton(title: "Zapisz", target: self, action: #selector(saveToday))
        save.keyEquivalent = "\r"
        save.setAccessibilityIdentifier("workdaySave")
        let close = NSButton(title: "Zamknij", target: self, action: #selector(close))
        close.keyEquivalent = "\u{1b}"

        let saveDay = NSButton(title: "Zapisz dzień", target: self, action: #selector(saveDay))
        saveDay.setAccessibilityIdentifier("pastDaySave")
        let removeDay = NSButton(title: "Usuń dzień", target: self, action: #selector(removeDay))
        removeDay.setAccessibilityIdentifier("pastDayRemove")

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
                preview,
                TimePickerPanel.hint("Ręczny początek obowiązuje tylko dziś. Koniec działa przy aktywnym VPN-ie, raz dziennie."),
                TimePickerPanel.buttons([close, save]),
                separator(),
                TimePickerPanel.caption("Dni pracy"),
                tableView(),
                row(
                    NSTextField(labelWithString: "Dzień"), dayPicker,
                    NSTextField(labelWithString: "od"), pastStartPicker,
                    NSTextField(labelWithString: "do"), pastEndPicker
                ),
                dayStatus,
                TimePickerPanel.buttons([removeDay, saveDay]),
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

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return box
    }

    private func tableView() -> NSView {
        let columns: [(String, String, CGFloat)] = [
            ("day", "Dzień", 90),
            ("start", "Początek", 65),
            ("end", "Koniec", 65),
            ("length", "Czas", 70),
            ("source", "Źródło", 90),
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
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        return scroll
    }
}
