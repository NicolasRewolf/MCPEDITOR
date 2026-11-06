import Foundation
import MPCCore

/// Text formatting shared by the views: counted nouns and decimals.
enum LibraryFormat {
    // Counted nouns. French, the source, is singular for 0 and 1 and is chosen here, so the text
    // is right even without the catalog (tests, swift run); the catalog gives other languages
    // their own plural forms, English "0 samples" included.
    static func samples(_ count: Int) -> String {
        count <= 1 ? String(localized: "\(count) sample") : String(localized: "\(count) samples")
    }

    static func results(_ count: Int) -> String {
        count <= 1 ? String(localized: "\(count) résultat") : String(localized: "\(count) résultats")
    }

    static func importedSamples(_ count: Int) -> String {
        count <= 1 ? String(localized: "\(count) sample importé.") : String(localized: "\(count) samples importés.")
    }

    static func emptyParts(_ count: Int) -> String {
        count <= 1 ? String(localized: "+ \(count) PART vide") : String(localized: "+ \(count) PART vides")
    }

    static func assignedPads(_ count: Int) -> String {
        count <= 1 ? String(localized: "\(count) pad affecté") : String(localized: "\(count) pads affectés")
    }

    static func programs(_ count: Int) -> String { String(localized: "\(count) .PGM") }

    /// Decimals follow the reader's region, like the sizes from ByteCountFormatter: "1,100" in France.
    static func decimal(_ value: Double, digits: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
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
            let count = metadata.appleDoubleCount
            parts.append(count == 1 ? String(localized: "\(count) fichier ._ (\(size))")
                                    : String(localized: "\(count) fichiers ._ (\(size))"))
        }
        parts += metadata.systemFolders.filter { $0 != ".fseventsd" }
        guard !parts.isEmpty else { return nil }
        let list = parts.joined(separator: " · ")
        return metadata.isComplete ? String(localized: "macOS : \(list)") : String(localized: "macOS : \(list) · relevé incomplet")
    }
}
