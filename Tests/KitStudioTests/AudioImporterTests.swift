import AVFoundation
import Foundation
import MPCCore
import Testing
@testable import KitStudio

struct AudioCase: Sendable, CustomTestStringConvertible {
    let fileExtension: String
    let sampleRate: Double
    let channels: Int

    var testDescription: String { "\(fileExtension) \(Int(sampleRate)) Hz \(channels) channel(s)" }

    static let all: [AudioCase] = ["wav", "aiff"].flatMap { ext in
        [44_100.0, 48_000, 96_000].flatMap { rate in
            [1, 2].map { AudioCase(fileExtension: ext, sampleRate: rate, channels: $0) }
        }
    }
}

private final class AudioFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KitStudioAudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func audio(_ format: AudioCase, frames: Int? = nil, floatingPoint: Bool = false,
               sample: (Int, Int) -> Float = { frame, channel in
                   Float(0.5 * sin(2 * .pi * Double(channel == 0 ? 440 : 997) * Double(frame) / 44_100))
               }) throws -> URL {
        let count = frames ?? Int(format.sampleRate / 10)
        let url = directory.appendingPathComponent("SAMPLE.\(format.fileExtension)")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channels,
            AVLinearPCMBitDepthKey: floatingPoint ? 32 : 16,
            AVLinearPCMIsFloatKey: floatingPoint,
            AVLinearPCMIsBigEndianKey: format.fileExtension == "aiff",
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = try AVAudioFile(forWriting: url, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let pcmFormat = output.processingFormat
        try #require(pcmFormat.channelCount == format.channels)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                                 frameCapacity: AVAudioFrameCount(max(1, count))))
        buffer.frameLength = AVAudioFrameCount(count)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<format.channels {
            for frame in 0..<count { data[channel][frame] = sample(frame, channel) }
        }
        try output.write(from: buffer)
        return url
    }
}

struct AudioImporterTests {
    @Test("WAV/AIFF resampling preserves duration and channel content", arguments: AudioCase.all)
    func convertsKnownSignals(_ format: AudioCase) throws {
        let fixture = try AudioFixture()
        let url = try fixture.audio(format) { frame, channel in
            Float(0.5 * sin(2 * .pi * Double(channel == 0 ? 440 : 997) * Double(frame) / format.sampleRate))
        }
        let sound = try AudioImporter.load(url)
        #expect(sound.channels.count == format.channels)
        #expect(abs(sound.frameCount - 4410) <= 1)
        #expect(sound.start == 0)
        #expect(sound.end == sound.frameCount)
        #expect(sound.name == "SAMPLE")
        for channel in sound.channels.indices {
            let samples = sound.channels[channel]
            try #require(samples.count > 128)
            let count = samples.count - 128
            let error = (64..<(samples.count - 64)).reduce(0.0) { total, frame in
                let expected = 0.5 * sin(2 * .pi * Double(channel == 0 ? 440 : 997) * Double(frame) / 44_100)
                return total + pow(Double(samples[frame]) - expected, 2)
            }
            #expect(sqrt(error / Double(count)) < 0.001)
        }
        // A successful import must be exportable by the same app.
        let native = try MPCSound.decode(sound.encoded())
        #expect(native.frameCount == sound.frameCount)
        #expect(native.channels.count == sound.channels.count)
    }

    @Test("Samples shorter than the native export minimum are rejected", arguments: AudioCase.all)
    func rejectsShortAudio(_ format: AudioCase) throws {
        let fixture = try AudioFixture()
        let url = try fixture.audio(format, frames: Int(format.sampleRate / 200))
        do {
            _ = try AudioImporter.load(url)
            Issue.record("A 5 ms sample was accepted although native export requires 10 ms.")
        } catch let error as StudioError {
            #expect(error.localizedDescription.contains("441"))
            #expect(error.localizedDescription.contains("10 ms"))
        }
    }

