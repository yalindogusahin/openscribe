import SwiftUI
import OpenScribeCore
import OpenScribeUI

@main
struct TranscribeApp: App {
    @StateObject private var vm = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
        }
        .commands {
            // Sistem File menüsündeki "New" grubunu "Open…" ile değiştir
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .openFileRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            // Loop menüsü
            CommandMenu("Loop") {
                Button("Clear Loop") { vm.clearLoop() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(vm.loop == nil)
            }
        }
    }
}
