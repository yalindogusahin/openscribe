import SwiftUI

struct ShortcutsView: View {
    private let rows: [(String, String)] = [
        ("Space",        "Play / Pause"),
        ("← / →",        "Seek 5s (Shift = 1s)"),
        ("Return",       "Jump to loop start"),
        ("Esc",          "Clear loop"),
        ("[ / ]",        "Set loop start / end at playhead"),
        ("⌘O",           "Open audio file"),
        ("Drag",         "Create loop on waveform"),
        ("⌥+drag",       "Pan zoomed waveform"),
        ("Scroll ↕",     "Zoom waveform at cursor"),
        ("Scroll ↔",     "Pan zoomed waveform"),
        ("Double-click", "Reset Speed / Pitch label"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard & Mouse")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                        Text(row.1)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