    @Test("The 10 ms native minimum remains importable", arguments: AudioCase.all)
    func acceptsMinimumAudio(_ format: AudioCase) throws {
        let fixture = try AudioFixture()
        let url = try fixture.audio(format, frames: Int(format.sampleRate / 100))
        let sound = try AudioImporter.load(url)
        #expect(sound.frameCount == 441)
        #expect(try sound.encoded().count == 38 + 441 * format.channels * 2)
    }

    @Test("Audio with non-finite PCM is rejected before preview")
    func rejectsNonFiniteAudio() throws {
        let fixture = try AudioFixture()
        let url = try fixture.audio(AudioCase(fileExtension: "wav", sampleRate: 44_100, channels: 1),
                                    floatingPoint: true) { frame, _ in frame == 100 ? .nan : 0.25 }
        do {
            _ = try AudioImporter.load(url)
            Issue.record("Non-finite PCM was accepted for playback.")
        } catch let error as StudioError {
            #expect(error.localizedDescription.contains("non finie"))
        }
    }

    @Test("Remaining PCM budget is checked for mono and stereo audio", arguments: [1, 2])
    func respectsAudioBudget(_ channels: Int) throws {
        let fixture = try AudioFixture()
        let url = try fixture.audio(AudioCase(fileExtension: "wav", sampleRate: 48_000, channels: channels))
        let pcmBytes = 4410 * channels * 2
        let sound = try AudioImporter.load(url, maximumPCMBytes: pcmBytes)
        #expect(sound.frameCount * sound.channels.count * 2 == pcmBytes)
        do {
            _ = try AudioImporter.load(url, maximumPCMBytes: pcmBytes - 1)
            Issue.record("An import exceeding its remaining PCM budget was accepted.")
        } catch let error as StudioError {
            #expect(error.localizedDescription.contains("disponible"))
        }
    }

    @Test("SND header budget is checked before decoding its body")
    func nativeBudgetIsPreflighted() throws {
        let fixture = try AudioFixture()
        let source = MPCSound(name: "NATIVE", channels: [[Float](repeating: 0.25, count: 441)])
        let url = fixture.directory.appendingPathComponent("NATIVE.SND")
        let data = try source.encoded()
        try data.write(to: url)
        let sound = try AudioImporter.load(url, maximumPCMBytes: 882)
        #expect(sound.channels == source.channels)
        #expect(sound.name == "NATIVE")
        // Deliberately omit PCM. A budget error proves that the header is inspected first.
        try data.prefix(38).write(to: url)
        do {
            _ = try AudioImporter.load(url, maximumPCMBytes: 881)
            Issue.record("The SND header exceeded the budget without an error.")
        } catch let error as StudioError {
            #expect(error.localizedDescription.contains("disponible"))
        }
        #expect(throws: MPCFormatError.self) { try AudioImporter.load(url) }
    }

    @Test("Short SND files are rejected before preview")
    func rejectsShortNativeAudio() throws {
        let fixture = try AudioFixture()
        var bytes = Array(try MPCSound(name: "SHORT", channels: [[Float](repeating: 0, count: 441)]).encoded())
        for offset in [26, 30] {
            bytes[offset] = 220
            for i in 1..<4 { bytes[offset + i] = 0 }
        }
        let url = fixture.directory.appendingPathComponent("SHORT.SND")
        try Data(bytes.prefix(38 + 220 * 2)).write(to: url)
        do {
            _ = try AudioImporter.load(url)
            Issue.record("A 220-frame SND was accepted although it cannot be exported.")
        } catch let error as StudioError {
            #expect(error.localizedDescription.contains("441"))
        }
    }

