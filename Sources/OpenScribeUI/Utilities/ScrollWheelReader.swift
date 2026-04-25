import AppKit
import SwiftUI

/// Transparent NSView overlay that captures scroll-wheel events
/// without blocking SwiftUI DragGesture (which uses NSGestureRecognizer).
struct ScrollWheelReader: NSViewRepresentable {
    let onScroll: (_ deltaX: CGFloat, _ deltaY: CGFloat, _ mouseX: CGFloat, _ viewWidth: CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollCaptureView {
        ScrollCaptureView()
    }

    func updateNSView(_ nsView: ScrollCaptureView, context: Context) {
        nsView.onScroll = onScroll
    }

    class ScrollCaptureView: NSView {
        var onScroll: ((_ deltaX: CGFloat, _ deltaY: CGFloat, _ mouseX: CGFloat, _ viewWidth: CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, local.x, bounds.width)
        }
    }
}
