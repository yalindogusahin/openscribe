# OpenScribe

A free, open-source music transcription tool for macOS — built as an alternative to [Transcribe!](https://www.seventhstring.com/xscribe/overview.html).

> *"If I stop practice for one day, I notice it; two days, my friends notice it; three days, the public notices it."*
> — Hans von Bülow (1877)

![OpenScribe screenshot](docs/screenshot.png)

## Features

- **Waveform visualizer** — see the full audio waveform at a glance
- **Mouse-driven loop selection** — drag to select any region, press Escape to clear
- **Pitch-preserving speed control** — slow down to 0.25× without changing the pitch
- **Pitch shifting** — transpose ±12 semitones independently of speed
- **Broad format support** — MP3, WAV, FLAC, AIFF, M4A / AAC

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (clang, Metal toolchain)

## Download

Grab the latest `.zip` from the [Releases](../../releases) page, unzip, and move `OpenScribeNative.app` to your Applications folder.

> **First launch:** right-click → Open to bypass the Gatekeeper warning (the app is not yet notarized).

## Build from Source

**Prerequisites:** Xcode Command Line Tools (`xcode-select --install`)

```bash
git clone https://github.com/yalindogusahin/openscribe.git
cd openscribe
bash cpp/build.sh 1.0.0
open cpp/OpenScribeNative.app
```

## Architecture

Native macOS app written in C++/Objective-C++ (Cocoa + AVFoundation + Metal).

| Layer | Files | Responsibility |
|---|---|---|
| App | `main.mm`, `AppDelegate.mm` | Entry point, lifecycle |
| Audio | `AudioEngine.mm` | AVFoundation pipeline, looping, time/pitch |
| Views | `MainWindow.mm`, `WaveformView.mm`, `TimelineRulerView.mm` | Cocoa + Metal-rendered waveform |
| Settings | `SettingsWindowController.mm` | Output device picker, prefs |

The audio pipeline uses `AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixerNode → output`. `AVAudioUnitTimePitch` handles both speed (`rate`) and pitch (`pitch` in cents) natively. The waveform is rendered with a Metal shader (`WaveformShaders.metal`) for smooth zoom at any scale.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE)
