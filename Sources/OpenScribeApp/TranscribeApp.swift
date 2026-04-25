import AppKit
import SwiftUI
import OpenScribeCore
import OpenScribeUI

// MARK: – Keyboard shortcut service (app-level, lives for the entire session)

private class KeyboardShortcutService {
    weak var vm: PlayerViewModel?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?

    init() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event) ?? event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event: event) ?? event
        }
    }

    deinit {
        if let keyMonitor    { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    private func handleScroll(event: NSEvent) -> NSEvent? {
        guard let vm else { return event }
        let mouse = event.locationInWindow
        guard vm.waveformWindowFrame.contains(mouse) else { return event }
        let localX  = mouse.x - vm.waveformWindowFrame.minX
        let viewW   = vm.waveformWindowFrame.width
        DispatchQueue.main.async {
            vm.handleWaveformScroll(
                dx: Double(event.scrollingDeltaX),
                dy: Double(event.scrollingDeltaY),
                mouseX: Double(localX),
                viewWidth: Double(viewW)
            )
        }
        return nil  // consume so sliders don't also react
    }

    private func handle(event: NSEvent) -> NSEvent? {
        // Cmd/Option combos must reach the menu / key-equivalent system.
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            return event
        }
        guard let vm else { return nil }
        if vm.duration > 0 {
            switch event.keyCode {
            case 49: // Space — play / pause
                DispatchQueue.main.async { vm.isPlaying ? vm.pause() : vm.play() }
            case 123: // Left arrow — seek back
                let step: TimeInterval = event.modifierFlags.contains(.shift) ? 1 : 5
                DispatchQueue.main.async { vm.seek(to: max(0, vm.currentTime - step)) }
            case 124: // Right arrow — seek forward
                let step: TimeInterval = event.modifierFlags.contains(.shift) ? 1 : 5
                DispatchQueue.main.async { vm.seek(to: min(vm.duration, vm.currentTime + step)) }
            case 36: // Return — jump to loop start (or beginning if no loop)
                DispatchQueue.main.async { vm.seek(to: vm.loop?.start ?? 0) }
            case 53: // Escape — clear loop
                DispatchQueue.main.async { vm.clearLoop() }
            case 33: // [ — set loop start at playhead (Shift = nudge -50ms)
                if event.modifierFlags.contains(.shift) {
                    DispatchQueue.main.async { vm.nudgeLoopStart(by: -0.05) }
                } else {
                    DispatchQueue.main.async { vm.setLoopStart(at: vm.currentTime) }
                }
            case 30: // ] — set loop end at playhead (Shift = nudge +50ms)
                if event.modifierFlags.contains(.shift) {
                    DispatchQueue.main.async { vm.nudgeLoopEnd(by: 0.05) }
                } else {
                    DispatchQueue.main.async { vm.setLoopEnd(at: vm.currentTime) }
                }
            case 11: // B — toggle bookmark at playhead
                DispatchQueue.main.async { vm.toggleBookmark(at: vm.currentTime) }
            case 18, 19, 20, 21, 22, 23, 25, 26, 28:
                // 1...9 → jump to bookmark N (no modifiers)
                let map: [UInt16: Int] = [18:0, 19:1, 20:2, 21:3, 23:4, 22:5, 26:6, 28:7, 25:8]
                if let idx = map[event.keyCode] {
                    DispatchQueue.main.async { vm.jumpToBookmark(idx) }
                }
            default:
                break
            }
        }
        // Always consume non-Cmd/Option keys so unhandled keys never trigger the system beep.
        return nil
    }
}

// MARK: – App entry point

// Global singleton — ensures exactly one set of NSEvent monitors for the app's lifetime.
// A stored `let` on a SwiftUI App struct (value type) can be recreated on each body
// evaluation, causing monitor churn that lets key events slip through and trigger the
// macOS system beep even when shortcuts are otherwise functional.
private let sharedKeyboard = KeyboardShortcutService()

@main
struct OpenScribeApp: App {
    @StateObject private var vm = PlayerViewModel()
    @State private var recentRefresh = 0  // bumped to force the Recent menu to rebuild

    private func openRecent(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        vm.load(url: url)
        recentRefresh &+= 1
    }

    init() {
        // Suppress macOS system beep on unhandled key events (must run before any window is created).
        _ = BeepSuppressor.install
        // Eagerly initialize the keyboard service so the NSEvent monitor is installed
        // before the first key event arrives.
        _ = sharedKeyboard
    }

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .onAppear { sharedKeyboard.vm = vm }
                .onChange(of: vm.loadedURL) { _ in recentRefresh &+= 1 }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About OpenScribe") {
                    let credits = NSAttributedString(
                        string: "Free macOS audio loop player.\nhttps://github.com/yalindogusahin/openscribe",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 11),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    )
                    NSApp.orderFrontStandardAboutPanel(options: [
                        NSApplication.AboutPanelOptionKey.credits: credits
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .openFileRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    let _ = recentRefresh  // re-evaluates when bumped
                    let recents = RecentFilesStore.urls()
                    if recents.isEmpty {
                        Text("No recent files").disabled(true)
                    } else {
                        ForEach(recents, id: \.self) { url in
                            Button(url.lastPathComponent) { openRecent(url) }
                        }
                        Divider()
                        Button("Clear Menu") {
                            RecentFilesStore.clear()
                            recentRefresh &+= 1
                        }
                    }
                }
            }
            CommandMenu("Loop") {
                // Escape is handled in KeyboardShortcutService to avoid the SwiftUI
                // beep when the menu item is disabled (no loop active).
                Button("Clear Loop") { vm.clearLoop() }
                    .disabled(vm.loop == nil)
            }
        }
    }
}
