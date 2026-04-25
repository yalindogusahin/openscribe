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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                guard let url else { return }
                DispatchQueue.main.async {
                    loadWithScope(url)
                }
            }
            return true
        }
        .fileImporter(
            isPresented: $isFilePickerShown,
            allowedContentTypes: supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                loadWithScope(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileRequested)) { _ in
            isFilePickerShown = true
        }
        .frame(minWidth: 700, minHeight: 220)
    }

    /// Acquire sandbox scope before loading; PlayerViewModel releases it
    /// when a new file replaces this one (or on deinit).
    private func loadWithScope(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        vm.load(url: url)
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
