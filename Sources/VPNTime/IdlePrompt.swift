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

    private let headline = NSTextField(labelWithString: L("idle.headline"))
    private let message = NSTextField(wrappingLabelWithString: "")
    private let remaining = NSTextField(labelWithString: "")
    private let countdown = NSTextField(wrappingLabelWithString: "")

    // Width of the text column, and of the whole window around it.
    private static let textWidth: CGFloat = 400
    private static let windowWidth: CGFloat = 540

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
        message.stringValue = L("idle.message", clock.string(from: idleSince), hoursMinutes(idle))
        countdown.stringValue = L("idle.countdown", clock.string(from: stopAt))
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
        remaining.stringValue = String(format: "%d:%02d", left / 60, left % 60)
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
        headline.font = .systemFont(ofSize: 18, weight: .semibold)
        message.font = .systemFont(ofSize: 13)
        message.setAccessibilityIdentifier("idleMessage")
        remaining.font = .monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
        remaining.setAccessibilityIdentifier("idleRemaining")
        countdown.font = .systemFont(ofSize: 12)
        countdown.textColor = .secondaryLabelColor
        countdown.setAccessibilityIdentifier("idleCountdown")

        message.preferredMaxLayoutWidth = Self.textWidth
        message.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true

        let timer = NSStackView(views: [remaining, countdown])
        timer.orientation = .horizontal
        timer.alignment = .centerY
        timer.spacing = 12
        countdown.preferredMaxLayoutWidth = Self.textWidth - 90

        let text = NSStackView(views: [headline, message, timer])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 10
        text.setCustomSpacing(16, after: message)
        text.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .regular))
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let body = NSStackView(views: [icon, text])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 18

        let working = NSButton(title: L("idle.working"), target: self, action: #selector(working))
        working.keyEquivalent = "\r"
        working.setAccessibilityIdentifier("idleKeepWorking")
        let end = NSButton(title: L("idle.endWork"), target: self, action: #selector(end))
        end.setAccessibilityIdentifier("idleEndWork")

        for button in [working, end] {
            button.controlSize = .large
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.setViews([end, working], in: .trailing)

        let content = NSStackView(views: [body, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 22
        content.edgeInsets = NSEdgeInsets(top: 34, left: 28, bottom: 24, right: 28)
        content.widthAnchor.constraint(equalToConstant: Self.windowWidth).isActive = true
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -56).isActive = true

        // No close button: only the two answers (or the countdown) end it.
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: Self.windowWidth, height: content.fittingSize.height))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        self.panel = panel
    }
}