    @Test("Oversized SND files are refused before a full read")
    func rejectsOversizedNativeFile() throws {
        let fixture = try AudioFixture()
        let url = fixture.directory.appendingPathComponent("OVERSIZE.SND")
        try MPCSound(name: "LARGE", channels: [[Float](repeating: 0, count: 441)]).encoded().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(MPCSound.maximumFileBytes + 1))
        try file.close()
        do {
            _ = try AudioImporter.load(url)
            Issue.record("An oversized SND source was accepted.")
        } catch MPCFormatError.tooLarge {
            // Expected before loading the PCM body.
        }
    }

    @Test("Non-audio and multichannel sources are rejected")
    func rejectsInvalidSources() throws {
        let fixture = try AudioFixture()
        let invalid = fixture.directory.appendingPathComponent("INVALID.wav")
        try Data("not audio".utf8).write(to: invalid)
        #expect(throws: NSError.self) { try AudioImporter.load(invalid) }
        let surround = try fixture.audio(AudioCase(fileExtension: "wav", sampleRate: 44_100, channels: 3))
        do {
            _ = try AudioImporter.load(surround)
            Issue.record("A three-channel source was accepted.")
        } catch let error as StudioError {
            #expect(error.localizedDescription.contains("mono ou stéréo"))
        }
    }

    @MainActor
    @Test("Preview renders both channels and respects stop without hardware I/O")
    func previewEngineRendersOffline() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let audio = StudioAudio(engine: engine)
        defer { engine.stop() }
        let sound = MPCSound(name: "STEREO", channels: [[Float](repeating: 0.25, count: 4410),
                                                       [Float](repeating: -0.5, count: 4410)],
                             start: 100, end: 2100, volume: 50)
        try audio.play(sound)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024))
        var peaks: [Float] = [0, 0]
        var energies = [0.0, 0.0]
        for _ in 0..<12 {
            let status = try engine.renderOffline(1024, to: buffer)
            try #require(status == .success)
            let data = try #require(buffer.floatChannelData)
            for channel in 0..<2 {
                for frame in 0..<Int(buffer.frameLength) {
                    peaks[channel] = max(peaks[channel], abs(data[channel][frame]))
                    energies[channel] += Double(data[channel][frame]) * Double(data[channel][frame])
                }
            }
        }
        // The varispeed resampler rings briefly at the rectangular signal's edges.
        #expect(peaks[0] > 0.12 && peaks[0] < 0.14)
        #expect(peaks[1] > 0.24 && peaks[1] < 0.28)
        #expect(abs(energies[0] - 2000 * 0.125 * 0.125) < 1)
        #expect(abs(energies[1] / energies[0] - 4) < 0.01)
        try audio.play(MPCSound(name: "LONG", channels: [[Float](repeating: 0.5, count: 44_100)]))
        _ = try engine.renderOffline(1024, to: buffer)
        audio.stop()
        // Permit the varispeed unit's short tail to drain before asserting silence.
        for _ in 0..<4 { _ = try engine.renderOffline(1024, to: buffer) }
        let stopped = try #require(buffer.floatChannelData)
        #expect((0..<Int(buffer.frameLength)).allSatisfy { stopped[0][$0] == 0 && stopped[1][$0] == 0 })
    }

    @MainActor
    @Test("Preview combines SND and pad tuning in tenths of a semitone")
    func previewTuningRendersOffline() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let audio = StudioAudio(engine: engine)
        defer { engine.stop() }
        let radiansPerFrame = 2.0 * Double.pi * 440.0 / 44_100.0
        let input: [Float] = (0..<44_100).map { Float(0.5 * sin(radiansPerFrame * Double($0))) }
        try audio.play(MPCSound(name: "A440", channels: [input], tune: 60), tune: 60)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024))
        var output: [Float] = []
        for _ in 0..<16 {
            let status = try engine.renderOffline(1024, to: buffer)
            try #require(status == .success)
            let data = try #require(buffer.floatChannelData)
            output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        let range = 4096..<12_288
        let crossings = range.dropFirst().filter { output[$0 - 1] <= 0 && output[$0] > 0 }.count
        let frequency = Double(crossings) * 44_100 / Double(range.count)
        // A one-crossing uncertainty corresponds to 5.4 Hz in this analysis window.
        #expect(abs(frequency - 880) < 6)
    }
}
