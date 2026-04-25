import AppKit
import SwiftUI

/// Transparent background view that reports its frame in window coordinates.
/// Used so the app-level scroll monitor knows where the waveform is.
struct FrameReporter: NSViewRepresentable {
    let onFrame: (CGRect) -> Void

    func makeNSView(context: Context) -> ReportView { ReportView() }
    func updateNSView(_ nsView: ReportView, context: Context) { nsView.onFrame = onFrame }

    class ReportView: NSView {
        var onFrame: ((CGRect) -> Void)?

        override func layout() {
            super.layout()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let _ = window else { return }
                onFrame?(convert(bounds, to: nil))
            }
        }
    }
}
