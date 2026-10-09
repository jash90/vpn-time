import AppKit
import VPNTimeCore

// The "Czy nadal pracujesz?" window shown after an hour without keyboard or
// mouse input during a VPN session. It floats above other windows on every
// Space but does not take keyboard focus, so it only answers to a click.
final class IdlePrompt: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var timer: Timer?
    private var deadline = Date()
    private var stopAt = Date()
    private var keepWorking: (() -> Void)?
    private var endNow: (() -> Void)?

    private let message = NSTextField(wrappingLabelWithString: "")
    private let countdown = NSTextField(labelWithString: "")

    private lazy var clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    var isShown: Bool {
        panel?.isVisible ?? false
    }

    func show(
        idleSince: Date,
        stopAt: Date,
        deadline: Date,
        keepWorking: @escaping () -> Void,
        endNow: @escaping () -> Void
    ) {
        self.deadline = deadline
        self.stopAt = stopAt
        self.keepWorking = keepWorking
        self.endNow = endNow

        if panel == nil {
            build()
        }

        let idle = Int(Date().timeIntervalSince(idleSince))
        message.stringValue = "Brak aktywności od \(clock.string(from: idleSince)) (\(hoursMinutes(idle))). "
            + "Czy nadal pracujesz?"
        tick()

        timer?.invalidate()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)

        panel?.center()
        panel?.orderFrontRegardless()
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func tick() {
        let left = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
        countdown.stringValue = String(format: "Bez odpowiedzi czas pracy zatrzyma się na %@ za %d:%02d.",
                                       clock.string(from: stopAt), left / 60, left % 60)
    }

    @objc private func working() {
        dismiss()
        keepWorking?()
    }

    @objc private func end() {
        dismiss()
        endNow?()
    }

    private func build() {
        message.font = .systemFont(ofSize: 13, weight: .semibold)
        message.preferredMaxLayoutWidth = 320
        message.setAccessibilityIdentifier("idleMessage")
        countdown.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countdown.textColor = .secondaryLabelColor
        countdown.setAccessibilityIdentifier("idleCountdown")

        let working = NSButton(title: "Pracuję", target: self, action: #selector(working))
        working.keyEquivalent = "\r"
        working.setAccessibilityIdentifier("idleKeepWorking")
        let end = NSButton(title: "Zakończ pracę", target: self, action: #selector(end))
        end.setAccessibilityIdentifier("idleEndWork")

        let panel = TimePickerPanel.panel(
            title: "Czy nadal pracujesz?",
            views: [message, countdown, TimePickerPanel.buttons([end, working])],
            delegate: self
        )
        // No close button: only the two answers (or the countdown) end it.
        panel.styleMask.remove(.closable)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        self.panel = panel
    }
}
