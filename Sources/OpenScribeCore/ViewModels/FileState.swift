import Foundation
import OpenScribeModels

struct FileState: Codable {
    var loop: LoopRegion?
    var zoom: Double
    var pan: Double
    var speed: Float
    var pitch: Float
    var lastTime: TimeInterval
    var volume: Float?
    var bookmarks: [TimeInterval]?
}

enum FileStateStore {
    private static let prefix = "openscribe.fileState."

    private static func key(for url: URL) -> String {
        prefix + url.standardizedFileURL.path
    }

    static func load(for url: URL) -> FileState? {
        guard let data = UserDefaults.standard.data(forKey: key(for: url)) else { return nil }
        return try? JSONDecoder().decode(FileState.self, from: data)
    }

    static func save(_ state: FileState, for url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key(for: url))
    }
}
