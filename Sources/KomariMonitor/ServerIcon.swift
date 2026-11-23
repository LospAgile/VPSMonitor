import AppKit

@MainActor
enum ServerIcon {
    static let image: NSImage = {
        // Reuse the original two-server paths, now as a template for the native
        // status button so its text and icon share menu-bar highlight behavior.
        let image = NSImage(size: NSSize(width: 14, height: 22), flipped: true) { _ in
            NSColor.black.withAlphaComponent(0.95).setStroke()
            NSColor.black.withAlphaComponent(0.95).setFill()
            for y: CGFloat in [5, 12] {
                let rack = NSBezierPath(roundedRect: NSRect(x: 1.5, y: y, width: 11, height: 4.5), xRadius: 1.3, yRadius: 1.3)
                rack.lineWidth = 1.2
                rack.stroke()
                NSBezierPath(ovalIn: NSRect(x: 3.2, y: y + 1.6, width: 1.4, height: 1.4)).fill()
                NSBezierPath(roundedRect: NSRect(x: 6.7, y: y + 1.8, width: 4.2, height: 1), xRadius: 0.5, yRadius: 0.5).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "服务器"
        return image
    }()
}
