import OpenScribeCore
import SwiftUI

public struct WaveformView: View {
    @ObservedObject var vm: PlayerViewModel

    // Internal drag state
    @State private var dragStart: Double? = nil
    private enum DragMode { case newLoop, resizeStart, resizeEnd, moveLoop }
    @State private var dragMode: DragMode = .newLoop
    @State private var moveAnchor: (loopStart: Double, loopEnd: Double, dragTime: Double)? = nil

    // Zoom & pan state (panOffset = visible start as fraction 0…1)
    @State private var zoomLevel: Double = 1.0
    @State private var panOffset: Double = 0.0

    // Hit radius for loop edge handles
    private let edgeHitRadius: CGFloat = 12

    public init(vm: PlayerViewModel) { self.vm = vm }

    // MARK: – Visible range helpers

    /// Visible start/end in normalised time [0, 1]
    private var visStart: Double { panOffset }
    private var visEnd:   Double { panOffset + 1.0 / zoomLevel }

    /// Canvas x pixel → actual time (seconds)
    private func xToTime(_ x: CGFloat, width: CGFloat) -> Double {
        let ratio = Double(x / width)          // 0…1 within visible window
        return (panOffset + ratio / zoomLevel) * vm.duration
    }

    /// Actual time → canvas x pixel (may be outside 0…width when off screen)
    private func timeToX(_ t: Double, width: CGFloat) -> CGFloat {
        guard vm.duration > 0 else { return 0 }
        return CGFloat((t / vm.duration - panOffset) * zoomLevel) * width
    }

    // MARK: – Scroll zoom

    private func handleScroll(dx: CGFloat, dy: CGFloat, mouseX: CGFloat, viewWidth: CGFloat) {
        // Vertical scroll → zoom centred on cursor
        if abs(dy) > abs(dx) {
            let cursorRatio = Double(mouseX / viewWidth)                // 0…1 in canvas
            let cursorNorm  = panOffset + cursorRatio / zoomLevel       // in normalised time

            let newZoom = max(1.0, min(64.0, zoomLevel * exp(Double(-dy) * 0.04)))
            let newPan  = max(0.0, min(1.0 - 1.0 / newZoom, cursorNorm - cursorRatio / newZoom))
            zoomLevel  = newZoom
            panOffset  = newZoom == 1.0 ? 0.0 : newPan
        } else {
            // Horizontal scroll → pan
            guard zoomLevel > 1 else { return }
            let delta = Double(dx) * 0.003 / zoomLevel
            panOffset = max(0.0, min(1.0 - 1.0 / zoomLevel, panOffset + delta))
        }
    }

    // MARK: – Body

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Canvas { ctx, size in
                drawBackground(ctx: ctx, size: size)
                drawWaveform(ctx: ctx, size: size)
                drawLoop(ctx: ctx, size: size)
                drawPlayhead(ctx: ctx, size: size)
                if zoomLevel > 1 { drawZoomLabel(ctx: ctx, size: size) }
            }
            .gesture(dragGesture(width: w))
            .onAppear { vm.waveformWidth = Int(w) }
            .onChange(of: w) { vm.waveformWidth = Int($0) }
            // Scroll wheel zoom (overlay so DragGesture still works)
            .overlay {
                ScrollWheelReader { dx, dy, mx, vw in
                    handleScroll(dx: dx, dy: dy, mouseX: mx, viewWidth: vw)
                }
            }
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

        let N = peaks.count
        let startIdx = max(0, Int(visStart * Double(N)))
        let endIdx   = min(N, Int(ceil(visEnd * Double(N))) + 1)
        guard endIdx > startIdx else { return }

        let mid    = size.height / 2
        let scaleY = (size.height / 2) - 4
        let step   = size.width / CGFloat(endIdx - startIdx)
        let waveColor = Color(red: 0.39, green: 0.71, blue: 1.0)

