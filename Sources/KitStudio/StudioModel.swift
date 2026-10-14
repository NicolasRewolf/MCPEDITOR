import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MPCCore

@MainActor
final class StudioModel: ObservableObject {
    @Published var locations: [URL] = []
    @Published var programs: [URL] = []
    @Published var selectedLocation: URL?
    @Published var programURL: URL?
    @Published var kitName = "NEWKIT"
    @Published var bank = 0
    @Published var selectedPad = 0
    @Published var isDirty = false
    @Published var busy = false
    @Published var status = "Choisis une partition ou ouvre un dossier de kits."
    @Published var errorMessage: String?
    @Published var sound: MPCSound?
    @Published var program: MPCProgram?

    private var sounds: [Int: MPCSound] = [:]
    private let audio = StudioAudio()
    private var generation = 0
    private var missing: [String] = []

    var memoryBytes: Int {
        guard let program else { return 0 }
        return program.referencedSlots.reduce(0) { result, slot in
            guard let sample = sounds[slot] else { return result }
            return result + sample.frameCount * sample.channels.count * 2
        }
    }

    var selectedLabel: String {
        String(format: "%@%02d", String(UnicodeScalar(65 + selectedPad / 16)!), selectedPad % 16 + 1)
    }

    var padTune: Int {
        guard let program else { return 0 }
        return program.tune(forNote: program.midiNote(forPad: selectedPad))
    }

