import Foundation

public enum MPCFormatError: LocalizedError {
    case invalid(String)
    case unsupported(String)
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "Fichier MPC invalide : \(detail)"
        case .unsupported(let detail): return "Format MPC non pris en charge : \(detail)"
        case .tooLarge: return "Le son dépasse la limite de 32 Mio."
        }
    }
}

private enum MPCBytes {
    static func u32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
    }
    static func put32(_ value: UInt32, into b: inout [UInt8], at p: Int) {
        for i in 0..<4 { b[p + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    static func text(_ b: [UInt8], at p: Int, count: Int) -> String {
        let part = b[p..<(p + count)].prefix { $0 != 0 }
        return String(bytes: part, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
    static func putName(_ name: String, into b: inout [UInt8], at p: Int, terminated: Bool) {
        let encoded = Array(MPCSound.safeName(name).utf8)
        for i in 0..<16 { b[p + i] = i < encoded.count ? encoded[i] : 32 }
        if terminated { b[p + 16] = 0 }
    }
}

/// Native revision-2 SND. Audio uses planar, normalized PCM at 44,100 Hz.
/// Header bytes without an established meaning survive a read/edit/write cycle.
public struct MPCSound {
    public var name: String
    public var channels: [[Float]]
    public var start: Int
    public var end: Int
    public var volume: Int
    public var tune: Int
    public var header: Data
    /// Additional source bytes after the declared PCM; exports use canonical PCM only.
    public private(set) var trailingByteCount: Int = 0
    public var frameCount: Int { channels.first?.count ?? 0 }
    public static let maximumFileBytes = 32 * 1024 * 1024

    public init(name: String, channels: [[Float]], start: Int = 0, end: Int? = nil,
                volume: Int = 100, tune: Int = 0) {
        self.name = name
        self.channels = channels
        self.start = start
        self.end = end ?? (channels.first?.count ?? 0)
        self.volume = volume
        self.tune = tune
        self.header = Data(repeating: 0, count: 38)
    }

    /// Shared with exporters: use the returned name when checking collisions.
    public static func safeName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        let trimmed = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        let ascii = trimmed.unicodeScalars.prefix(16).map { scalar -> UInt8 in
            let v = scalar.value
            return (v >= 32 && v <= 126 && v != 47 && v != 92 && v != 58) ? UInt8(v) : 95
        }
        let result = String(bytes: ascii, encoding: .ascii) ?? ""
        return result.isEmpty || result == "." || result == ".." ? "UNTITLED" : result
    }

    public static func decode(_ data: Data, name: String? = nil) throws -> MPCSound {
        guard data.count <= maximumFileBytes else { throw MPCFormatError.tooLarge }
        guard data.count >= 38 else { throw MPCFormatError.invalid("en-tête SND tronqué.") }
        let b = Array(data)
        guard b[0] == 1 else { throw MPCFormatError.unsupported("ce fichier n'est pas un SND natif.") }
        if b[1] == 0x82 { throw MPCFormatError.unsupported("SND compressé 12 bits (révision 82).") }
        guard b[1] == 2 else { throw MPCFormatError.unsupported("seule la révision SND 02 est prise en charge.") }
        guard b[21] <= 1 else { throw MPCFormatError.invalid("indicateur mono/stéréo incorrect.") }
        let count = Int(MPCBytes.u32(b, 30))
        let channelCount = Int(b[21]) + 1
        guard count > 0 else { throw MPCFormatError.invalid("longueur audio nulle.") }
        guard count <= (maximumFileBytes - 38) / (2 * channelCount) else { throw MPCFormatError.tooLarge }
        guard data.count >= 38 + count * 2 * channelCount else {
            throw MPCFormatError.invalid("la longueur PCM ne correspond pas à l'en-tête.")
        }
        let start = Int(MPCBytes.u32(b, 22)), end = Int(MPCBytes.u32(b, 26))
        guard start <= end && end <= count else { throw MPCFormatError.invalid("marqueurs début/fin hors du son.") }
        var channels = [[Float]]()
        for channel in 0..<channelCount {
            var samples = [Float]()
            samples.reserveCapacity(count)
            for frame in 0..<count {
                let p = 38 + 2 * (channel * count + frame)
                let bits = UInt16(b[p]) | UInt16(b[p + 1]) << 8
                samples.append(Float(Int16(bitPattern: bits)) / 32768)
            }
            channels.append(samples)
        }
        var sound = MPCSound(name: name ?? MPCBytes.text(b, at: 2, count: 16),
                             channels: channels, start: start, end: end,
                             volume: Int(b[19]), tune: Int(Int8(bitPattern: b[20])))
        sound.header = Data(b.prefix(38))
        sound.trailingByteCount = data.count - (38 + count * 2 * channelCount)
        return sound
    }

    public func encoded(name overrideName: String? = nil) throws -> Data {
        guard channels.count == 1 || channels.count == 2 else { throw MPCFormatError.invalid("un ou deux canaux sont nécessaires.") }
        let count = frameCount
        guard channels.allSatisfy({ $0.count == count }) else { throw MPCFormatError.invalid("longueurs de canaux différentes.") }
        guard count >= 441 else { throw MPCFormatError.invalid("un son doit contenir au moins 441 échantillons (10 ms).") }
        guard count <= (Self.maximumFileBytes - 38) / (2 * channels.count) else { throw MPCFormatError.tooLarge }
        guard start >= 0 && start <= end && end <= count else { throw MPCFormatError.invalid("marqueurs début/fin hors du son.") }
        guard channels.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw MPCFormatError.invalid("l'audio contient une valeur non finie.")
        }
        var b = header.count == 38 ? Array(header) : [UInt8](repeating: 0, count: 38)
        b[0] = 1; b[1] = 2
        MPCBytes.putName(overrideName ?? name, into: &b, at: 2, terminated: false)
        b[19] = UInt8(clamping: volume)
        b[20] = UInt8(bitPattern: Int8(clamping: tune))
        b[21] = UInt8(channels.count - 1)
        MPCBytes.put32(UInt32(start), into: &b, at: 22)
        MPCBytes.put32(UInt32(end), into: &b, at: 26)
        MPCBytes.put32(UInt32(count), into: &b, at: 30)
        MPCBytes.put32(0, into: &b, at: 34) // Runtime RAM pointer is ignored by the native reader.
        b.reserveCapacity(38 + count * 2 * channels.count)
        for channel in channels {
            for sample in channel {
                let scaled = (Double(max(-1, min(1, sample))) * 32768).rounded()
                let value = Int16(clamping: Int(scaled))
                let bits = UInt16(bitPattern: value)
                b.append(UInt8(truncatingIfNeeded: bits))
                b.append(UInt8(truncatingIfNeeded: bits >> 8))
            }
        }
        return Data(b)
    }

    private func cleaned() -> MPCSound {
        var copy = self
        let count = channels.map(\.count).min() ?? 0
        copy.channels = channels.map { $0.prefix(count).map { $0.isFinite ? $0 : 0 } }
        copy.start = max(0, min(count, start))
        copy.end = max(copy.start, min(count, end))
        return copy
    }

    public func trimmed() -> MPCSound {
        var copy = cleaned()
        copy.channels = copy.channels.map { Array($0[copy.start..<copy.end]) }
        copy.end -= copy.start
        copy.start = 0
        return copy
    }

    public func normalized() -> MPCSound {
        var copy = cleaned()
        let peak = copy.channels.reduce(Float(0)) { peak, channel in
            channel.reduce(peak) { max($0, abs($1)) }
        }
        if peak > 0 {
            copy.channels = copy.channels.map { $0.map { Float(Double($0) / Double(peak)) } }
        }
        return copy
    }

    public func mono() -> MPCSound {
        var copy = cleaned()
        guard !copy.channels.isEmpty else { return copy }
        if copy.channels.count > 1 {
            let original = copy.channels
            copy.channels = [(0..<copy.frameCount).map { frame in
                Float(original.reduce(0.0) { $0 + Double($1[frame]) } / Double(original.count))
            }]
        }
        return copy
    }

    public func faded(milliseconds: Double) -> MPCSound {
        var copy = cleaned()
        let count = copy.end - copy.start
        guard milliseconds.isFinite && milliseconds > 0 && count > 1 else { return copy }
        let frames = Int(min(Double(count / 2), max(1, milliseconds * 44.1)))
        let denominator = Float(max(1, frames - 1))
        for channel in copy.channels.indices {
            for i in 0..<frames {
                let gain = Float(i) / denominator
                copy.channels[channel][copy.start + i] *= gain
                copy.channels[channel][copy.end - 1 - i] *= gain
            }
        }
        return copy
    }
}

/// One native PGM; unknown bytes are retained verbatim when editing known fields.
public struct MPCProgram {
    public var bytes: Data
    private static let image = 2690
    private static let assignments = image + 62
    private static let padMap = image + 1854

    public init(data: Data) throws {
        guard data.count == 4608 else { throw MPCFormatError.invalid("un PGM natif doit mesurer 4 608 octets.") }
        guard data[data.startIndex] == 7 && data[data.startIndex + 1] == 0 else {
            throw MPCFormatError.unsupported("signature PGM native 07 00 attendue.")
        }
        bytes = Data(Array(data))
    }

    /// Start from a reference MPC3000 program rather than guessing mixer/global defaults.
    /// The bundled template retains its pad map and known machine settings.
    public static func blank(name: String) -> MPCProgram {
        guard let url = templateURL,
              let data = try? Data(contentsOf: url),
              var program = try? MPCProgram(data: data) else {
            preconditionFailure("Le programme modèle Default.pgm manque dans le paquet MPCCore.")
        }
        var b = Array(program.bytes)
        for i in 2..<2690 { b[i] = 0 } // Empty 128-name inventory and memory-word table.
        for note in 0..<64 {
            let p = assignments + note * 24
            b[p] = 0xFF
            b[p + 1] = 0 // NORMAL: dormant alternate-note settings cannot activate layers.
        }
        MPCBytes.putName(name, into: &b, at: image, terminated: true)
        program.bytes = Data(b)
        return program
    }

    private static var templateURL: URL? {
        // Support a manually packaged .app as well as swift run/test.
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("KitStudio_MPCCore.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("KitStudio_MPCCore.bundle")
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: candidate),
               let url = bundle.url(forResource: "Default", withExtension: "pgm") { return url }
        }
        return Bundle.module.url(forResource: "Default", withExtension: "pgm")
    }

    private func position(_ note: Int) -> Int? {
        guard bytes.count == 4608 && (35...98).contains(note) else { return nil }
        return Self.assignments + (note - 35) * 24
    }

    public var name: String {
        get {
            guard bytes.count == 4608 else { return "" }
            return MPCBytes.text(Array(bytes), at: Self.image, count: 17)
        }
        set {
            guard bytes.count == 4608 else { return }
            var b = Array(bytes)
            MPCBytes.putName(newValue, into: &b, at: Self.image, terminated: true)
            bytes = Data(b)
        }
    }

    public func midiNote(forPad pad: Int) -> Int {
        guard bytes.count == 4608 && (0..<64).contains(pad) else { return 35 }
        return Int(Array(bytes)[Self.padMap + pad])
    }
    public func slot(forNote note: Int) -> Int? {
        guard let p = position(note) else { return nil }
        let slot = Int(Array(bytes)[p])
        return slot < 128 ? slot : nil
    }
    public mutating func assign(slot: Int?, toNote note: Int) {
        guard let p = position(note), slot == nil || (0..<128).contains(slot!) else { return }
        var b = Array(bytes)
        b[p] = slot.map(UInt8.init) ?? 0xFF
        bytes = Data(b)
    }
    public func soundName(slot: Int) -> String {
        guard bytes.count == 4608 && (0..<128).contains(slot) else { return "" }
        return MPCBytes.text(Array(bytes), at: 2 + slot * 17, count: 17)
    }
    public mutating func setSound(slot: Int, name: String, wordCount: Int) {
        guard bytes.count == 4608 && (0..<128).contains(slot) else { return }
        var b = Array(bytes)
        let p = 2 + slot * 17
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for i in 0..<17 { b[p + i] = 0 }
            MPCBytes.put32(0, into: &b, at: 2178 + slot * 4)
        } else {
            MPCBytes.putName(name, into: &b, at: p, terminated: true)
            MPCBytes.put32(UInt32(clamping: wordCount), into: &b, at: 2178 + slot * 4)
        }
        bytes = Data(b)
    }
    public func tune(forNote note: Int) -> Int {
        guard let p = position(note) else { return 0 }
        let b = Array(bytes)
        return Int(Int16(bitPattern: UInt16(b[p + 9]) | UInt16(b[p + 10]) << 8))
    }
    public mutating func setTune(_ value: Int, forNote note: Int) {
        guard let p = position(note) else { return }
        var b = Array(bytes)
        let bits = UInt16(bitPattern: Int16(clamping: value))
        b[p + 9] = UInt8(truncatingIfNeeded: bits)
        b[p + 10] = UInt8(truncatingIfNeeded: bits >> 8)
        bytes = Data(b)
    }
    public var referencedSlots: Set<Int> { Set((35...98).compactMap { slot(forNote: $0) }) }
    public var soundNames: [String] { (0..<128).map { soundName(slot: $0) } }
}
