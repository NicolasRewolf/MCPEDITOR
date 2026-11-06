import Foundation
import AVFoundation
import MPCCore

enum AudioImporter {
    static func load(_ url: URL, maximumPCMBytes: Int = 33_554_432) throws -> MPCSound {
        if url.pathExtension.lowercased() == "snd" {
            return try loadNativeSound(url, maximumPCMBytes: maximumPCMBytes)
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let source = file.processingFormat
        let channels = Int(source.channelCount)
        guard channels == 1 || channels == 2, source.sampleRate.isFinite, source.sampleRate > 0 else {
            throw StudioError.message(String(localized: "Choisis un fichier audio mono ou stéréo."))
        }
        let expected = ceil(Double(file.length) * 44100 / source.sampleRate)
        try validatePCM(frameCount: expected, channels: channels, maximumPCMBytes: maximumPCMBytes)
        // Bound the source buffer as well as the converted PCM, before allocating either.
        guard file.length <= 33_554_432 else {
            throw StudioError.message(String(localized: "Ce fichier contient trop d’échantillons audio pour cet import."))
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
                                         channels: source.channelCount, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(expected) + 64),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw StudioError.message(String(localized: "Impossible de préparer la conversion audio."))
        }
        try file.read(into: input)
        guard input.frameLength == file.length, let inputPCM = input.floatChannelData else {
            throw StudioError.message(String(localized: "La lecture de ce fichier audio est incomplète."))
        }
        guard (0..<channels).allSatisfy({ channel in
            UnsafeBufferPointer(start: inputPCM[channel], count: Int(input.frameLength)).allSatisfy(\.isFinite)
        }) else {
            throw StudioError.message(String(localized: "Ce fichier contient une valeur audio non finie (NaN ou infini)."))
        }
        let conversionInput = AudioConversionInput(input)
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            conversionInput.next(status)
        }
        if let conversionError { throw conversionError }
        guard result != .error, output.frameLength > 0, let pcm = output.floatChannelData else {
            throw StudioError.message(String(localized: "La conversion de ce fichier audio a échoué."))
        }
        try validatePCM(frameCount: Double(output.frameLength), channels: channels, maximumPCMBytes: maximumPCMBytes)
        guard (0..<channels).allSatisfy({ channel in
            UnsafeBufferPointer(start: pcm[channel], count: Int(output.frameLength)).allSatisfy(\.isFinite)
        }) else {
            throw StudioError.message(String(localized: "La conversion contient une valeur audio non finie (NaN ou infini)."))
        }
        let data = (0..<channels).map { Array(UnsafeBufferPointer(start: pcm[$0], count: Int(output.frameLength))) }
        return MPCSound(name: url.deletingPathExtension().lastPathComponent, channels: data)
    }

    private static func validatePCM(frameCount: Double, channels: Int, maximumPCMBytes: Int) throws {
        guard frameCount.isFinite, frameCount >= 441 else {
            throw StudioError.message(String(localized: "Ce sample doit contenir au moins 441 échantillons (10 ms à 44,1 kHz) pour la MPC."))
        }
        // The native 32 MiB file limit includes the 38-byte SND header.
        guard frameCount <= Double((MPCSound.maximumFileBytes - MPCSoundHeader.byteCount) / (channels * 2)) else {
            throw StudioError.message(String(localized: "Ce sample dépasse la taille maximale d’un fichier SND de 32 Mio."))
        }
        guard maximumPCMBytes >= 0,
              frameCount <= Double(maximumPCMBytes / (channels * 2)) else {
            let available = ByteCountFormatter.string(fromByteCount: Int64(max(0, maximumPCMBytes)), countStyle: .memory)
            throw StudioError.message(String(localized: "Ce sample dépasse la mémoire PCM disponible pour cet import (\(available))."))
        }
    }

    private static func loadNativeSound(_ url: URL, maximumPCMBytes: Int) throws -> MPCSound {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = MPCSoundHeader(try file.read(upToCount: MPCSoundHeader.byteCount) ?? Data())
        let declared = try header.declaration()
        // Import policy intentionally precedes file/body validation: short sounds
        // and exhausted budgets are rejected before any PCM read or allocation.
        try validatePCM(frameCount: Double(declared.frameCount), channels: declared.channelCount,
                        maximumPCMBytes: maximumPCMBytes)
        let fileBytes = try file.seekToEnd()
        guard fileBytes <= MPCSound.maximumFileBytes else { throw MPCFormatError.tooLarge }
        try file.seek(toOffset: 0)
        // A growing or oversized source is never read without a bound.
        let data = try file.read(upToCount: MPCSound.maximumFileBytes + 1) ?? Data()
        guard data.count == fileBytes, data.prefix(MPCSoundHeader.byteCount) == header.bytes else {
            throw StudioError.message(String(localized: "Ce fichier SND a changé pendant l’import. Réessaie avec un fichier stable."))
        }
        return try MPCSound.decode(data, name: url.deletingPathExtension().lastPathComponent)
    }
}

/// Narrow bridge for AVAudioConverterInputBlock's SDK Sendable contract. The
/// buffer is fully populated and validated before ownership enters this wrapper;
/// neither the loader nor this wrapper mutates it afterwards. The single-feed
/// state is locked, and the buffer is retained for the whole conversion as the
/// AVAudioConverterInputBlock documentation requires. No global AVFoundation
/// Sendable conformance or preconcurrency suppression is introduced.
private final class AudioConversionInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var supplied = false

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else { status.pointee = .endOfStream; return nil }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

@MainActor
final class StudioAudio {
    private let engine: AVAudioEngine
    private var voices: [(AVAudioPlayerNode, AVAudioUnitVarispeed)] = []
    private var next = 0

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        for _ in 0..<8 {
            let player = AVAudioPlayerNode()
            let speed = AVAudioUnitVarispeed()
            engine.attach(player)
            engine.attach(speed)
            engine.connect(player, to: speed, format: format)
            engine.connect(speed, to: engine.mainMixerNode, format: format)
            voices.append((player, speed))
        }
        engine.prepare()
    }

    func play(_ sound: MPCSound, tune: Int = 0) throws {
        let lo = max(0, min(sound.start, sound.frameCount))
        let hi = max(lo, min(sound.end, sound.frameCount))
        guard hi > lo, !sound.channels.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hi - lo)),
              let pcm = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(hi - lo)
        for channel in 0..<2 {
            let samples = sound.channels[min(channel, sound.channels.count - 1)]
            for i in 0..<(hi - lo) { pcm[channel][i] = samples[lo + i] }
        }
        let (player, speed) = voices[next]
        next = (next + 1) % voices.count
        player.stop()
        speed.rate = Float(min(4, max(0.25, pow(2, Double(sound.tune + tune) / 120))))
        player.volume = min(2, max(0, Float(sound.volume) / 100))
        if !engine.isRunning { try engine.start() }
        player.scheduleBuffer(buffer)
        player.play()
    }

    func stop() { for (player, _) in voices { player.stop() } }
}

enum StudioError: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
