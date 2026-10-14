import Foundation
import AVFoundation
import MPCCore

enum AudioImporter {
    static func load(_ url: URL) throws -> MPCSound {
        if url.pathExtension.lowercased() == "snd" {
            return try MPCSound.decode(Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
        }
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let channels = Int(source.channelCount)
        guard channels == 1 || channels == 2, source.sampleRate > 0 else {
            throw StudioError.message("Choisis un fichier audio mono ou stéréo.")
        }
        let expected = ceil(Double(file.length) * 44100 / source.sampleRate)
        guard file.length > 0, file.length <= 33_554_432,
              expected > 0, expected * Double(channels) * 2 <= 33_554_432 else {
            throw StudioError.message("Ce sample dépasse les 32 Mo de mémoire PCM.")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
                                         channels: source.channelCount, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(expected) + 64),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw StudioError.message("Impossible de préparer la conversion audio.")
        }
        try file.read(into: input)
        var supplied = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard result != .error, output.frameLength > 0, let pcm = output.floatChannelData else {
            throw StudioError.message("La conversion de ce fichier audio a échoué.")
        }
        let data = (0..<channels).map { Array(UnsafeBufferPointer(start: pcm[$0], count: Int(output.frameLength))) }
        return MPCSound(name: url.deletingPathExtension().lastPathComponent, channels: data)
    }
}

@MainActor
final class StudioAudio {
    private let engine = AVAudioEngine()
    private var voices: [(AVAudioPlayerNode, AVAudioUnitVarispeed)] = []
    private var next = 0

    init() {
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

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
