import OpenScribeCore
import SwiftUI

public struct WaveformView: View {
    @ObservedObject var vm: PlayerViewModel

    // Internal drag state
    @State private var dragStart: Double? = nil

    public init(vm: PlayerViewModel) { self.vm = vm }

    public var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawBackground(ctx: ctx, size: size)
                drawWaveform(ctx: ctx, size: size)
                drawLoop(ctx: ctx, size: size)
                drawPlayhead(ctx: ctx, size: size)
            }
            .gesture(dragGesture(width: geo.size.width))
            .onAppear { vm.waveformWidth = Int(geo.size.width) }
            .onChange(of: geo.size.width) { vm.waveformWidth = Int($0) }
            .overlay {
                if vm.waveformPeaks.isEmpty {
                    Button {
                        NotificationCenter.default.post(name: .openFileRequested, object: nil)
                    } label: {
                        Label("Open an audio file  (⌘O)", systemImage: "music.note")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minHeight: 120)
        .background(Color(red: 0.12, green: 0.12, blue: 0.12))
    }

    // MARK: – Drawing

    private func drawBackground(ctx: GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(Color(red: 0.12, green: 0.12, blue: 0.12)))
    }

    private func drawWaveform(ctx: GraphicsContext, size: CGSize) {
        let peaks = vm.waveformPeaks
        guard !peaks.isEmpty else { return }

        let mid = size.height / 2
        let scaleY = (size.height / 2) - 4
        let waveColor = Color(red: 0.39, green: 0.71, blue: 1.0)

        var path = Path()
        for (i, peak) in peaks.enumerated() {
            let x = CGFloat(i)
            let y1 = mid - CGFloat(peak.max) * scaleY
            let y2 = mid - CGFloat(peak.min) * scaleY
            path.move(to: CGPoint(x: x, y: y1))
            path.addLine(to: CGPoint(x: x, y: max(y1 + 1, y2)))
        }
        ctx.stroke(path, with: .color(waveColor), lineWidth: 1)
    }

    private func drawLoop(ctx: GraphicsContext, size: CGSize) {
        guard let loop = vm.loop, vm.duration > 0 else { return }
        let x1 = CGFloat(loop.start / vm.duration) * size.width
        let x2 = CGFloat(loop.end / vm.duration) * size.width

        // Semi-transparent fill
        ctx.fill(
            Path(CGRect(x: x1, y: 0, width: x2 - x1, height: size.height)),
            with: .color(Color.blue.opacity(0.25))
        )
        // Border lines
        var border = Path()
        border.move(to: CGPoint(x: x1, y: 0)); border.addLine(to: CGPoint(x: x1, y: size.height))
        border.move(to: CGPoint(x: x2, y: 0)); border.addLine(to: CGPoint(x: x2, y: size.height))
        ctx.stroke(border, with: .color(Color.blue.opacity(0.7)), lineWidth: 1.5)
    }

    private func drawPlayhead(ctx: GraphicsContext, size: CGSize) {
        guard vm.duration > 0 else { return }
        let x = CGFloat(vm.currentTime / vm.duration) * size.width
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(path, with: .color(.red), lineWidth: 2)
    }

    // MARK: – Gestures

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let ratio = min(1, max(0, Double(value.location.x / width)))
                if dragStart == nil {
                    dragStart = min(1, max(0, Double(value.startLocation.x / width)))
                }
                guard let start = dragStart else { return }
                let s = min(start, ratio) * vm.duration
                let e = max(start, ratio) * vm.duration
                if e > s {
                    vm.setLoop(LoopRegion(start: s, end: e))
                }
            }
            .onEnded { value in
                dragStart = nil
                let ratio = min(1, max(0, Double(value.location.x / width)))
                let distance = abs(value.translation.width)
                if distance < 4 {
                    // Short tap → seek
                    vm.clearLoop()
                    vm.seek(to: ratio * vm.duration)
                }
            }
    }
}
