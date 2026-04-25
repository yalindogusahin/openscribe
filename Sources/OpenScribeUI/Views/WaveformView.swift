import AppKit
import OpenScribeCore
import SwiftUI

public struct WaveformView: View {
    @ObservedObject var vm: PlayerViewModel

    // Internal drag state
    @State private var dragStart: Double? = nil
    private enum DragMode { case newLoop, resizeStart, resizeEnd, moveLoop, pan }
    @State private var dragMode: DragMode = .newLoop
    @State private var moveAnchor: (loopStart: Double, loopEnd: Double, dragTime: Double)? = nil
    @State private var panAnchor: Double = 0
    @State private var isDragging = false

    // Hit radius for loop edge handles
    private let edgeHitRadius: CGFloat = 12

    public init(vm: PlayerViewModel) { self.vm = vm }

    // MARK: – Zoom helpers (state lives in vm)

    private var zoomLevel: Double { vm.waveformZoomLevel }
    private var panOffset: Double { vm.waveformPanOffset }
    private var visStart:  Double { panOffset }
    private var visEnd:    Double { panOffset + 1.0 / zoomLevel }

    private func xToTime(_ x: CGFloat, width: CGFloat) -> Double {
        let ratio = Double(x / width)
        return (panOffset + ratio / zoomLevel) * vm.duration
    }

    private func timeToX(_ t: Double, width: CGFloat) -> CGFloat {
        guard vm.duration > 0 else { return 0 }
        return CGFloat((t / vm.duration - panOffset) * zoomLevel) * width
    }

