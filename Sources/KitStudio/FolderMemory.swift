import Foundation

/// Added folders stay stored as paths, in order, with a bookmark per path. A bookmark
/// follows a volume that macOS remounts under another name ("T9" then "T9 1"), as long
/// as the folder keeps its path inside that volume. An older entry without a usable
/// bookmark falls back to the same path on a sibling mount name, only when exactly one
/// candidate exists; an ambiguity keeps the stored path.
enum FolderMemory {
    static let bookmarksKey = "library.folderBookmarks"

    static func resolve(_ folders: [URL], defaults: UserDefaults,
                        volumes: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)) -> [URL] {
        let marks = bookmarks(defaults)
        return folders.map { folder in
            if isDirectory(folder) { return folder }
            if let data = marks[folder.path], let resolved = resolveBookmark(data), isDirectory(resolved),
               isSameFolderOnRemountedVolume(folder, resolved, volumes: volumes) {
                return resolved.standardizedFileURL
            }
            return remountedSibling(of: folder, volumes: volumes) ?? folder
        }
    }

    /// Bookmarks are refreshed for every folder that is reachable now.
    static func remember(_ folders: [URL], defaults: UserDefaults) {
        var marks = bookmarks(defaults)
        for folder in folders where isDirectory(folder) {
            if let data = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                marks[folder.path] = data
            }
        }
        defaults.set(marks, forKey: bookmarksKey)
    }

    static func remountedSibling(of folder: URL, volumes: URL) -> URL? {
        let components = folder.standardizedFileURL.pathComponents
        let root = volumes.standardizedFileURL.pathComponents
        guard components.count > root.count, components.starts(with: root) else { return nil }
        let name = components[root.count]
        let rest = components.dropFirst(root.count + 1)
        let base = baseVolumeName(name)
        let candidates = ([base] + (1...9).map { "\(base) \($0)" }).filter { $0 != name }
        let found = candidates
            .map { candidate in
                rest.reduce(volumes.appendingPathComponent(candidate, isDirectory: true)) {
                    $0.appendingPathComponent($1, isDirectory: true)
                }
            }
            .filter(isDirectory)
        return found.count == 1 ? found[0].standardizedFileURL : nil
    }

    /// A bookmark may follow the folder's volume to a new mount name, never the folder to
    /// a new place: a moved or renamed folder stays unavailable, as the library expects.
    static func isSameFolderOnRemountedVolume(_ stored: URL, _ resolved: URL, volumes: URL) -> Bool {
        let root = volumes.standardizedFileURL.pathComponents
        let before = stored.standardizedFileURL.pathComponents
        let after = resolved.standardizedFileURL.pathComponents
        guard before.count > root.count, after.count > root.count,
              before.starts(with: root), after.starts(with: root) else { return false }
        return Array(before.dropFirst(root.count + 1)) == Array(after.dropFirst(root.count + 1))
    }

    /// macOS appends " 1", " 2"… to a duplicate mount name; a longer number is part of the name.
    static func baseVolumeName(_ name: String) -> String {
        guard let space = name.lastIndex(of: " "),
              let number = Int(name[name.index(after: space)...]), (1...99).contains(number) else { return name }
        return String(name[..<space])
    }

    private static func bookmarks(_ defaults: UserDefaults) -> [String: Data] {
        (defaults.dictionary(forKey: bookmarksKey) as? [String: Data]) ?? [:]
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}
