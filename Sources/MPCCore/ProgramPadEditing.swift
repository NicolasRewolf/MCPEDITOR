import Foundation

public enum ProgramPadEditingError: LocalizedError, Equatable {
    case invalidPad(Int)
    case emptySource(Int)
    case sharedNote(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPad(let pad):
            return String(localized: "Le pad \(pad) n’existe pas ; les pads vont de A01 à D16.")
        case .emptySource(let pad):
            return String(localized: "Le pad \(Self.label(pad)) est vide.")
        case .sharedNote(let note):
            return String(localized: "La note MIDI \(note) est partagée par plusieurs pads. Le déplacement ou la copie est annulé pour préserver leurs réglages.")
        }
    }

    private static func label(_ pad: Int) -> String {
        ["A", "B", "C", "D"][pad / 16] + String(format: "%02d", pad % 16 + 1)
    }
}

extension MPCProgram {
    /// Move a pad into an empty pad, exchange two occupied pads, or copy a pad.
    ///
    /// Moving exchanges the two pad-to-MIDI-note map entries, leaving the entire
    /// note and mixer images intact. This preserves tuning, envelopes, routing,
    /// alternate/choke references, unknown bytes, and existing MIDI sequencing.
    /// Copying leaves the map intact and copies the complete 24-byte note record
    /// and 4-byte mixer record. Alternate/choke references keep their exact MIDI
    /// note values; they are not reinterpreted or redirected to the new pad.
    ///
    /// Sound slots and the sound inventory are retained in either case, so the
    /// caller must retain its sound pool. The copy shares the source sound slot.
    /// Only the two affected map entries (move) or destination records (copy)
    /// can change. Invalid programs, empty sources, and MIDI-note aliases are
    /// rejected without mutation. Pads are zero-based across the four banks.
    public mutating func transferPad(from source: Int, to destination: Int, copy: Bool = false) throws {
        for pad in [source, destination] {
            guard (0..<64).contains(pad) else { throw ProgramPadEditingError.invalidPad(pad) }
        }
        try validateKnownFields()

        // Work with a zero-based copy: public `bytes` can be a Data slice.
        var image = Array(bytes)
        let mapBase = 2690 + 1854
        let sourceNote = Int(image[mapBase + source])
        let destinationNote = Int(image[mapBase + destination])
        let noteBase = 2690 + 62
        let sourceRecord = noteBase + (sourceNote - 35) * 24
        guard image[sourceRecord] != 0xFF else {
            throw ProgramPadEditingError.emptySource(source)
        }
        guard source != destination else { return }

        for note in [sourceNote, destinationNote] {
            guard image[mapBase..<(mapBase + 64)].filter({ Int($0) == note }).count == 1 else {
                throw ProgramPadEditingError.sharedNote(note)
            }
        }

        if copy {
            let destinationRecord = noteBase + (destinationNote - 35) * 24
            let mixerBase = 2690 + 1598
            let sourceMixer = mixerBase + (sourceNote - 35) * 4
            let destinationMixer = mixerBase + (destinationNote - 35) * 4
            let noteRecord = Array(image[sourceRecord..<(sourceRecord + 24)])
            let mixerRecord = Array(image[sourceMixer..<(sourceMixer + 4)])
            image.replaceSubrange(destinationRecord..<(destinationRecord + 24), with: noteRecord)
            image.replaceSubrange(destinationMixer..<(destinationMixer + 4), with: mixerRecord)
        } else {
            image.swapAt(mapBase + source, mapBase + destination)
        }
        bytes = Data(image)
    }
}
