import AppKit
import SwiftUI
import OpenScribeCore
import OpenScribeUI

// MARK: – Keyboard shortcut service (app-level, lives for the entire session)

private class KeyboardShortcutService {
    weak var vm: PlayerViewModel?
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event) ?? event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(event: NSEvent) -> NSEvent? {
        guard let vm, vm.duration > 0 else { return event }
        switch event.keyCode {
        case 49: // Space — play / pause
            DispatchQueue.main.async { vm.isPlaying ? vm.pause() : vm.play() }
            return nil
        case 123: // Left arrow — seek back
            let step: TimeInterval = event.modifierFlags.contains(.shift) ? 1 : 5
            DispatchQueue.main.async { vm.seek(to: max(0, vm.currentTime - step)) }
            return nil
        case 124: // Right arrow — seek forward
            let step: TimeInterval = event.modifierFlags.contains(.shift) ? 1 : 5
            DispatchQueue.main.async { vm.seek(to: min(vm.duration, vm.currentTime + step)) }
            return nil
        default:
            return event
        }
    }
}

// MARK: – App entry point

@main
struct OpenScribeApp: App {
    @StateObject private var vm = PlayerViewModel()
    // Retained for the app's lifetime
    private let keyboard = KeyboardShortcutService()

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .onAppear { keyboard.vm = vm }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .openFileRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Loop") {
                Button("Clear Loop") { vm.clearLoop() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(vm.loop == nil)
            }
        }
    }
}
