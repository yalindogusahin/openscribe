# OpenScribe

A free, open-source music transcription tool for macOS — built as an alternative to [Transcribe!](https://www.seventhstring.com/xscribe/overview.html).

<!-- screenshot -->

## Features

- **Waveform visualizer** — see the full audio waveform at a glance
- **Mouse-driven loop selection** — drag to select any region, press Escape to clear
- **Pitch-preserving speed control** — slow down to 0.25× without changing the pitch
- **Pitch shifting** — transpose ±12 semitones independently of speed
- **Broad format support** — MP3, WAV, FLAC, AIFF, M4A / AAC

## Requirements

- macOS 13 Ventura or later
- Xcode 14 or later (for building from source)

## Build & Run

```bash
git clone https://github.com/yourusername/openscribe.git
cd openscribe
swift run
```

Or build without running:

```bash
swift build
.build/debug/OpenScribe
```

## Testing

```bash
swift test
```

## Architecture

OpenScribe follows **MVVM** with a dedicated audio layer:

| Layer | Files | Responsibility |
|---|---|---|
| Model | `LoopRegion.swift` | Pure data, loop validation & clamping |
| Audio | `AudioEngine.swift`, `WaveformAnalyzer.swift` | AVAudioEngine pipeline, waveform peaks |
| ViewModel | `PlayerViewModel.swift` | UI state, coordinates audio ↔ views |
| View | `WaveformView.swift`, `TransportView.swift`, `ContentView.swift` | SwiftUI rendering & gestures |

The audio pipeline: `AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixerNode → output`

`AVAudioUnitTimePitch` handles both speed (`rate`) and pitch (`pitch` in cents) natively — no external libraries required.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE)
