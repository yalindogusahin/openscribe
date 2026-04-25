import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var vm: PlayerViewModel
    @State private var isFilePickerShown = false

    var body: some View {
        VStack(spacing: 0) {
            WaveformView(vm: vm)
                .frame(maxWidth: .infinity)

            Divider()

            TransportView(vm: vm)
        }
        .fileImporter(
            isPresented: $isFilePickerShown,
            allowedContentTypes: supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                // Sandbox erişimi için güvenlik kapsamı
                if url.startAccessingSecurityScopedResource() {
                    vm.load(url: url)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileRequested)) { _ in
            isFilePickerShown = true
        }
        .frame(minWidth: 700, minHeight: 220)
    }

    private var supportedTypes: [UTType] {
        [.mp3, .wav, .aiff, .flac, .m4a, UTType("public.aac-audio")].compactMap { $0 }
    }
}

extension Notification.Name {
    static let openFileRequested = Notification.Name("openFileRequested")
}
