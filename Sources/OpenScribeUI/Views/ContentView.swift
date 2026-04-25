import AppKit
import OpenScribeCore
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @ObservedObject var vm: PlayerViewModel
    @State private var isFilePickerShown = false
    @State private var keyEventMonitor: Any?

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
                    _ = url.startAccessingSecurityScopedResource()
                    vm.load(url: url)
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
                // Security-scoped resource access for sandbox
                if url.startAccessingSecurityScopedResource() {
                    vm.load(url: url)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileRequested)) { _ in
            isFilePickerShown = true
        }
        .onAppear {
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 49: // Space — play / pause
                    guard vm.duration > 0 else { return event }
                    vm.isPlaying ? vm.pause() : vm.play()
                    return nil
                case 123: // Left arrow — seek back
                    let step: Double = event.modifierFlags.contains(.shift) ? 1 : 5
                    vm.seek(to: max(0, vm.currentTime - step))
                    return nil
                case 124: // Right arrow — seek forward
                    let step: Double = event.modifierFlags.contains(.shift) ? 1 : 5
                    vm.seek(to: min(vm.duration, vm.currentTime + step))
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = keyEventMonitor {
                NSEvent.removeMonitor(monitor)
                keyEventMonitor = nil
            }
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
