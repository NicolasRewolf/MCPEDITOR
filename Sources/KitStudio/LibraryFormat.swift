import Foundation
import MPCCore

/// Formatting shared by the sample and .PGM columns.
enum LibraryFormat {
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value > 1 ? "s" : "")"
    }

    /// "/Volumes/T9/…" → "T9"; a folder of the Mac's own disk has no volume to name.
    static func volumeName(of url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return nil }
        return components[2]
    }

    /// `.fseventsd` exists on every mounted PART; only what costs or blocks is shown inline.
    static func macOSSummary(_ metadata: MacOSMetadata) -> String? {
        var parts: [String] = []
        if metadata.appleDoubleCount > 0 {
            let size = ByteCountFormatter.string(fromByteCount: metadata.appleDoubleBytes, countStyle: .file)
            parts.append("\(metadata.appleDoubleCount) fichier\(metadata.appleDoubleCount > 1 ? "s" : "") ._ (\(size))")
        }
        parts += metadata.systemFolders.filter { $0 != ".fseventsd" }
        guard !parts.isEmpty else { return nil }
        return "macOS : " + parts.joined(separator: " · ") + (metadata.isComplete ? "" : " · relevé incomplet")
    }
}
