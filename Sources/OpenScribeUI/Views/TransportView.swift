import OpenScribeCore
import SwiftUI

public struct TransportView: View {
    @ObservedObject var vm: PlayerViewModel

    public init(vm: PlayerViewModel) { self.vm = vm }

    public var body: some View {
        HStack(spacing: 20) {
            // ---- Play / Pause ----
            Button(action: togglePlay) {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(vm.duration == 0)

            // ---- Stop ----
            Button(action: { vm.stop() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 20))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(vm.duration == 0)

            Divider().frame(height: 32)

            // ---- Süre ----
            Text(timeString(vm.currentTime) + " / " + timeString(vm.duration))
                .font(.system(.body, design: .monospaced))
                .frame(width: 120, alignment: .leading)

            Divider().frame(height: 32)

            // ---- Speed ----
            HStack(spacing: 4) {
                Button("-") {
                    vm.speed = max(0.25, round((vm.speed - 0.1) * 100) / 100)
                }
                .frame(width: 24)
                VStack(alignment: .center, spacing: 2) {
                    Text("Speed: \(String(format: "%.2f", vm.speed))×")
                        .font(.caption)
                    Slider(value: $vm.speed, in: 0.25...2.0, step: 0.05)
                        .frame(width: 140)
                }
                Button("+") {
                    vm.speed = min(2.0, round((vm.speed + 0.1) * 100) / 100)
                }
                .frame(width: 24)
            }

            Divider().frame(height: 32)

            // ---- Pitch ----
            VStack(alignment: .leading, spacing: 2) {
                let sign = vm.pitch > 0 ? "+" : ""
                Text("Pitch: \(sign)\(Int(vm.pitch)) st")
                    .font(.caption)
                Slider(value: $vm.pitch, in: -12...12, step: 1)
                    .frame(width: 160)
            }

            Divider().frame(height: 32)

            // ---- Clear Loop ----
            Button("Clear Loop") { vm.clearLoop() }
                .disabled(vm.loop == nil)
                .keyboardShortcut(.escape, modifiers: [])

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func togglePlay() {
        vm.isPlaying ? vm.pause() : vm.play()
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
