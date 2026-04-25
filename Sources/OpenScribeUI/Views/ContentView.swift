import OpenScribeCore
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @ObservedObject var vm: PlayerViewModel
    @State private var isFilePickerShown = false

    public init(vm: PlayerViewModel) { self.vm = vm }

    public var body: some View {
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
        var types: [UTType] = [.mp3, .wav, .aiff]
        if let flac = UTType(filenameExtension: "flac") { types.append(flac) }
        if let m4a  = UTType(filenameExtension: "m4a")  { types.append(m4a) }
        if let aac  = UTType("public.aac-audio")         { types.append(aac) }
        return types
    }
}

extension Notification.Name {
    public static let openFileRequested = Notification.Name("openFileRequested")
}