    // MARK: – Body

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Canvas { ctx, size in
                drawBackground(ctx: ctx, size: size)
                drawWaveform(ctx: ctx, size: size)
                drawLoop(ctx: ctx, size: size)
                drawBookmarks(ctx: ctx, size: size)
                drawPlayhead(ctx: ctx, size: size)
                if zoomLevel > 1 { drawZoomLabel(ctx: ctx, size: size) }
            }
            .gesture(dragGesture(width: w))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): cursorFor(location: location, width: w).set()
                case .ended:               NSCursor.arrow.set()
                }
            }
            .background(
                FrameReporter { frame in vm.waveformWindowFrame = frame }
            )
            .onAppear { vm.waveformWidth = Int(w) }
            .onChange(of: w) { vm.waveformWidth = Int($0) }
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

        let N        = peaks.count
        let startIdx = max(0, Int(visStart * Double(N)))
        let endIdx   = min(N, Int(ceil(visEnd * Double(N))) + 1)
        guard endIdx > startIdx else { return }

        let visibleCount = endIdx - startIdx
        let pixelWidth   = max(1, Int(size.width))
        let mid          = size.height / 2
        let scaleY       = (size.height / 2) - 4

        var path = Path()
        let waveColor = Color(red: 0.39, green: 0.71, blue: 1.0)

        if visibleCount > pixelWidth {
            // Dense data: aggregate min/max per screen pixel for clean rendering.
            for px in 0..<pixelWidth {
                let bucketStart = startIdx + px * visibleCount / pixelWidth
                let bucketEnd   = startIdx + (px + 1) * visibleCount / pixelWidth
                guard bucketEnd > bucketStart else { continue }
                var mn: Float = 0
                var mx: Float = 0
                for i in bucketStart..<bucketEnd {
                    if peaks[i].min < mn { mn = peaks[i].min }
                    if peaks[i].max > mx { mx = peaks[i].max }
                }
                let x  = CGFloat(px)
                let y1 = mid - CGFloat(mx) * scaleY
                let y2 = mid - CGFloat(mn) * scaleY
                path.move(to: CGPoint(x: x, y: y1))
                path.addLine(to: CGPoint(x: x, y: max(y1 + 1, y2)))
            }
        } else {
            // Zoomed-in: fewer peaks than pixels. Draw a smooth filled silhouette
            // by tracing the upper envelope, then back along the lower envelope.
            let step = size.width / CGFloat(visibleCount)
            // Upper envelope
            for (i, peak) in peaks[startIdx..<endIdx].enumerated() {
                let x = CGFloat(i) * step
                let y = mid - CGFloat(peak.max) * scaleY
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else      { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            // Lower envelope (reverse)
            for (i, peak) in peaks[startIdx..<endIdx].enumerated().reversed() {
                let x = CGFloat(i) * step
                let y = mid - CGFloat(peak.min) * scaleY
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.closeSubpath()
            ctx.fill(path, with: .color(waveColor.opacity(0.85)))
            return
        }
        ctx.stroke(path, with: .color(waveColor), lineWidth: 1)
    }

    private func drawLoop(ctx: GraphicsContext, size: CGSize) {
        guard let loop = vm.loop, vm.duration > 0 else { return }
        let x1 = timeToX(loop.start, width: size.width)
        let x2 = timeToX(loop.end,   width: size.width)
        let cx1 = max(0, x1), cx2 = min(size.width, x2)
        guard cx2 > cx1 else { return }

        ctx.fill(
            Path(CGRect(x: cx1, y: 0, width: cx2 - cx1, height: size.height)),
            with: .color(Color.blue.opacity(0.25))
        )
        var border = Path()
        if x1 >= 0 {
            border.move(to: CGPoint(x: x1, y: 0)); border.addLine(to: CGPoint(x: x1, y: size.height))
        }
        if x2 <= size.width {
            border.move(to: CGPoint(x: x2, y: 0)); border.addLine(to: CGPoint(x: x2, y: size.height))
        }
        ctx.stroke(border, with: .color(Color.blue.opacity(0.7)), lineWidth: 1.5)
    }

    private func drawBookmarks(ctx: GraphicsContext, size: CGSize) {
        guard vm.duration > 0 else { return }
        let color = Color(red: 1.0, green: 0.85, blue: 0.30)
        for (i, t) in vm.bookmarks.enumerated() {
            let x = timeToX(t, width: size.width)
            guard x >= 0 && x <= size.width else { continue }
            // Vertical line
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(line, with: .color(color.opacity(0.55)), lineWidth: 1)
            // Top flag
            var flag = Path()
            flag.move(to: CGPoint(x: x, y: 0))
            flag.addLine(to: CGPoint(x: x + 12, y: 0))
            flag.addLine(to: CGPoint(x: x + 12, y: 10))
            flag.addLine(to: CGPoint(x: x + 6, y: 14))
            flag.addLine(to: CGPoint(x: x, y: 10))
            flag.closeSubpath()
            ctx.fill(flag, with: .color(color))
            ctx.draw(
                Text("\(i + 1)").font(.system(size: 9, weight: .bold)).foregroundColor(.black),
                at: CGPoint(x: x + 6, y: 7),
                anchor: .center
            )
        }
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
        ctx.draw(
            Text(String(format: "%.1f×", zoomLevel))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.4)),
            at: CGPoint(x: size.width - 4, y: 4),
            anchor: .topTrailing
        )
    }

    // MARK: – Cursor

    private func cursorFor(location: CGPoint, width: CGFloat) -> NSCursor {
        if isDragging {
            switch dragMode {
            case .resizeStart, .resizeEnd: return .resizeLeftRight
            case .moveLoop, .pan:         return .closedHand
            case .newLoop:                return .crosshair
            }
        }
        // Option held (zoomed in) → hint at pan with an open hand.
        if NSEvent.modifierFlags.contains(.option) && zoomLevel > 1 { return .openHand }
        guard let loop = vm.loop, vm.duration > 0 else { return .crosshair }
        let sx = timeToX(loop.start, width: width)
        let ex = timeToX(loop.end,   width: width)
        let x  = location.x
        if abs(x - sx) <= edgeHitRadius || abs(x - ex) <= edgeHitRadius { return .resizeLeftRight }
        if x > sx && x < ex { return .openHand }
        return .crosshair
    }

    // MARK: – Gestures

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let x = value.location.x

                if dragStart == nil {
                    isDragging = true
                    dragMode   = detectDragMode(startX: value.startLocation.x, width: width)
                    dragStart  = Double(value.startLocation.x / width)
                    if dragMode == .moveLoop, let loop = vm.loop {
                        moveAnchor = (loop.start, loop.end, xToTime(value.startLocation.x, width: width))
                    }
                    if dragMode == .pan {
                        panAnchor = vm.waveformPanOffset
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
                    let delta    = time - anchor.dragTime
                    let dur      = anchor.loopEnd - anchor.loopStart
                    let newStart = max(0, anchor.loopStart + delta)
                    let newEnd   = min(vm.duration, newStart + dur)
                    vm.setLoop(LoopRegion(start: newEnd - dur, end: newEnd))

                case .newLoop:
                    guard let startRatio = dragStart else { return }
                    let startTime = xToTime(CGFloat(startRatio) * width, width: width)
                    let s = min(startTime, time)
                    let e = max(startTime, time)
                    if e > s { vm.setLoop(LoopRegion(start: s, end: e)) }

                case .pan:
                    // Drag right → reveal earlier content (pan offset decreases).
                    let dragNorm = Double(value.translation.width / width) / zoomLevel
                    let maxPan = max(0.0, 1.0 - 1.0 / zoomLevel)
                    vm.waveformPanOffset = max(0.0, min(maxPan, panAnchor - dragNorm))
                }
            }
            .onEnded { value in
                let time = xToTime(max(0, min(width, value.location.x)), width: width)
                if abs(value.translation.width) < 4, dragMode == .newLoop {
                    vm.clearLoop()
                    vm.seek(to: time)
                } else if dragMode == .newLoop, let loop = vm.loop {
                    // Snap playhead to the new loop's start so playback enters
                    // the loop immediately — works whether playing or paused.
                    vm.seek(to: loop.start)
                }
                dragStart  = nil
                moveAnchor = nil
                dragMode   = .newLoop
                isDragging = false
            }
    }

    private func detectDragMode(startX: CGFloat, width: CGFloat) -> DragMode {
        // Option held → pan the visible window without touching the loop.
        if NSEvent.modifierFlags.contains(.option) { return .pan }
        guard let loop = vm.loop, vm.duration > 0 else { return .newLoop }
        let sx = timeToX(loop.start, width: width)
        let ex = timeToX(loop.end,   width: width)
        if abs(startX - sx) <= edgeHitRadius { return .resizeStart }
        if abs(startX - ex) <= edgeHitRadius { return .resizeEnd }
        if startX > sx && startX < ex        { return .moveLoop }
        return .newLoop
    }
}
