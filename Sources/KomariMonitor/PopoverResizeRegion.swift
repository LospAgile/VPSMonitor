import AppKit
import SwiftUI

enum PopoverResizeEdge {
    case left, right, bottom, bottomLeft, bottomRight

    var isLeft: Bool { self == .left || self == .bottomLeft }
    var changesHeight: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var label: String {
        switch self {
        case .left: "左侧缩放面板"
        case .right: "右侧缩放面板"
        case .bottom: "底边缩放面板"
        case .bottomLeft: "左下角缩放面板"
        case .bottomRight: "右下角缩放面板"
        }
    }
    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch self {
            case .left: .left
            case .right: .right
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        return changesHeight ? .resizeUpDown : .resizeLeftRight
    }
}

typealias PopoverResizeAction = (CGSize, PopoverResizeEdge, Bool) -> Void

struct PopoverResizeRegion: View {
    let edge: PopoverResizeEdge
    let onResize: PopoverResizeAction

    var body: some View {
        PopoverResizeSurface(edge: edge, onResize: onResize)
            .overlay {
                if edge == .bottomLeft || edge == .bottomRight {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .scaleEffect(x: edge.isLeft ? -1 : 1, y: 1)
                        .allowsHitTesting(false)
                }
            }
            .help("拖动调整面板大小").accessibilityLabel(edge.label)
    }
}

private struct PopoverResizeSurface: NSViewRepresentable {
    let edge: PopoverResizeEdge
    let onResize: PopoverResizeAction

    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {
        view.edge = edge
        view.onResize = onResize
    }

    final class ResizeView: NSView {
        var edge = PopoverResizeEdge.right
        var onResize: PopoverResizeAction?
        private var start: NSPoint?
        private var eventStart: CGPoint?
        private var lastDelta = CGSize.zero

        override func resetCursorRects() { addCursorRect(bounds, cursor: edge.cursor) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            start = event.window?.convertPoint(toScreen: event.locationInWindow)
            eventStart = event.cgEvent?.location
            lastDelta = .zero
            if start != nil { onResize?(.zero, edge, false) }
        }

        override func mouseDragged(with event: NSEvent) { resize(with: event, finished: false) }
        override func mouseUp(with event: NSEvent) { resize(with: event, finished: true) }

        private func resize(with event: NSEvent, finished: Bool) {
            guard let start, let window = event.window else { return }
            // CGEvent keeps the position at event creation, even if AppKit has
            // since repositioned the popover. Quartz uses a downward y axis.
            if let eventStart, let point = event.cgEvent?.location {
                lastDelta = CGSize(width: point.x - eventStart.x, height: point.y - eventStart.y)
            } else {
                let point = window.convertPoint(toScreen: event.locationInWindow)
                lastDelta = CGSize(width: point.x - start.x, height: start.y - point.y)
            }
            onResize?(lastDelta, edge, finished)
            if finished { self.start = nil }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, start != nil {
                onResize?(lastDelta, edge, true)
                start = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

struct PopoverResizeBorder: ViewModifier {
    let onResize: PopoverResizeAction

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) { region(.left).frame(width: 7).padding(.vertical, 28) }
            .overlay(alignment: .trailing) { region(.right).frame(width: 7).padding(.vertical, 28) }
            .overlay(alignment: .bottom) { region(.bottom).frame(height: 7).padding(.horizontal, 28) }
            .overlay(alignment: .bottomLeading) { region(.bottomLeft).frame(width: 28, height: 28) }
            .overlay(alignment: .bottomTrailing) { region(.bottomRight).frame(width: 28, height: 28) }
    }

    private func region(_ edge: PopoverResizeEdge) -> some View {
        PopoverResizeRegion(edge: edge, onResize: onResize)
    }
}
