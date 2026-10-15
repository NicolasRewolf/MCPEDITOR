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
        missing = []
        errorMessage = nil
        if scan(url) {
            status = "\(programs.count) programme(s) dans \(url.lastPathComponent)."
        }
    }

    @discardableResult
    func scan(_ url: URL) -> Bool {
        do {
            programs = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]).filter {
                    $0.pathExtension.lowercased() == "pgm" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            errorMessage = nil
            return true
        } catch {
            programs = []
            errorMessage = "Impossible de lire ce dossier : \(error.localizedDescription)"
            status = "Le dossier est indisponible."
            return false
        }
    }

    func openProgram(_ url: URL) {
        guard !busy, confirmDiscard() else { return }
        generation += 1
        let token = generation
        busy = true
        errorMessage = nil
        audio.stop()
        status = "Ouverture de \(url.lastPathComponent)…"
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try KitLoader.load(programURL: url)
                }.value
                guard token == self.generation else { return }
                self.program = loaded.program
                self.sounds = loaded.sounds
                self.missing = loaded.missing
                self.programURL = url
                self.kitName = url.deletingPathExtension().lastPathComponent
                self.isDirty = false
                self.busy = false
                self.selectPad(0)
                self.bank = 0
                let trailing = loaded.sounds.values.reduce(0) { $0 + $1.trailingByteCount }
                self.status = loaded.missing.isEmpty ? (trailing > 0 ?
                    "Kit ouvert. \(trailing) octets hors PCM seront omis lors du nouvel export." :
                    "Kit ouvert. L’export crée de nouveaux fichiers et conserve les originaux.") :
                    "Sons indisponibles : \(loaded.missing.joined(separator: ", ")). L’export exige tous les sons du kit."
            } catch {
                guard token == self.generation else { return }
                self.busy = false
                self.errorMessage = error.localizedDescription
                self.status = "Ouverture interrompue."
            }
        }
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
        errorMessage = nil
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
        // Reserve the entire operation before provider resolution can suspend.
        busy = true
        errorMessage = nil
        status = "Lecture des fichiers déposés…"
        Task {
            do {
                var urls: [URL] = []
                for (index, provider) in accepted.enumerated() {
                    let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                            let prefix = "Impossible de lire le fichier déposé \(index + 1)."
                            if let error {
                                continuation.resume(throwing: StudioError.message("\(prefix) \(error.localizedDescription)"))
                                return
                            }
                            let url: URL?
                            if let data = item as? Data {
                                url = URL(dataRepresentation: data, relativeTo: nil)
                            } else {
                                url = item as? URL
                            }
                            guard let url, url.isFileURL else {
                                continuation.resume(throwing: StudioError.message(prefix))
                                return
                            }
                            continuation.resume(returning: url)
                        }
                    }
                    urls.append(url)
                }
                guard token == self.generation else { return }
                await self.importResolvedURLs(urls, atPad: onPad, token: token)
            } catch {
                guard token == self.generation else { return }
                self.busy = false
                self.errorMessage = error.localizedDescription
                self.status = "Import interrompu ; le kit est conservé."
            }
        }
        return true
    }

    struct PreparedImport {
        let program: MPCProgram
        let sounds: [Int: MPCSound]
        let importedCount: Int
    }

    /// Prepare the complete batch on copies; the model commits it only after every file succeeds.
    /// The injected loader makes the per-file memory allowance independently testable.
    nonisolated static func prepareImport(
        _ urls: [URL], atPad: Int, program: MPCProgram, sounds: [Int: MPCSound],
        maximumPCMBytes: Int = 33_554_432,
        loadAudio: (URL, Int) throws -> MPCSound = { try AudioImporter.load($0, maximumPCMBytes: $1) }
    ) throws -> PreparedImport {
        guard (0..<64).contains(atPad) else {
            throw StudioError.message("Le pad de départ est invalide.")
        }
        guard urls.count <= 64 - atPad else {
            throw StudioError.message("L’import contient \(urls.count) samples, mais seuls \(64 - atPad) pads restent jusqu’à D16. Choisis moins de fichiers ou un pad de départ plus tôt.")
        }
        let targetNotes = urls.indices.map { program.midiNote(forPad: atPad + $0) }
        guard targetNotes.allSatisfy({ (35...98).contains($0) }) else {
            throw StudioError.message("Le programme contient une affectation de pad invalide.")
        }
        guard Set(targetNotes).count == targetNotes.count else {
            throw StudioError.message("Deux pads de ce lot partagent la même note MIDI. Importe ces samples séparément ou modifie l’affectation des pads.")
        }
        var updated = program
        let initialReferences = program.referencedSlots
        var pool = sounds.filter { initialReferences.contains($0.key) }
        for (offset, url) in urls.enumerated() {
            let note = targetNotes[offset]
            let referenced = updated.referencedSlots
            let old = updated.slot(forNote: note)
            let replacesExclusive = old.map { slot in
                (35...98).filter { updated.slot(forNote: $0) == slot }.count == 1
            } ?? false
            var available = Set(0..<128).subtracting(referenced)
            if replacesExclusive, let old { available.insert(old) }
            guard let slot = available.min() else {
                throw StudioError.message("Le programme utilise déjà 128 sons.")
            }
            let retainedBytes = referenced.reduce(0) { sum, existing in
                if replacesExclusive && existing == old { return sum }
                guard let sample = pool[existing] else { return sum }
                return sum + sample.frameCount * sample.channels.count * 2
            }
            let remaining = maximumPCMBytes - retainedBytes
            guard remaining > 0 else {
                throw StudioError.message("L’import ferait dépasser 32 Mo de mémoire PCM.")
            }
            let sample = try loadAudio(url, remaining)
            let sampleBytes = sample.frameCount * sample.channels.count * 2
            guard sampleBytes <= remaining else {
                throw StudioError.message("L’import ferait dépasser 32 Mo de mémoire PCM.")
            }
            pool[slot] = sample
            updated.setSound(slot: slot, name: sample.name, wordCount: sample.frameCount * sample.channels.count)
            updated.assign(slot: slot, toNote: note)
            let currentReferences = updated.referencedSlots
            pool = pool.filter { currentReferences.contains($0.key) }
        }
        return PreparedImport(program: updated, sounds: pool, importedCount: urls.count)
    }

    @discardableResult
    func importURLs(_ urls: [URL], atPad: Int) -> Task<Void, Never>? {
        guard !busy, !urls.isEmpty else { return nil }
        let token = generation
        busy = true
        errorMessage = nil
        status = "Conversion audio vers 44,1 kHz…"
        return Task { await self.importResolvedURLs(urls, atPad: atPad, token: token) }
    }

    /// Both entry points hold `busy` until provider resolution and conversion finish.
    private func importResolvedURLs(_ urls: [URL], atPad: Int, token: Int) async {
        let startingProgram = program ?? MPCProgram.blank(name: kitName)
        let startingSounds = sounds
        status = "Conversion audio vers 44,1 kHz…"
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepareImport(urls, atPad: atPad, program: startingProgram, sounds: startingSounds)
            }.value
            guard token == self.generation else { return }
            self.program = prepared.program
            self.sounds = prepared.sounds
            self.busy = false
            self.isDirty = true
            self.selectPad(atPad)
            self.status = "\(prepared.importedCount) sample(s) importé(s)."
        } catch {
            guard token == self.generation else { return }
            self.busy = false
            self.errorMessage = error.localizedDescription
            self.status = "Import interrompu ; le kit est conservé."
        }
    }

    func setKitName(_ value: String) {
        guard !busy, value != kitName else { return }
        kitName = value
        isDirty = true
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