    func refreshLocations() {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                           options: [.skipHiddenVolumes]) ?? []
        let external = mounted.filter {
            guard let values = try? $0.resourceValues(forKeys: keys) else { return false }
            return values.volumeIsInternal == false || values.volumeIsRemovable == true || values.volumeIsEjectable == true
        }
        locations = Array(Set(locations + external)).filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if let selectedLocation { scan(selectedLocation) }
    }

    func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Ouvrir une partition ou un dossier de kits"
        panel.prompt = "Ouvrir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !locations.contains(url) { locations.append(url) }
        selectLocation(url)
    }

    func selectLocation(_ url: URL) {
        guard !busy, confirmDiscard() else { return }
        generation += 1
        audio.stop()
        selectedLocation = url
        programURL = nil
        program = nil
        sound = nil
        sounds = [:]
        isDirty = false
        scan(url)
        status = "\(programs.count) programme(s) dans \(url.lastPathComponent)."
    }

    private func scan(_ url: URL) {
        do {
            programs = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]).filter {
                    $0.pathExtension.lowercased() == "pgm" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch { errorMessage = "Impossible de lire ce dossier : \(error.localizedDescription)" }
    }

    func openProgram(_ url: URL) {
        guard !busy, confirmDiscard() else { return }
        generation += 1
        let token = generation
        busy = true
        audio.stop()
        status = "Ouverture de \(url.lastPathComponent)…"
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try Self.loadKit(url)
                }.value
                guard token == self.generation else { return }
                self.program = loaded.0
                self.sounds = loaded.1
                self.missing = loaded.2
                self.programURL = url
                self.kitName = url.deletingPathExtension().lastPathComponent
                self.isDirty = false
                self.busy = false
                self.selectPad(0)
                self.bank = 0
                let trailing = loaded.1.values.reduce(0) { $0 + $1.trailingByteCount }
                self.status = loaded.2.isEmpty ? (trailing > 0 ?
                    "Kit ouvert. \(trailing) octets hors PCM seront omis lors du nouvel export." :
                    "Kit ouvert. Les originaux sont conservés jusqu’à un nouvel export.") :
                    "Sons indisponibles : \(loaded.2.joined(separator: ", ")). L’export exige tous les sons du kit."
            } catch {
                guard token == self.generation else { return }
                self.busy = false
                self.errorMessage = error.localizedDescription
                self.status = "Ouverture interrompue."
            }
        }
    }

    nonisolated private static func loadKit(_ url: URL) throws -> (MPCProgram, [Int: MPCSound], [String]) {
        let program = try MPCProgram(data: Data(contentsOf: url))
        let folder = url.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles])
        var assets: [Int: MPCSound] = [:]
        var missing: [String] = []
        var total = 0
        for slot in program.referencedSlots.sorted() {
            let name = program.soundName(slot: slot)
            let matches = files.filter {
                $0.pathExtension.lowercased() == "snd" &&
                $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
            }
            guard matches.count == 1, let file = matches.first else {
                missing.append(name.isEmpty ? "slot \(slot + 1)" : name)
                continue
            }
            do {
                let sample = try MPCSound.decode(Data(contentsOf: file), name: name)
                total += sample.frameCount * sample.channels.count * 2
                guard total <= 33_554_432 else { throw StudioError.message("Le kit dépasse 32 Mo de mémoire PCM.") }
                assets[slot] = sample
            } catch let error as StudioError { throw error }
              catch { missing.append("\(name) (\(error.localizedDescription))") }
        }
        return (program, assets, missing)
    }

    func newKit() {
        guard !busy, confirmDiscard() else { return }
        generation += 1
        audio.stop()
        program = MPCProgram.blank(name: "NEWKIT")
        sounds = [:]
        missing = []
        kitName = "NEWKIT"
        programURL = nil
        bank = 0
        selectedPad = 0
        sound = nil
        isDirty = false
        status = "Nouveau kit. Importe des WAV, AIFF ou SND sur les pads."
    }

    func selectPad(_ index: Int) {
        guard (0..<64).contains(index) else { return }
        selectedPad = index
        bank = index / 16
        updateSound()
    }

    func padName(_ index: Int) -> String {
        guard let program else { return "—" }
        let note = program.midiNote(forPad: index)
        guard let slot = program.slot(forNote: note) else { return "—" }
        return sounds[slot]?.name ?? program.soundName(slot: slot)
    }

    func padIsMissing(_ index: Int) -> Bool {
        guard let program, let slot = program.slot(forNote: program.midiNote(forPad: index)) else { return false }
        return sounds[slot] == nil
    }

    func playPad(_ index: Int) {
        selectPad(index)
        guard let sound, let program else { return }
        do { try audio.play(sound, tune: program.tune(forNote: program.midiNote(forPad: index))) }
        catch { errorMessage = "Écoute impossible : \(error.localizedDescription)" }
    }

    func stop() { audio.stop() }

    func importAudio() {
        guard !busy else { return }
        if program == nil { newKit() }
        let panel = NSOpenPanel()
        panel.title = "Importer des samples sur les pads"
        panel.prompt = "Importer"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, UTType(filenameExtension: "snd") ?? .data]
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls, atPad: selectedPad)
    }

    func dropFiles(_ providers: [NSItemProvider], onPad: Int) -> Bool {
        guard !busy else { return false }
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else { return false }
        let token = generation
        Task {
            var urls: [URL] = []
            for provider in accepted {
                let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let data = item as? Data {
                            continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                        } else if let url = item as? URL {
                            continuation.resume(returning: url)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let url { urls.append(url) }
            }
            guard token == self.generation else { return }
            self.importURLs(urls, atPad: onPad)
        }
        return true
    }

    private func importURLs(_ urls: [URL], atPad: Int) {
        guard !busy, !urls.isEmpty else { return }
        if program == nil { newKit() }
        let token = generation
        busy = true
        status = "Conversion audio vers 44,1 kHz…"
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try urls.prefix(64 - atPad).map { try AudioImporter.load($0) }
                }.value
                guard token == self.generation, var updated = self.program else { return }
                var pool = self.sounds
                for (offset, sample) in loaded.enumerated() {
                    let note = updated.midiNote(forPad: atPad + offset)
                    var available = Set(0..<128).subtracting(updated.referencedSlots)
                    if let old = updated.slot(forNote: note) {
                        let uses = (35...98).filter { updated.slot(forNote: $0) == old }.count
                        if uses == 1 { available.insert(old) }
                    }
                    guard let slot = available.sorted().first else { throw StudioError.message("Le programme utilise déjà 128 sons.") }
                    pool[slot] = sample
                    updated.setSound(slot: slot, name: sample.name, wordCount: sample.frameCount * sample.channels.count)
                    updated.assign(slot: slot, toNote: note)
                }
                let bytes = updated.referencedSlots.reduce(0) { sum, slot in
                    sum + (pool[slot].map { $0.frameCount * $0.channels.count * 2 } ?? 0)
                }
                guard bytes <= 33_554_432 else { throw StudioError.message("L’import ferait dépasser 32 Mo de mémoire PCM.") }
                pool = pool.filter { updated.referencedSlots.contains($0.key) }
                self.program = updated
                self.sounds = pool
                self.busy = false
                self.isDirty = true
                self.selectPad(atPad)
                self.status = "\(loaded.count) sample(s) importé(s)."
            } catch {
                self.busy = false
                self.errorMessage = error.localizedDescription
                self.status = "Import interrompu ; le kit est conservé."
            }
        }
    }

    func setTrim(start: Int, end: Int) {
        guard !busy, var sample = sound else { return }
        let lo = min(max(0, start), max(0, sample.frameCount - 1))
        sample.start = lo
        sample.end = min(sample.frameCount, max(lo + 1, end))
        replaceSelected(sample)
    }

    func transform(_ kind: String) {
        guard !busy, let sound else { return }
        switch kind {
        case "trim":
            guard sound.end - sound.start >= 441 else {
                errorMessage = "La découpe doit conserver au moins 441 points (10 ms)."
                return
            }
            replaceSelected(sound.trimmed())
        case "normalize": replaceSelected(sound.normalized())
        case "mono": replaceSelected(sound.mono())
        case "fade": replaceSelected(sound.faded(milliseconds: 3))
        case "reverse":
            var copy = sound
            copy.channels = sound.channels.map { Array($0.reversed()) }
            copy.start = sound.frameCount - sound.end
            copy.end = sound.frameCount - sound.start
            replaceSelected(copy)
        default: return
        }
        status = "Sample modifié en mémoire ; exporte le kit pour le conserver."
    }

    func setPadTune(_ value: Int) {
        guard !busy, var updated = program else { return }
        updated.setTune(min(120, max(-120, value)), forNote: updated.midiNote(forPad: selectedPad))
        program = updated
        isDirty = true
    }

    private func replaceSelected(_ sample: MPCSound) {
        guard let program, let slot = program.slot(forNote: program.midiNote(forPad: selectedPad)) else { return }
        sounds[slot] = sample
        sound = sample
        isDirty = true
    }

    private func updateSound() {
        guard let program, let slot = program.slot(forNote: program.midiNote(forPad: selectedPad)) else {
            sound = nil
            return
        }
        sound = sounds[slot]
    }

    func exportKit() {
        guard !busy, var program else { return }
        let panel = NSOpenPanel()
        panel.title = "Exporter un nouveau kit dans une partition"
        panel.prompt = "Exporter ici"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = selectedLocation ?? programURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        program.name = kitName
        let exportProgram = program
        let pool = sounds
        let name = kitName
        busy = true
        status = "Export du programme et des samples…"
        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try KitExport.export(program: exportProgram, sounds: pool, name: name, to: destination)
                }.value
                self.busy = false
                self.isDirty = false
                self.status = "Export terminé : \(output.lastPathComponent). Éjecte la carte depuis le Finder après utilisation."
                if self.selectedLocation == destination { self.scan(destination) }
            } catch {
                self.busy = false
                self.errorMessage = error.localizedDescription
                self.status = "L’export n’a pas abouti."
            }
        }
    }

    func clearPad() {
        guard !busy, var updated = program else { return }
        let note = updated.midiNote(forPad: selectedPad)
        let oldSlot = updated.slot(forNote: note)
        updated.assign(slot: nil, toNote: note)
        if let oldSlot, !updated.referencedSlots.contains(oldSlot) {
            sounds.removeValue(forKey: oldSlot)
            updated.setSound(slot: oldSlot, name: "", wordCount: 0)
        }
        program = updated
        sound = nil
        isDirty = true
    }

    func confirmClose() -> Bool {
        guard !busy else { NSSound.beep(); return false }
        return confirmDiscard()
    }

    private func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Des modifications n’ont pas été exportées."
        alert.informativeText = "Continuer abandonnera les modifications en mémoire. Les fichiers d’origine restent disponibles."
        alert.addButton(withTitle: "Continuer")
        alert.addButton(withTitle: "Annuler")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
