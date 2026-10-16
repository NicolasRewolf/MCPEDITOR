import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MPCCore

enum LibraryMode: String, CaseIterable, Sendable {
    case kits = "Kits"
    case samples = "Samples"
}

struct SoundRangeWarning: Identifiable, Sendable {
    let slot: Int
    let name: String
    let report: PCM16RangeReport
    var id: Int { slot }
}

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
    @Published private(set) var resolvingDroppedFiles = false
    @Published var status = "Choisis une partition ou ouvre un dossier de kits."
    @Published var errorMessage: String?
    @Published var sound: MPCSound?
    @Published var program: MPCProgram?
    @Published private(set) var audioRangeReports: [Int: PCM16RangeReport] = [:]

    @Published var libraryMode: LibraryMode = .kits
    @Published var partitions: [LibraryPartition] = []
    @Published var libraryKits: [LibraryKit] = []
    @Published var libraryScanning = false
    @Published var kitSearch = ""
    @Published var libraryIssue: String?
    @Published var sampleRoots: [URL] = []
    @Published var selectedSampleRoot: URL?
    @Published var sampleFolder: URL?
    @Published var sampleListing = LibraryFolderListing(folders: [], samples: [], issue: nil)
    @Published var selectedSampleURL: URL?
    @Published var sampleQuery = ""
    @Published var samplePreviewBusy = false
    @Published var samplePreviewStatus = "Sélectionne un sample pour l’écouter ou l’affecter à un pad."
    @Published var lastExportURL: URL?
    @Published private(set) var awaitingDiscardConfirmation = false
    @Published private(set) var filePanelPresented = false
    @Published private(set) var awaitingKitTrashConfirmation = false
    @Published var showExportSheet = false
    @Published var exportDestinationURL: URL?
    @Published private(set) var exportDestinationReceipt: ExportDestination?

    private var kitFolders: [URL] = []
    private var libraryGeneration = 0
    private var sampleBrowseGeneration = 0
    private var samplePreviewGeneration = 0
    private var volumeObservation: WorkspaceMountObservation?
    private var volumeRefreshTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    private var refreshPending = false
    typealias DiscardPresenter = (@escaping (Bool) -> Void) -> Void
    typealias TrashPresenter = (KitTrash.Prepared, @escaping (Bool) -> Void) -> Void
    private let discardPresenter: DiscardPresenter?
    private let trashPresenter: TrashPresenter?
    private let trashOperation: KitTrash.Operation
    private let preferences: UserDefaults
    private let volumeProvider: () -> [URL]
    private let sampleFolderLoader: @Sendable (URL) -> LibraryFolderListing
    private var sounds: [Int: MPCSound] = [:]
    private let audio = StudioAudio()
    private var generation = 0
    private var missing: [String] = []
    private var dropTask: Task<Void, Never>?
    private var dropResolution: ItemProviderResolution?

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

    /// The program title is independent of the DOS filename allocated for a copy.
    var programTitle: String { program?.name ?? kitName }

    var exportAudioWarnings: [SoundRangeWarning] {
        guard let program else { return [] }
        return program.referencedSlots.sorted().compactMap { slot in
            guard let report = audioRangeReports[slot],
                  report.outOfRangeSampleCount > 0 || report.nonFiniteSampleCount > 0 else { return nil }
            return SoundRangeWarning(slot: slot, name: sounds[slot]?.name ?? program.soundName(slot: slot), report: report)
        }
    }

    var selectedAudioRangeWarning: SoundRangeWarning? {
        guard let program, let slot = program.slot(forNote: program.midiNote(forPad: selectedPad)) else { return nil }
        return exportAudioWarnings.first { $0.slot == slot }
    }

    var exportAudioIssue: String? {
        let warnings = exportAudioWarnings
        guard !warnings.isEmpty else { return nil }
        let peak = warnings.map(\.report.peakMagnitude).max() ?? 0
        return "\(warnings.count) sample(s) dépassent le niveau maximal du PCM 16 bits (crête \(String(format: "%.2f", peak))). L’export écrêterait leur son. Normalise volontairement les samples concernés, ou remplace-les. La préécoute utilise le Float de travail."
    }

    /// The user explicitly chooses the gain change; imports and exports never
    /// silently normalize or clamp the in-memory Float samples.
    func normalizeOverrangeSamples() {
        guard !documentLocked else { return }
        let affected = exportAudioWarnings
        guard !affected.isEmpty else { return }
        for warning in affected {
            guard let sample = sounds[warning.slot], warning.report.nonFiniteSampleCount == 0 else { continue }
            let normalized = sample.normalized()
            sounds[warning.slot] = normalized
            audioRangeReports[warning.slot] = normalized.pcm16RangeReport
        }
        updateSound()
        isDirty = true
        status = "Samples hors plage normalisés en mémoire à ta demande ; les sources sont conservées."
    }

    init(defaults: UserDefaults = .standard,
         discardPresenter: DiscardPresenter? = nil,
         trashPresenter: TrashPresenter? = nil,
         trashOperation: @escaping KitTrash.Operation = { try KitTrash.systemTrash($0) },
         volumeProvider: @escaping () -> [URL] = {
             FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                  options: [.skipHiddenVolumes]) ?? []
         },
         sampleFolderLoader: @escaping @Sendable (URL) -> LibraryFolderListing = { LibraryIndex.listSamples(in: $0) }) {
        preferences = defaults
        self.discardPresenter = discardPresenter
        self.trashPresenter = trashPresenter
        self.trashOperation = trashOperation
        self.volumeProvider = volumeProvider
        self.sampleFolderLoader = sampleFolderLoader
        kitFolders = (defaults.stringArray(forKey: "library.kitFolders") ?? []).map { URL(fileURLWithPath: $0) }
        sampleRoots = (defaults.stringArray(forKey: "library.sampleRoots") ?? []).map { URL(fileURLWithPath: $0) }
        volumeObservation = WorkspaceMountObservation(center: NSWorkspace.shared.notificationCenter,
            names: [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification]) { [weak self] _ in
            Task { @MainActor in self?.scheduleVolumeRefresh() }
        }
    }

    deinit {
        volumeRefreshTask?.cancel()
        dropTask?.cancel()
        dropResolution?.cancel()
    }

    var documentLocked: Bool { busy || awaitingDiscardConfirmation || filePanelPresented || awaitingKitTrashConfirmation }
    var documentActionsDisabled: Bool { documentLocked || showExportSheet }

    var filteredKits: [LibraryKit] {
        libraryKits.filter { kit in
            (selectedLocation == nil || kit.rootURL == selectedLocation?.standardizedFileURL) &&
            (kitSearch.isEmpty || kit.title.localizedStandardContains(kitSearch) ||
             kit.locationLabel.localizedStandardContains(kitSearch))
        }
    }

    var filteredSampleFolders: [URL] {
        sampleListing.folders.filter { sampleQuery.isEmpty || $0.lastPathComponent.localizedStandardContains(sampleQuery) }
    }

    var filteredSamples: [URL] {
        sampleListing.samples.filter { sampleQuery.isEmpty || $0.lastPathComponent.localizedStandardContains(sampleQuery) }
    }

    var assignedPadCount: Int {
        guard let program else { return 0 }
        return (0..<64).filter { program.slot(forNote: program.midiNote(forPad: $0)) != nil }.count
    }

    var estimatedExportBytes: Int64 {
        Int64(memoryBytes + (program?.referencedSlots.count ?? 0) * 38 + 4608)
    }

    private var exportFileSizes: [Int] {
        guard let program else { return [4608] }
        return program.referencedSlots.sorted().compactMap { sounds[$0] }.map { $0.frameCount * $0.channels.count * 2 + 38 } + [4608]
    }

    var requiredExportFreeBytes: Int64 {
        let conservativeFAT = ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: 0)
        return (try? ExportSpace.estimate(fileSizes: exportFileSizes, volume: conservativeFAT).requiredBytes) ?? Int64.max
    }

    func requiredExportFreeBytes(in partition: LibraryPartition) -> Int64 {
        let space = partition.volumeSpace ?? ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: partition.availableBytes ?? 0)
        return (try? ExportSpace.estimate(fileSizes: exportFileSizes, volume: space).requiredBytes) ?? Int64.max
    }

    nonisolated static func locationLabel(for url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents
        if let part = components.first(where: { LibraryIndex.partitionLetter(for: URL(fileURLWithPath: "/" + $0)) != nil }) {
            return "PART " + String(part.suffix(1))
        }
        return url.deletingLastPathComponent().lastPathComponent
    }

    var kitLocationLabel: String {
        if let url = lastExportURL {
            return "\(isDirty ? "Modifié depuis l’export" : "Exporté") · \(Self.locationLabel(for: url)) · \(url.lastPathComponent)"
        }
        if let url = programURL {
            return "\(isDirty ? "Modifié en mémoire" : "Ouvert") · \(Self.locationLabel(for: url)) · \(url.lastPathComponent)"
        }
        return "Kit en mémoire · non enregistré"
    }

    var kitLocationPath: String { (lastExportURL ?? programURL)?.path ?? "" }
    var selectedDestinationLabel: String {
        guard let destination = exportDestinationURL else { return "Choisir une destination" }
        return LibraryIndex.partitionLetter(for: destination).map { "PART \($0)" } ?? destination.lastPathComponent
    }

    var exportDestinationIssue: String? {
        guard let destination = exportDestinationURL else { return nil }
        if let part = partitions.first(where: { $0.url == destination.standardizedFileURL }), !part.issues.isEmpty {
            return "Cette PART doit être vérifiée avant l’enregistrement. Actualise la bibliothèque."
        }
        guard exportDestinationReceipt?.url.standardizedFileURL == destination.standardizedFileURL else {
            return "Choisis à nouveau la destination pour vérifier son emplacement."
        }
        return nil
    }

    func revealKitLocation() {
        if let url = lastExportURL ?? programURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// A kit is a program. Its samples and sequences remain independent on disk.
    @discardableResult
    func requestTrashKit(_ kit: LibraryKit) -> Task<Void, Never>? {
        guard !documentActionsDisabled else { return nil }
        awaitingKitTrashConfirmation = true
        stop()
        errorMessage = nil
        return Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try KitTrash.prepare(kit.url)
                }.value
                let confirmation: (Bool) -> Void = { [weak self] approved in
                    guard let self, self.awaitingKitTrashConfirmation else { return }
                    if approved { self.moveConfirmedKitToTrash(prepared) }
                    else { self.awaitingKitTrashConfirmation = false }
                }
                if let trashPresenter = self.trashPresenter {
                    trashPresenter(prepared, confirmation)
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Mettre \(prepared.url.lastPathComponent) à la corbeille ?"
                alert.informativeText = "Ce kit est le programme .PGM situé ici :\n\(prepared.url.path)\n\nLes samples .SND et les séquences .SEQ restent sur le disque. Cette action libère très peu d’espace. Le kit ouvert reste en mémoire ; tu peux l’enregistrer à nouveau."
                alert.addButton(withTitle: "Mettre à la corbeille")
                alert.addButton(withTitle: "Annuler")
                alert.buttons.first?.hasDestructiveAction = true
                let finish: (NSApplication.ModalResponse) -> Void = { response in
                    confirmation(response == .alertFirstButtonReturn)
                }
                if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
                    alert.beginSheetModal(for: window, completionHandler: finish)
                } else { finish(alert.runModal()) }
            } catch {
                self.awaitingKitTrashConfirmation = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func moveConfirmedKitToTrash(_ prepared: KitTrash.Prepared) {
        busy = true
        awaitingKitTrashConfirmation = false
        let operation = trashOperation
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try KitTrash.move(prepared, operation: operation)
                }.value
                let deletedURL = prepared.url.standardizedFileURL
                let wasCurrent = (self.lastExportURL ?? self.programURL)?.standardizedFileURL == deletedURL
                if self.programURL?.standardizedFileURL == deletedURL { self.programURL = nil }
                if self.lastExportURL?.standardizedFileURL == deletedURL { self.lastExportURL = nil }
                if wasCurrent { self.isDirty = true }
                self.libraryKits.removeAll { $0.url == deletedURL }
                self.programs.removeAll { $0.standardizedFileURL == deletedURL }
                self.busy = false
                self.status = "\(deletedURL.lastPathComponent) mis à la corbeille. Les samples et les séquences sont conservés."
                self.refreshLocations()
            } catch {
                self.busy = false
                self.errorMessage = error.localizedDescription
                self.status = "La mise à la corbeille n’a pas abouti ; le kit en mémoire est conservé."
            }
        }
    }

    private func scheduleVolumeRefresh() {
        volumeRefreshTask?.cancel()
        volumeRefreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) }
            catch { return }
            self?.refreshLocations()
        }
    }

    @discardableResult
    func refreshLocations() -> Task<Void, Never> {
        if let libraryTask {
            refreshPending = true
            return libraryTask
        }
        libraryGeneration += 1
        let token = libraryGeneration
        let mounted = Set(volumeProvider().map(\.standardizedFileURL))
        // Retain known PARTs after disconnection, with an explicit unavailable scan.
        let partURLs = Array(Set(mounted.filter { LibraryIndex.partitionLetter(for: $0) != nil }).union(partitions.map(\.url)))
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let folders = kitFolders
        libraryScanning = true
        let task = Task {
            let result = await Task.detached(priority: .utility) {
                let parts = partURLs.map { url in
                    guard mounted.contains(url) else {
                        return LibraryPartition(url: url, letter: LibraryIndex.partitionLetter(for: url) ?? url.lastPathComponent,
                                                kits: [], fileCount: 0, folderCount: 0, audioCount: 0,
                                                sequenceCount: 0, issues: ["Cette PART n’est plus montée. Rebranche la SD puis actualise."],
                                                availableBytes: nil)
                    }
                    return LibraryIndex.scanPartition(url)
                }
                var kits = parts.flatMap(\.kits)
                var issues = parts.flatMap(\.issues)
                for folder in folders {
                    if let part = partURLs.first(where: { folder.pathComponents.starts(with: $0.pathComponents) }),
                       !mounted.contains(part) { continue }
                    do { kits += try LibraryIndex.scanKits(in: folder) }
                    catch { issues.append(error.localizedDescription) }
                }
                kits = Array(Dictionary(kits.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first }).values)
                    .sorted { $0.title == $1.title ? $0.url.path < $1.url.path :
                        $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return (parts, kits, issues)
            }.value
            guard token == self.libraryGeneration else { return }
            self.partitions = result.0
            self.libraryKits = result.1
            self.locations = partURLs + folders
            self.programs = self.filteredKits.map(\.url)
            self.libraryIssue = result.2.isEmpty ? nil : result.2.joined(separator: "\n")
            self.libraryScanning = false
            self.libraryTask = nil
            if let folder = self.sampleFolder { self.browseSamplesFolder(folder) }
            if self.refreshPending {
                self.refreshPending = false
                self.refreshLocations()
            }
        }
        libraryTask = task
        return task
    }

    func chooseFolder() {
        guard !documentLocked else { return }
        let panel = NSOpenPanel()
        panel.title = "Ajouter un dossier de kits"
        panel.prompt = "Ajouter"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        presentFilePanel(panel) { [weak self] response in
            guard response == .OK, let self, let url = panel.url?.standardizedFileURL else { return }
            if !self.kitFolders.contains(url) { self.kitFolders.append(url) }
            self.preferences.set(self.kitFolders.map(\.path), forKey: "library.kitFolders")
            self.selectLocation(url)
            self.refreshLocations()
        }
    }

    /// Browsing is independent from the in-memory document, including while it is dirty.
    func selectLocation(_ url: URL) {
        selectedLocation = url.standardizedFileURL
        programs = filteredKits.map(\.url)
        selectSampleRoot(url)
    }

    func showAllKits() {
        selectedLocation = nil
        programs = filteredKits.map(\.url)
    }

    func chooseSampleFolder() {
        guard !documentLocked else { return }
        let panel = NSOpenPanel()
        panel.title = "Ajouter une source de samples"
        panel.prompt = "Ajouter"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        presentFilePanel(panel) { [weak self] response in
            guard response == .OK, let self, let url = panel.url?.standardizedFileURL else { return }
            if !self.sampleRoots.contains(url) { self.sampleRoots.append(url) }
            self.preferences.set(self.sampleRoots.map(\.path), forKey: "library.sampleRoots")
            self.selectSampleRoot(url)
        }
    }

    func selectSampleRoot(_ url: URL) {
        selectedSampleRoot = url.standardizedFileURL
        sampleQuery = ""
        browseSamplesFolder(url)
    }

    @discardableResult
    func browseSamplesFolder(_ url: URL) -> Task<Void, Never>? {
        guard let root = selectedSampleRoot?.standardizedFileURL else { return nil }
        let folder = url.standardizedFileURL
        if let part = partitions.first(where: { folder.pathComponents.starts(with: $0.url.pathComponents) }),
           !Set(volumeProvider().map(\.standardizedFileURL)).contains(part.url) {
            sampleBrowseGeneration += 1
            stop()
            sampleFolder = folder
            selectedSampleURL = nil
            sampleListing = LibraryFolderListing(folders: [], samples: [], issue: "Cette PART n’est plus montée. Rebranche la SD puis actualise.")
            samplePreviewStatus = "PART indisponible."
            return nil
        }
        guard folder.pathComponents.starts(with: root.pathComponents),
              folder.resolvingSymlinksInPath().pathComponents.starts(with: root.resolvingSymlinksInPath().pathComponents) else { return nil }
        sampleBrowseGeneration += 1
        stop()
        let token = sampleBrowseGeneration
        sampleFolder = folder
        selectedSampleURL = nil
        samplePreviewBusy = false
        sampleQuery = ""
        sampleListing = LibraryFolderListing(folders: [], samples: [], issue: nil)
        samplePreviewStatus = "Lecture du dossier…"
        let loader = sampleFolderLoader
        return Task {
            let listing = await Task.detached(priority: .utility) { loader(folder) }.value
            guard token == self.sampleBrowseGeneration else { return }
            self.sampleListing = listing
            self.samplePreviewStatus = listing.issue == nil ? "\(listing.samples.count) samples dans ce dossier." : "Dossier indisponible. Rebranche le disque puis actualise."
        }
    }

    func sampleGoUp() {
        guard let folder = sampleFolder, folder != selectedSampleRoot else { return }
        browseSamplesFolder(folder.deletingLastPathComponent())
    }

    func selectSample(_ url: URL) {
        if selectedSampleURL != url { stop() }
        selectedSampleURL = url
        samplePreviewStatus = "Prêt à écouter · \(url.lastPathComponent)"
    }

    func previewSample(_ url: URL) {
        guard !documentActionsDisabled, !samplePreviewBusy else { return }
        selectedSampleURL = url
        samplePreviewGeneration += 1
        let token = samplePreviewGeneration
        samplePreviewBusy = true
        samplePreviewStatus = "Préparation de \(url.lastPathComponent)…"
        Task {
            do {
                let sample = try await Task.detached(priority: .userInitiated) { try AudioImporter.load(url) }.value
                guard token == self.samplePreviewGeneration else { return }
                self.audio.stop()
                try self.audio.play(sample)
                self.samplePreviewBusy = false
                self.samplePreviewStatus = "Écoute · \(url.lastPathComponent)"
            } catch {
                guard token == self.samplePreviewGeneration else { return }
                self.samplePreviewBusy = false
                self.samplePreviewStatus = "Écoute impossible : \(error.localizedDescription)"
            }
        }
    }

    func assignSample(_ url: URL) {
        guard !documentActionsDisabled else { return }
        samplePreviewGeneration += 1
        samplePreviewBusy = false
        audio.stop()
        importURLs([url], atPad: selectedPad)
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
        guard !documentActionsDisabled else { return }
        requestDiscard { [weak self] approved in
            if approved { self?.beginOpenProgram(url) }
        }
    }

    private func beginOpenProgram(_ url: URL) {
        guard !documentActionsDisabled else { return }
        generation += 1
        let token = generation
        busy = true
        errorMessage = nil
        stop()
        status = "Ouverture de \(url.lastPathComponent)…"
        Task {
            do {
                let (loaded, reports) = try await Task.detached(priority: .userInitiated) {
                    let loaded = try KitLoader.load(programURL: url)
                    return (loaded, loaded.sounds.mapValues(\.pcm16RangeReport))
                }.value
                guard token == self.generation else { return }
                self.program = loaded.program
                self.sounds = loaded.sounds
                self.audioRangeReports = reports
                self.missing = loaded.missing
                self.programURL = url
                self.lastExportURL = nil
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
        guard !documentActionsDisabled else { return }
        requestDiscard { [weak self] approved in
            if approved { self?.makeNewKit() }
        }
    }

    private func makeNewKit() {
        guard !documentActionsDisabled else { return }
        generation += 1
        stop()
        program = MPCProgram.blank(name: "NEWKIT")
        sounds = [:]
        audioRangeReports = [:]
        missing = []
        kitName = "NEWKIT"
        programURL = nil
        lastExportURL = nil
        bank = 0
        selectedPad = 0
        sound = nil
        isDirty = false
        errorMessage = nil
        status = "Nouveau kit. Importe des WAV, AIFF ou SND sur les pads."
    }

    func selectPad(_ index: Int) {
        guard !documentActionsDisabled, (0..<64).contains(index) else { return }
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
        guard !documentActionsDisabled else { return }
        selectPad(index)
        guard let sound, let program else { return }
        do { try audio.play(sound, tune: program.tune(forNote: program.midiNote(forPad: index))) }
        catch { errorMessage = "Écoute impossible : \(error.localizedDescription)" }
    }

    func stop() {
        samplePreviewGeneration += 1
        if samplePreviewBusy || samplePreviewStatus.hasPrefix("Écoute ·") { samplePreviewStatus = "Écoute arrêtée." }
        samplePreviewBusy = false
        audio.stop()
    }

    func importAudio() {
        guard !documentActionsDisabled else { return }
        let panel = NSOpenPanel()
        panel.title = "Importer des samples sur les pads"
        panel.prompt = "Importer"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, UTType(filenameExtension: "snd") ?? .data]
        let pad = selectedPad
        let token = generation
        presentFilePanel(panel) { [weak self] response in
            guard response == .OK, let self, token == self.generation else { return }
            self.importURLs(panel.urls, atPad: pad)
        }
    }

    func dropFiles(_ providers: [NSItemProvider], onPad: Int) -> Bool {
        guard !documentActionsDisabled else { return false }
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else { return false }
        let token = generation
        stop()
        // Reserve the entire operation before provider resolution can suspend.
        busy = true
        resolvingDroppedFiles = true
        errorMessage = nil
        status = "Lecture des fichiers déposés…"
        dropTask = Task {
            do {
                var urls: [URL] = []
                for (index, provider) in accepted.enumerated() {
                    try Task.checkCancellation()
                    let resolution = ItemProviderResolution()
                    self.dropResolution = resolution
                    let url = try await resolution.resolve(provider, index: index)
                    guard token == self.generation else { return }
                    self.dropResolution = nil
                    urls.append(url)
                }
                guard token == self.generation else { return }
                self.resolvingDroppedFiles = false
                await self.importResolvedURLs(urls, atPad: onPad, token: token)
                self.dropTask = nil
            } catch {
                guard token == self.generation else { return }
                self.dropResolution = nil
                self.dropTask = nil
                self.resolvingDroppedFiles = false
                self.busy = false
                self.errorMessage = error is CancellationError ? nil : error.localizedDescription
                self.status = "Import interrompu ; le kit est conservé."
            }
        }
        return true
    }

    /// Only the provider phase is cancellable; once decoding starts, the bounded
    /// batch finishes atomically. No source or document is changed by cancellation.
    func cancelDroppedFiles() {
        guard resolvingDroppedFiles else { return }
        generation += 1
        dropTask?.cancel()
        dropResolution?.cancel()
        dropTask = nil
        dropResolution = nil
        resolvingDroppedFiles = false
        busy = false
        errorMessage = nil
        status = "Dépôt annulé ; le kit et ses modifications sont conservés."
    }

    struct PreparedImport: Sendable {
        let program: MPCProgram
        let sounds: [Int: MPCSound]
        let importedCount: Int
        let rangeReports: [Int: PCM16RangeReport]
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
        return PreparedImport(program: updated, sounds: pool, importedCount: urls.count,
                              rangeReports: pool.mapValues(\.pcm16RangeReport))
    }

    @discardableResult
    func importURLs(_ urls: [URL], atPad: Int) -> Task<Void, Never>? {
        guard !documentActionsDisabled, !urls.isEmpty else { return nil }
        let token = generation
        stop()
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
            self.audioRangeReports = prepared.rangeReports
            self.busy = false
            self.isDirty = true
            self.selectPad(atPad)
            self.status = self.exportAudioIssue ?? "\(prepared.importedCount) sample(s) importé(s)."
        } catch {
            guard token == self.generation else { return }
            self.busy = false
            self.errorMessage = error.localizedDescription
            self.status = "Import interrompu ; le kit est conservé."
        }
    }

    func setKitName(_ value: String) {
        guard !documentLocked, value != kitName else { return }
        kitName = value
        program?.name = value
        isDirty = true
    }

    func setSoundName(_ name: String) {
        guard !documentActionsDisabled, var sample = sound, sample.name != name, var updated = program,
              let slot = updated.slot(forNote: updated.midiNote(forPad: selectedPad)) else { return }
        sample.name = name
        updated.setSound(slot: slot, name: name, wordCount: sample.frameCount * sample.channels.count)
        program = updated
        replaceSelected(sample, updateRangeReport: false)
    }

    func setTrim(start: Int, end: Int) {
        guard !documentActionsDisabled, var sample = sound else { return }
        let lo = min(max(0, start), max(0, sample.frameCount - 1))
        sample.start = lo
        sample.end = min(sample.frameCount, max(lo + 1, end))
        replaceSelected(sample, updateRangeReport: false)
    }

    func transform(_ kind: String) {
        guard !documentActionsDisabled, let sound else { return }
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
        guard !documentActionsDisabled, var updated = program else { return }
        updated.setTune(min(120, max(-120, value)), forNote: updated.midiNote(forPad: selectedPad))
        program = updated
        isDirty = true
    }

    private func replaceSelected(_ sample: MPCSound, updateRangeReport: Bool = true) {
        guard let program, let slot = program.slot(forNote: program.midiNote(forPad: selectedPad)) else { return }
        sounds[slot] = sample
        if updateRangeReport { audioRangeReports[slot] = sample.pcm16RangeReport }
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

    var recommendedSDPartition: LibraryPartition? {
        partitions.first {
            $0.isEmpty && $0.exportDestination?.isMountedMPCPartition == true &&
            ($0.availableBytes ?? -1) >= requiredExportFreeBytes(in: $0)
        }
    }

    func exportKit() {
        guard !documentActionsDisabled, program != nil else { return }
        let recommended = recommendedSDPartition
        exportDestinationURL = recommended?.url
        exportDestinationReceipt = recommended?.exportDestination?.requiringEmpty()
        showExportSheet = true
    }

    func selectExportPartition(_ partition: LibraryPartition) {
        guard !documentLocked, partition.issues.isEmpty,
              let receipt = partition.exportDestination, receipt.isMountedMPCPartition else { return }
        exportDestinationURL = partition.url
        exportDestinationReceipt = partition.isEmpty ? receipt.requiringEmpty() : receipt
    }

    func selectExportFolder(_ url: URL) {
        guard !documentLocked else { return }
        do {
            let receipt = try ExportDestination.capture(at: url)
            exportDestinationURL = url.standardizedFileURL
            exportDestinationReceipt = receipt
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseExportFolder() {
        guard !documentLocked else { return }
        let panel = NSOpenPanel()
        panel.title = "Choisir le dossier d’export"
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = exportDestinationURL
        presentFilePanel(panel) { [weak self] response in
            if response == .OK, let url = panel.url { self?.selectExportFolder(url) }
        }
    }

    func exportKitToDestination() {
        guard !documentLocked, let destination = exportDestinationURL,
              let receipt = exportDestinationReceipt, exportDestinationIssue == nil else { return }
        showExportSheet = false
        exportKit(to: destination, expectedDestination: receipt)
    }

    @discardableResult
    func exportKit(to destination: URL, expectedDestination: ExportDestination? = nil) -> Task<Void, Never>? {
        guard !documentActionsDisabled, let program else { return nil }
        if let issue = exportAudioIssue {
            errorMessage = issue
            status = "L’export attend ta décision sur le niveau des samples ; le kit est conservé."
            return nil
        }
        let exportProgram = program
        let pool = sounds
        let name = kitName
        busy = true
        errorMessage = nil
        samplePreviewGeneration += 1
        samplePreviewBusy = false
        audio.stop()
        status = "Export vers \(selectedDestinationLabel)…"
        return Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    return try KitExport.export(program: exportProgram, sounds: pool, name: name, to: destination,
                                                expectedDestination: expectedDestination)
                }.value
                self.busy = false
                self.isDirty = false
                self.lastExportURL = output
                self.libraryMode = .kits
                self.selectedLocation = nil
                self.kitSearch = ""
                self.kitName = output.deletingPathExtension().lastPathComponent
                if LibraryIndex.partitionLetter(for: destination) == nil && !self.kitFolders.contains(destination) {
                    self.kitFolders.append(destination)
                    self.preferences.set(self.kitFolders.map(\.path), forKey: "library.kitFolders")
                }
                self.status = "Export terminé · \(Self.locationLabel(for: output)) · \(output.lastPathComponent)."
                self.refreshLocations()
            } catch {
                self.busy = false
                self.errorMessage = error.localizedDescription
                self.status = "L’export n’a pas abouti ; le kit est conservé."
            }
        }
    }

    private func presentFilePanel(_ panel: NSOpenPanel,
                                  completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !documentLocked else { return }
        // The save dialog is already a sheet. Present its folder picker on the
        // active leaf rather than queueing another sheet behind the main window.
        var host = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
        while let attached = host?.attachedSheet { host = attached }
        filePanelPresented = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.filePanelPresented = false
            completion(response)
        }
        if let window = host {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    func clearPad() {
        guard !documentActionsDisabled, var updated = program else { return }
        let note = updated.midiNote(forPad: selectedPad)
        let oldSlot = updated.slot(forNote: note)
        updated.assign(slot: nil, toNote: note)
        if let oldSlot, !updated.referencedSlots.contains(oldSlot) {
            sounds.removeValue(forKey: oldSlot)
            audioRangeReports.removeValue(forKey: oldSlot)
            updated.setSound(slot: oldSlot, name: "", wordCount: 0)
        }
        program = updated
        sound = nil
        isDirty = true
    }

    func requestClose(_ completion: @escaping (Bool) -> Void) {
        guard !documentActionsDisabled else { NSSound.beep(); completion(false); return }
        stop()
        requestDiscard(completion)
    }

    private func requestDiscard(_ completion: @escaping (Bool) -> Void) {
        guard !awaitingDiscardConfirmation else { completion(false); return }
        guard isDirty else { completion(true); return }
        awaitingDiscardConfirmation = true
        let approval: (Bool) -> Void = { [weak self] approved in
            self?.awaitingDiscardConfirmation = false
            completion(approved)
        }
        if let discardPresenter { discardPresenter(approval); return }
        let alert = NSAlert()
        alert.messageText = "Des modifications n’ont pas été enregistrées."
        alert.informativeText = "Continuer ne les enregistrera pas. Les fichiers d’origine restent disponibles."
        alert.addButton(withTitle: "Continuer")
        alert.addButton(withTitle: "Annuler")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            approval(response == .alertFirstButtonReturn)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