        var path = Path()
        for (i, peak) in peaks[startIdx..<endIdx].enumerated() {
            let x  = CGFloat(i) * step
            let y1 = mid - CGFloat(peak.max) * scaleY
            let y2 = mid - CGFloat(peak.min) * scaleY
            path.move(to: CGPoint(x: x, y: y1))
            path.addLine(to: CGPoint(x: x, y: max(y1 + 1, y2)))
        }
        ctx.stroke(path, with: .color(waveColor), lineWidth: 1)
    }

    private func drawLoop(ctx: GraphicsContext, size: CGSize) {
        guard let loop = vm.loop, vm.duration > 0 else { return }
        let x1 = timeToX(loop.start, width: size.width)
        let x2 = timeToX(loop.end,   width: size.width)
        let cx1 = max(0, x1), cx2 = min(size.width, x2)
        guard cx2 > cx1 else { return }

        // Semi-transparent fill
        ctx.fill(
            Path(CGRect(x: cx1, y: 0, width: cx2 - cx1, height: size.height)),
            with: .color(Color.blue.opacity(0.25))
        )
        // Border lines
        var border = Path()
        if x1 >= 0 {
            border.move(to: CGPoint(x: x1, y: 0)); border.addLine(to: CGPoint(x: x1, y: size.height))
        }
        if x2 <= size.width {
            border.move(to: CGPoint(x: x2, y: 0)); border.addLine(to: CGPoint(x: x2, y: size.height))
        }
        ctx.stroke(border, with: .color(Color.blue.opacity(0.7)), lineWidth: 1.5)
    }

    private func drawPlayhead(ctx: GraphicsContext, size: CGSize) {
        guard vm.duration > 0 else { return }
        let x = timeToX(vm.currentTime, width: size.width)
        guard x >= 0 && x <= size.width else { return }
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(path, with: .color(.red), lineWidth: 2)
    }

    private func drawZoomLabel(ctx: GraphicsContext, size: CGSize) {
        let label = String(format: "%.1f×", zoomLevel)
        ctx.draw(
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.4)),
            at: CGPoint(x: size.width - 4, y: 4),
            anchor: .topTrailing
        )
    }

    // MARK: – Gestures

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let x = value.location.x

                if dragStart == nil {
                    dragMode = detectDragMode(startX: value.startLocation.x, width: width)
                    dragStart = Double(x / width)
                    if dragMode == .moveLoop, let loop = vm.loop {
                        let startTime = xToTime(value.startLocation.x, width: width)
                        moveAnchor = (loop.start, loop.end, startTime)
                    }
                }

                let time = xToTime(max(0, min(width, x)), width: width)

                switch dragMode {
                case .resizeStart:
                    guard let loop = vm.loop else { return }
                    vm.setLoop(LoopRegion(start: max(0, min(time, loop.end - 0.1)), end: loop.end))

                case .resizeEnd:
                    guard let loop = vm.loop else { return }
                    vm.setLoop(LoopRegion(start: loop.start, end: min(vm.duration, max(time, loop.start + 0.1))))

                case .moveLoop:
                    guard let anchor = moveAnchor else { return }
                    let delta = time - anchor.dragTime
                    let dur   = anchor.loopEnd - anchor.loopStart
                    let newStart = max(0, anchor.loopStart + delta)
                    let newEnd   = min(vm.duration, newStart + dur)
                    vm.setLoop(LoopRegion(start: newEnd - dur, end: newEnd))

                case .newLoop:
                    let startTime = xToTime(max(0, min(width, CGFloat((dragStart ?? 0) * Double(width)))), width: width)
                    let s = min(startTime, time)
                    let e = max(startTime, time)
                    if e > s { vm.setLoop(LoopRegion(start: s, end: e)) }
                }
            }
            .onEnded { value in
                let time = xToTime(max(0, min(width, value.location.x)), width: width)
                if abs(value.translation.width) < 4, dragMode == .newLoop {
                    vm.clearLoop()
                    vm.seek(to: time)
                }
                dragStart  = nil
                moveAnchor = nil
                dragMode   = .newLoop
            }
    }

    private func detectDragMode(startX: CGFloat, width: CGFloat) -> DragMode {
        guard let loop = vm.loop, vm.duration > 0 else { return .newLoop }
        let sx = timeToX(loop.start, width: width)
        let ex = timeToX(loop.end,   width: width)
        if abs(startX - sx) <= edgeHitRadius { return .resizeStart }
        if abs(startX - ex) <= edgeHitRadius { return .resizeEnd }
        if startX > sx && startX < ex        { return .moveLoop }
        return .newLoop
    }
}
