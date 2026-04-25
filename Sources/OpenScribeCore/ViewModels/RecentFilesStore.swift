import Foundation

public enum RecentFilesStore {
    private static let key = "openscribe.recentFiles"
    private static let maxCount = 10

    public static func add(_ url: URL) {
        var list = load()
        let path = url.standardizedFileURL.path
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        UserDefaults.standard.set(list, forKey: key)
    }

    public static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    public static func urls() -> [URL] {
        load().compactMap { URL(fileURLWithPath: $0) }
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
