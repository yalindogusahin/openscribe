import OpenScribeCore
import SwiftUI

public struct TransportView: View {
    @ObservedObject var vm: PlayerViewModel
    @State private var showShortcuts = false

    public init(vm: PlayerViewModel) { self.vm = vm }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            singleRow
            twoRows
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Wide layout — everything on one line.
    private var singleRow: some View {
        HStack(spacing: 16) {
            transportButtons
            divider
            timeDisplay
            divider
            speedControl
            divider
            pitchControl
            divider
            volumeControl
            divider
            loopInfo
            Spacer()
            helpButton
        }
    }

    // Narrow layout — transport + time + loop + help on top, sliders below.
    private var twoRows: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                transportButtons
                divider
                timeDisplay
                divider
                loopInfo
                Spacer()
                helpButton
            }
            HStack(spacing: 12) {
                speedControl
                divider
                pitchControl
                divider
                volumeControl
                Spacer()
            }
        }
    }

    // MARK: – Pieces

    private var divider: some View {
        Divider().frame(height: 32)
    }

    private var transportButtons: some View {
        HStack(spacing: 12) {
            Button(action: togglePlay) {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(vm.duration == 0)

            Button(action: { vm.stop() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 20))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(vm.duration == 0)
        }
    }

    private var timeDisplay: some View {
        Text(timeString(vm.currentTime) + " / " + timeString(vm.duration))
            .font(.system(.body, design: .monospaced))
            .fixedSize()
    }

    private var speedControl: some View {
        HStack(spacing: 4) {
            Button("-") {
                vm.speed = max(0.25, round((vm.speed - 0.1) * 100) / 100)
            }
            .frame(width: 24)
            VStack(alignment: .center, spacing: 2) {
                Text("Speed: \(String(format: "%.2f", vm.speed))×")
                    .font(.caption)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { vm.speed = 1.0 }
                Slider(value: $vm.speed, in: 0.25...2.0, step: 0.05)
                    .frame(width: 120)
            }
            Button("+") {
                vm.speed = min(2.0, round((vm.speed + 0.1) * 100) / 100)
            }
            .frame(width: 24)
        }
    }

    private var pitchControl: some View {
        HStack(spacing: 4) {
            Button("-") {
                vm.pitch = max(-12, vm.pitch - 1)
            }
            .frame(width: 24)
            VStack(alignment: .center, spacing: 2) {
                let sign = vm.pitch > 0 ? "+" : ""
                Text("Pitch: \(sign)\(Int(vm.pitch)) st")
                    .font(.caption)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { vm.pitch = 0 }
                Slider(value: $vm.pitch, in: -12...12, step: 1)
                    .frame(width: 120)
            }
            Button("+") {
                vm.pitch = min(12, vm.pitch + 1)
            }
            .frame(width: 24)
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: vm.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
                .frame(width: 16)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { vm.volume = 1.0 }
            Slider(value: $vm.volume, in: 0...1)
                .frame(width: 70)
        }
    }

    private var loopInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let loop = vm.loop {
                Text("Loop: \(timeString(loop.start)) → \(timeString(loop.end))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text("No loop")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            Button("Clear Loop") { vm.clearLoop() }
                .disabled(vm.loop == nil)
                .font(.caption)
        }
    }

    private var helpButton: some View {
        Button {
            showShortcuts.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 16))
        }
        .buttonStyle(.plain)
        .help("Keyboard shortcuts")
        .popover(isPresented: $showShortcuts, arrowEdge: .bottom) {
            ShortcutsView()
        }
    }

    private func togglePlay() {
        vm.isPlaying ? vm.pause() : vm.play()
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = max(0, t)
        let whole = Int(total)
        let ms    = Int((total - Double(whole)) * 1000)
        return String(format: "%02d:%02d.%03d", whole / 60, whole % 60, ms)
    }
}
