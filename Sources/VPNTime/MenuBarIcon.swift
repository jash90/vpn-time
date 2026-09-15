import AppKit

enum MenuBarIcon {
    static let connected = lock(shackleEndAngle: 0, accessibilityDescription: "VPN on")
    static let disconnected = lock(shackleEndAngle: 20, accessibilityDescription: "VPN off")

    private static func lock(shackleEndAngle: CGFloat, accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            NSBezierPath(
                roundedRect: NSRect(x: 3.5, y: 1.5, width: 11, height: 9),
                xRadius: 2.2,
                yRadius: 2.2
            ).fill()

            let shackle = NSBezierPath()
            shackle.lineWidth = 1.8
            shackle.lineCapStyle = .round
            shackle.move(to: NSPoint(x: 5.9, y: 10.0))
            shackle.line(to: NSPoint(x: 5.9, y: 11.6))
            shackle.appendArc(
                withCenter: NSPoint(x: 9, y: 11.6),
                radius: 3.1,
                startAngle: 180,
                endAngle: shackleEndAngle,
                clockwise: true
            )
            shackle.stroke()

            return true
        }

        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
