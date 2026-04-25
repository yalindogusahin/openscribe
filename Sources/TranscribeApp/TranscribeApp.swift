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
            CommandGroup(replacing: .newItem) {}
            CommandMenu("File") {
                Button("Open…") {
                    NotificationCenter.default.post(name: .openFileRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Loop") {
                Button("Loop Temizle") { vm.clearLoop() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(vm.loop == nil)
            }
        }
    }
}
