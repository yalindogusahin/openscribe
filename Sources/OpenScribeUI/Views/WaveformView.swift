import OpenScribeCore
import SwiftUI

public struct WaveformView: View {
    @ObservedObject var vm: PlayerViewModel

    // Internal drag state
    @State private var dragStart: Double? = nil
    private enum DragMode { case newLoop, resizeStart, resizeEnd, moveLoop }
    @State private var dragMode: DragMode = .newLoop
    // For moveLoop: stores (loopStart, loopEnd, dragStartTime) at gesture begin
    @State private var moveAnchor: (loopStart: Double, loopEnd: Double, dragTime: Double)? = nil

    // Pixels within which a drag is treated as edge-resize
    private let edgeHitRadius: CGFloat = 12

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
                let x = value.location.x
                let ratio = Double(min(width, max(0, x)) / width)

                // Determine mode on first movement
                if dragStart == nil {
                    dragMode = detectDragMode(startX: value.startLocation.x, width: width)
                    dragStart = ratio
                    if dragMode == .moveLoop, let loop = vm.loop {
                        let startTime = Double(value.startLocation.x / width) * vm.duration
                        moveAnchor = (loop.start, loop.end, startTime)
                    }
                }

                let time = ratio * vm.duration

                switch dragMode {
                case .resizeStart:
                    guard let loop = vm.loop else { return }
                    let newStart = min(time, loop.end - 0.1)
                    vm.setLoop(LoopRegion(start: max(0, newStart), end: loop.end))

                case .resizeEnd:
                    guard let loop = vm.loop else { return }
                    let newEnd = max(time, loop.start + 0.1)
                    vm.setLoop(LoopRegion(start: loop.start, end: min(vm.duration, newEnd)))

                case .moveLoop:
                    guard let anchor = moveAnchor else { return }
                    let delta = time - anchor.dragTime
                    let dur = anchor.loopEnd - anchor.loopStart
                    let newStart = max(0, anchor.loopStart + delta)
                    let newEnd   = min(vm.duration, newStart + dur)
                    vm.setLoop(LoopRegion(start: newEnd - dur, end: newEnd))

                case .newLoop:
                    guard let startRatio = dragStart else { return }
                    let s = min(startRatio, ratio) * vm.duration
                    let e = max(startRatio, ratio) * vm.duration
                    if e > s { vm.setLoop(LoopRegion(start: s, end: e)) }
                }
            }
            .onEnded { value in
                let ratio = Double(min(width, max(0, value.location.x)) / width)
                let distance = abs(value.translation.width)
                if distance < 4, dragMode == .newLoop {
                    // Short tap → seek
                    vm.clearLoop()
                    vm.seek(to: ratio * vm.duration)
                }
                dragStart = nil
                moveAnchor = nil
                dragMode = .newLoop
            }
    }

    /// Decide whether the drag starts on an edge handle, inside the loop, or draws a new loop.
    private func detectDragMode(startX: CGFloat, width: CGFloat) -> DragMode {
        guard let loop = vm.loop, vm.duration > 0 else { return .newLoop }
        let startPx = CGFloat(loop.start / vm.duration) * width
        let endPx   = CGFloat(loop.end   / vm.duration) * width
        if abs(startX - startPx) <= edgeHitRadius { return .resizeStart }
        if abs(startX - endPx)   <= edgeHitRadius { return .resizeEnd }
        if startX > startPx && startX < endPx      { return .moveLoop }
        return .newLoop
    }
}
