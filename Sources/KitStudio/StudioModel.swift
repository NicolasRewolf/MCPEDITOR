import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers
import MPCCore

/// What the computer pane shows: the Mac collection, a sample source, or one .PGM's samples.
enum LibrarySampleScope: Equatable, Sendable {
    case library
    case folder
    case program(LibraryKit)
}

struct SoundRangeWarning: Identifiable, Sendable {
    let slot: Int
    let name: String
    let report: PCM16RangeReport
    var id: Int { slot }
}

@MainActor
final class StudioModel: ObservableObject {
    @Published var selectedLocation: URL?
    @Published var programURL: URL?
    @Published var kitName = "NEWPROG"
    @Published var bank = 0
    @Published var selectedPad = 0
    @Published var isDirty = false
    @Published var busy = false
    @Published private(set) var resolvingDroppedFiles = false
    @Published var status = "Choisis une PART ou ouvre un dossier de .PGM."
    @Published var errorMessage: String?
    @Published var sound: MPCSound?
    @Published var program: MPCProgram?
    @Published private(set) var audioRangeReports: [Int: PCM16RangeReport] = [:]

    @Published var partitions: [LibraryPartition] = []
    @Published var libraryKits: [LibraryKit] = []
    @Published var libraryScanning = false
    @Published var libraryIssue: String?
    @Published private(set) var sampleScope: LibrarySampleScope = .library
    @Published private(set) var associations = ProgramAssociationIndex()
    @Published var sampleRoots: [URL] = []
    @Published var selectedSampleRoot: URL?
    @Published var sampleFolder: URL?
    @Published var sampleListing = LibraryFolderListing(folders: [], samples: [], issue: nil)
    @Published var selectedSampleURL: URL?
    @Published var sampleQuery = "" {
        didSet { if sampleQuery != oldValue { scheduleSampleSearch() } }
    }
    /// Folders opened in place in the sample tree, like a DAW browser. Kept per URL, so
    /// returning to a source finds it opened as it was left.
    @Published private(set) var expandedSampleFolders: Set<URL> = [] {
        didSet {
            guard expandedSampleFolders != oldValue else { return }
            preferences.set(expandedSampleFolders.map(\.path).sorted().prefix(300).map { $0 },
                            forKey: "library.expandedSampleFolders")
        }
    }
    @Published private(set) var sampleTreeListings: [URL: LibraryFolderListing] = [:]
    @Published private(set) var sampleSearch: SampleSearchState?
    /// A source is being read for the first time: the tree waits instead of saying "empty".
    @Published private(set) var sampleFolderReading = false
    /// The SD has its own sample pane beside the computer's: PARTs open in place.
    @Published var sdSampleQuery = ""
    @Published private(set) var expandedSDParts: Set<URL> = []
    /// One sample is chosen at a time, in either pane; this one belongs to the SD pane.
    @Published private(set) var selectedSDSampleURL: URL?
    @Published private(set) var mountedPartURLs: Set<URL> = []
    private var sampleSearchTask: Task<Void, Never>?
    @Published var samplePreviewBusy = false
    /// Choosing samples for a bank: play each one as soon as it is selected.
    @Published var autoPreviewSamples = false {
        didSet { preferences.set(autoPreviewSamples, forKey: "library.autoPreviewSamples") }
    }
    /// A preview that failed or a source that went away; routine progress is not reported.
    @Published private(set) var sampleProblem: String?
    @Published var lastExportURL: URL?
    @Published private(set) var localSaveURL: URL?
    @Published private var history = DocumentHistory()
    private var revision = UUID()
    private var savedRevision: UUID?
    private let localStore: LocalProgramStore
    private let padDragSession = UUID()
    private struct SampleNavigation {
        let scope: LibrarySampleScope
        let root: URL?
        let folder: URL?
        let query: String
        let selection: URL?
    }
    @Published private var sampleHistory: [SampleNavigation] = []
    @Published private(set) var awaitingDiscardConfirmation = false
    @Published private(set) var filePanelPresented = false
    @Published private(set) var awaitingKitTrashConfirmation = false
    @Published var showExportSheet = false
    @Published var exportDestinationURL: URL?
    @Published private(set) var exportDestinationReceipt: ExportDestination?
    @Published private(set) var validatingExportDestination = false

    private var kitFolders: [URL] = []
    private var libraryGeneration = 0
    private var sampleBrowseGeneration = 0
    private var samplePreviewGeneration = 0
    private var volumeObservation: WorkspaceMountObservation?
    private var volumeRefreshTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    private var refreshPending = false
    enum UnsavedDecision { case save, discard, cancel }
    typealias UnsavedPresenter = (@escaping (UnsavedDecision) -> Void) -> Void
    private let unsavedPresenter: UnsavedPresenter?
    typealias DiscardPresenter = (@escaping (Bool) -> Void) -> Void
    typealias TrashPresenter = (KitTrash.Prepared, @escaping (Bool) -> Void) -> Void
    private let discardPresenter: DiscardPresenter?
    private let trashPresenter: TrashPresenter?
    private let trashOperation: KitTrash.Operation
    private let preferences: UserDefaults
    private let volumeProvider: () -> [URL]
    private let sampleFolderLoader: @Sendable (URL) -> LibraryFolderListing
    private let exportDestinationCapture: @Sendable (URL) throws -> ExportDestination
    private var exportDestinationValidationGeneration = 0
    private var exportDestinationValidationTask: Task<Void, Never>?
    private var sounds: [Int: MPCSound] = [:]
    private let audio = StudioAudio()
    private var generation = 0
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
        recordEdit("Normaliser les samples hors plage")
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
         localLibraryURL: URL? = nil,
         discardPresenter: DiscardPresenter? = nil,
         unsavedPresenter: UnsavedPresenter? = nil,
         trashPresenter: TrashPresenter? = nil,
         trashOperation: @escaping KitTrash.Operation = { try KitTrash.systemTrash($0) },
         volumeProvider: @escaping () -> [URL] = {
             FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                  options: [.skipHiddenVolumes]) ?? []
         },
         sampleFolderLoader: @escaping @Sendable (URL) -> LibraryFolderListing = { LibraryIndex.listSamples(in: $0) },
         exportDestinationCapture: @escaping @Sendable (URL) throws -> ExportDestination = { try ExportDestination.capture(at: $0) }) {
        localStore = LocalProgramStore(rootURL: localLibraryURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MPC Kit Studio/Programs", isDirectory: true))
        self.unsavedPresenter = unsavedPresenter
        preferences = defaults
        self.discardPresenter = discardPresenter
        self.trashPresenter = trashPresenter
        self.trashOperation = trashOperation
        self.volumeProvider = volumeProvider
        self.sampleFolderLoader = sampleFolderLoader
        self.exportDestinationCapture = exportDestinationCapture
        savedRevision = revision
        kitFolders = (defaults.stringArray(forKey: "library.kitFolders") ?? []).map { URL(fileURLWithPath: $0) }
        sampleRoots = (defaults.stringArray(forKey: "library.sampleRoots") ?? []).map { URL(fileURLWithPath: $0) }
        autoPreviewSamples = defaults.bool(forKey: "library.autoPreviewSamples")
        repairFolderLocations()
        expandedSampleFolders = Set((defaults.stringArray(forKey: "library.expandedSampleFolders") ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) })
        restoreLastSamplePlace()
        FolderMemory.remember(kitFolders + sampleRoots, defaults: defaults)
        volumeObservation = WorkspaceMountObservation(center: NSWorkspace.shared.notificationCenter,
            names: [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification]) { [weak self] _ in
            Task { @MainActor in self?.scheduleVolumeRefresh() }
        }
    }

    deinit {
        volumeRefreshTask?.cancel()
        dropTask?.cancel()
        dropResolution?.cancel()
        exportDestinationValidationTask?.cancel()
    }

    var documentLocked: Bool { busy || awaitingDiscardConfirmation || filePanelPresented || awaitingKitTrashConfirmation }
    var documentActionsDisabled: Bool { documentLocked || showExportSheet || validatingExportDestination }

    var filteredKits: [LibraryKit] {
        guard let selectedPath = selectedLocation?.standardizedFileURL.pathComponents else { return libraryKits }
        return libraryKits.filter { $0.url.pathComponents.starts(with: selectedPath) }
    }

    struct KitGroup: Identifiable, Equatable {
        let id: String
        let title: String
        let kits: [LibraryKit]
    }

    /// The MPC finds a bank by its PART: the list groups .PGM files by where they live,
    /// the Mac collection first, then PARTs A–Z, then added folders. Order inside a
    /// group is the existing title order.
    var groupedFilteredKits: [KitGroup] {
        var order: [String] = []
        var titles: [String: String] = [:]
        var members: [String: [LibraryKit]] = [:]
        for kit in filteredKits {
            let (key, title) = kitGroup(for: kit)
            if members[key] == nil { order.append(key); titles[key] = title }
            members[key, default: []].append(kit)
        }
        return order.sorted().map { KitGroup(id: $0, title: titles[$0] ?? $0, kits: members[$0] ?? []) }
    }

    private func kitGroup(for kit: LibraryKit) -> (key: String, title: String) {
        if isMacLibraryKit(kit) { return ("0", "Bibliothèque sur le Mac") }
        if let letter = kit.partitionLetter { return ("1-\(letter)", "PART \(letter)") }
        // Folders sort by their visible name; the path only separates homonyms.
        let name = kit.rootURL.lastPathComponent
        return ("2-\(name.lowercased())-\(kit.rootURL.path)", name)
    }

    /// Inside its group, a row only needs the subfolder, filename and content.
    func kitRowSubtitle(for kit: LibraryKit) -> String {
        ([kit.relativeFolder.isEmpty ? nil : kit.relativeFolder, kit.url.lastPathComponent, kitContentSummary(for: kit)]
            .compactMap { $0 }).joined(separator: " · ")
    }

    private var scopedSamples: [URL] {
        switch sampleScope {
        case .library:
            return Array(Set(libraryKits.filter { isMacLibraryKit($0) }.flatMap {
                associations.association(for: $0.url)?.samples ?? []
            })).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        case .folder:
            return sampleTreeRows.compactMap { $0.kind == .sample ? $0.url : nil }
        case .program(let kit):
            return associations.association(for: kit.url)?.samples ?? []
        }
    }

    var filteredSamples: [URL] {
        if sampleScope == .folder { return folderSamples }
        return scopedSamples.filter {
            sampleQuery.isEmpty || $0.lastPathComponent.localizedStandardContains(sampleQuery) ||
                sampleLocationLabel(for: $0).localizedStandardContains(sampleQuery)
        }
    }

    // MARK: Sample tree

    struct SampleTreeRow: Identifiable, Equatable {
        enum Kind: Equatable {
            case folder(expanded: Bool, loading: Bool)
            case sample
            case notice(String)
        }
        let id: String
        let url: URL
        let depth: Int
        let kind: Kind
        var name: String { url.lastPathComponent }
        var isNotice: Bool {
            if case .notice = kind { return true }
            return false
        }
    }

    struct SampleSearchState: Equatable {
        let root: URL
        let query: String
        /// nil while the search is running.
        let result: LibrarySampleSearch?
    }

    /// The browsed source as a tree: opened folders show their content in place,
    /// folders first, then samples, both in Finder order.
    var sampleTreeRows: [SampleTreeRow] {
        guard sampleScope == .folder else { return [] }
        var rows: [SampleTreeRow] = []
        func append(_ listing: LibraryFolderListing, depth: Int) {
            for folder in listing.folders {
                let expanded = expandedSampleFolders.contains(folder)
                let child = expanded ? sampleTreeListings[folder] : nil
                rows.append(SampleTreeRow(id: folder.path, url: folder, depth: depth,
                                          kind: .folder(expanded: expanded, loading: expanded && child == nil)))
                guard let child else { continue }
                if let issue = child.issue {
                    rows.append(SampleTreeRow(id: folder.path + "#issue", url: folder, depth: depth + 1, kind: .notice(issue)))
                } else if child.folders.isEmpty && child.samples.isEmpty {
                    rows.append(SampleTreeRow(id: folder.path + "#empty", url: folder, depth: depth + 1,
                                              kind: .notice("Aucun sample ici")))
                }
                append(child, depth: depth + 1)
            }
            for sample in listing.samples {
                rows.append(SampleTreeRow(id: sample.path, url: sample, depth: depth, kind: .sample))
            }
        }
        append(sampleListing, depth: 0)
        return rows
    }

    /// A query searches the whole source (bounded); until its answer arrives, the
    /// folders already read give an immediate partial answer.
    private var folderSamples: [URL] {
        let query = sampleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scopedSamples }
        if let search = sampleSearch, search.query == sampleQuery, search.root == sampleTreeRoot,
           let result = search.result {
            return result.samples
        }
        guard let root = sampleTreeRoot else { return [] }
        let loaded = sampleListing.samples + sampleTreeListings.values.flatMap(\.samples)
        return Array(Set(loaded)).filter {
            LibraryIndex.sampleMatches(relativePath: Self.relativePath(of: $0, in: root), query: query)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var sampleSearchInProgress: Bool {
        guard let search = sampleSearch else { return false }
        return search.result == nil && search.query == sampleQuery
    }

    var sampleSearchTruncated: Bool {
        sampleSearch.map { $0.query == sampleQuery && $0.result?.truncated == true } ?? false
    }

    /// The folder the tree starts from: the source itself, or a subfolder it was focused on.
    private var sampleTreeRoot: URL? {
        guard sampleScope == .folder else { return nil }
        return (sampleFolder ?? selectedSampleRoot)?.standardizedFileURL
    }

    var isSampleTreeSearch: Bool {
        sampleScope == .folder && !sampleQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated private static func relativePath(of url: URL, in root: URL) -> String {
        url.standardizedFileURL.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
    }

    nonisolated private static func isInside(_ folder: URL, root: URL) -> Bool {
        folder.pathComponents.starts(with: root.pathComponents) &&
            folder.resolvingSymlinksInPath().pathComponents.starts(with: root.resolvingSymlinksInPath().pathComponents)
    }

    /// Opens or closes a folder of the tree in place. Only a folder the tree shows can
    /// open, and only inside the browsed source; each folder is read once, one level deep.
    @discardableResult
    func toggleSampleFolder(_ url: URL) -> Task<Void, Never>? {
        let folder = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        if expandedSampleFolders.contains(folder) {
            expandedSampleFolders.remove(folder)
            return nil
        }
        guard let root = sampleTreeRoot,
              sampleTreeRows.contains(where: { $0.url == folder && $0.id == folder.path }) else { return nil }
        expandedSampleFolders.insert(folder)
        return loadMissingTreeFolders(root: root)
    }

    /// Reads the opened folders the tree shows without content yet.
    private func loadMissingTreeFolders(root: URL) -> Task<Void, Never>? {
        let missing = sampleTreeRows.compactMap { row -> URL? in
            if case .folder(true, true) = row.kind { return row.url }
            return nil
        }.filter { Self.isInside($0, root: root) }
        guard !missing.isEmpty else { return nil }
        let loader = sampleFolderLoader
        return Task {
            let listings = await Task.detached(priority: .userInitiated) {
                missing.map { ($0, loader($0)) }
            }.value
            guard self.sampleTreeRoot == root else { return }
            for (folder, listing) in listings where self.expandedSampleFolders.contains(folder) {
                self.sampleTreeListings[folder] = listing
            }
            // A folder opened inside one that just arrived may itself be open already.
            await self.loadMissingTreeFolders(root: root)?.value
        }
    }

    private func scheduleSampleSearch() {
        sampleSearchTask?.cancel()
        sampleSearchTask = nil
        let original = sampleQuery
        let query = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let root = sampleTreeRoot else {
            sampleSearch = nil
            return
        }
        sampleSearch = SampleSearchState(root: root, query: original, result: nil)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        sampleSearchTask = Task {
            // Typing a word should start one search, not one per letter.
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) {
                    LibraryIndex.searchSamples(in: root, matching: query,
                                               isCancelled: { cancelled.withLock { $0 } })
                }.value
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
            guard !Task.isCancelled, self.sampleQuery == original, self.sampleTreeRoot == root else { return }
            self.sampleSearch = SampleSearchState(root: root, query: original, result: result)
        }
    }

    /// The running search, for tests that wait for its answer.
    var pendingSampleSearch: Task<Void, Never>? { sampleSearchTask }

    enum SamplePlace: Hashable {
        case library
        case root(URL)
    }

    /// Which entry of the places list the browser is showing, if any.
    var selectedSamplePlace: SamplePlace? {
        switch sampleScope {
        case .library: return .library
        case .program: return nil
        case .folder:
            guard let root = selectedSampleRoot?.standardizedFileURL,
                  sampleRoots.contains(where: { $0.standardizedFileURL == root }) else { return nil }
            return .root(root)
        }
    }

    /// Showing a file in the Finder reads nothing and changes nothing.
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    struct SampleGroup: Identifiable, Equatable {
        let id: String
        let samples: [URL]
        var title: String { id }
    }

    /// The source is said once per group instead of under every sample name.
    var groupedFilteredSamples: [SampleGroup] {
        var order: [String] = []
        var members: [String: [URL]] = [:]
        let treeRoot = sampleTreeRoot
        let macOwner = sampleScope == .library ? macLibrarySampleOwners : [:]
        for sample in filteredSamples {
            let label = macOwner[sample]
                ?? treeRoot.map { sampleFolderLabel(for: sample, in: $0) }
                ?? sampleLocationLabel(for: sample)
            if members[label] == nil { order.append(label) }
            members[label, default: []].append(sample)
        }
        return order.map { SampleGroup(id: $0, samples: members[$0] ?? []) }
    }

    /// Each saved .PGM keeps its own copy of its samples: the Mac list is grouped by .PGM.
    private var macLibrarySampleOwners: [URL: String] {
        let pairs = libraryKits.filter(isMacLibraryKit).flatMap { kit in
            (associations.association(for: kit.url)?.samples ?? []).map { ($0, kit.title) }
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    /// Search results say their folder below the source, not only its last name.
    private func sampleFolderLabel(for sample: URL, in root: URL) -> String {
        let relative = Self.relativePath(of: sample.deletingLastPathComponent(), in: root)
        return relative.isEmpty ? root.lastPathComponent : relative.replacingOccurrences(of: "/", with: " / ")
    }

    var sampleScopeTitle: String {
        switch sampleScope {
        case .library: return "Bibliothèque sur le Mac"
        case .folder:
            guard let sampleFolder else { return "Dossier de samples" }
            if let part = partition(containing: sampleFolder) {
                return sampleFolder == part.url ? "Samples · PART \(part.letter)" : "PART \(part.letter) · \(sampleFolder.lastPathComponent)"
            }
            return sampleFolder.lastPathComponent
        case .program(let kit): return "\(kit.url.lastPathComponent) · \(kit.locationLabel)"
        }
    }

    var sampleScopeIssue: String? {
        switch sampleScope {
        case .library:
            let issues = libraryKits.filter { isMacLibraryKit($0) }
                .flatMap { associations.association(for: $0.url)?.issues ?? [] }
            return issues.isEmpty ? nil : Array(NSOrderedSet(array: issues)).compactMap { $0 as? String }.joined(separator: "\n")
        case .folder: return sampleListing.issue
        case .program(let kit):
            guard libraryKits.contains(where: { $0.url == kit.url }) else {
                return "Ce .PGM n’est plus disponible dans la bibliothèque. Rebranche sa source puis actualise."
            }
            let issues = associations.association(for: kit.url)?.issues ?? ["Les liens de ce .PGM ne sont pas encore vérifiés. Actualise la bibliothèque."]
            return issues.isEmpty ? nil : issues.joined(separator: "\n")
        }
    }

    func programsUsingSample(_ url: URL) -> [LibraryKit] {
        associations.programs(using: url).filter { linked in
            libraryKits.contains { $0.url == linked.url }
        }
    }

    var selectedSampleAssociationNotice: String? {
        guard selectedSampleURL != nil else { return nil }
        if libraryScanning { return "Actualisation des liens vers les .PGM enregistrés…" }
        var notice = "Liens vérifiés dans les .PGM enregistrés de la bibliothèque. Les modifications en mémoire ne sont pas incluses."
        if libraryIssue != nil || !associations.issues.isEmpty {
            notice += " L’inventaire est incomplet ; d’autres liens peuvent manquer."
        }
        return notice
    }

    /// Banks are chosen by content: the resolved sample count tells apart homonyms such
    /// as several PROGRAM_.pgm files across PARTs. Read-only, like the associations.
    func kitContentSummary(for kit: LibraryKit) -> String? {
        guard !libraryScanning, let association = associations.association(for: kit.url) else { return nil }
        let count = association.samples.count
        let samples = "\(count) sample\(count > 1 ? "s" : "")"
        return association.isComplete ? samples : "\(samples) · liens incomplets"
    }

    func kitTitleOnMPC(for kit: LibraryKit) -> String? {
        guard let title = associations.association(for: kit.url)?.title, !title.isEmpty, title != kit.title else { return nil }
        return title
    }

    func libraryLocationLabel(for kit: LibraryKit) -> String {
        isMacLibraryKit(kit) ? "Bibliothèque sur le Mac" : kit.locationLabel
    }

    func sampleLocationLabel(for url: URL) -> String {
        if url.standardizedFileURL.pathComponents.starts(with: localStore.rootURL.pathComponents) {
            return "Bibliothèque sur le Mac"
        }
        if let part = partition(containing: url) {
            let folder = url.deletingLastPathComponent()
            let relative = folder.pathComponents.dropFirst(part.url.pathComponents.count).joined(separator: "/")
            return relative.isEmpty ? "PART \(part.letter)" : "PART \(part.letter) · \(relative)"
        }
        return url.deletingLastPathComponent().lastPathComponent
    }

    private func partition(containing folder: URL?) -> LibraryPartition? {
        guard let folder = folder?.standardizedFileURL else { return nil }
        return partitions.first { folder.pathComponents.starts(with: $0.url.pathComponents) }
    }

    var assignedPadCount: Int {
        guard let program else { return 0 }
        return (0..<64).filter { program.slot(forNote: program.midiNote(forPad: $0)) != nil }.count
    }

    private var preparedCopy: KitExport.PreparedCopy? {
        guard let program else { return nil }
        return try? KitExport.prepareCopy(program: program, sounds: sounds)
    }

    var estimatedExportBytes: Int64? { preparedCopy?.nominalBytes }

    var exportSizeLabel: String {
        estimatedExportBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? "Taille indisponible"
    }

    var requiredExportFreeBytes: Int64 {
        guard let preparedCopy else { return Int64.max }
        let conservativeFAT = ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: 0)
        return (try? ExportSpace.estimate(fileSizes: preparedCopy.fileSizes, volume: conservativeFAT).requiredBytes) ?? Int64.max
    }

    func requiredExportFreeBytes(in partition: LibraryPartition) -> Int64 {
        guard let preparedCopy else { return Int64.max }
        let space = partition.volumeSpace ?? ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: partition.availableBytes ?? 0)
        return (try? ExportSpace.estimate(fileSizes: preparedCopy.fileSizes, volume: space).requiredBytes) ?? Int64.max
    }

    /// A bank is copied into one PART: compare what the copy needs with an empty PART.
    struct PartCapacity: Equatable {
        /// Same estimate as the copy check: FAT allocation, metadata and reserve.
        let requiredBytes: Int64
        let capacityBytes: Int64
        /// The empty PART measured now, or nil when the capacity was remembered.
        let measuredLetter: String?
        var fits: Bool { requiredBytes <= capacityBytes }
        var fraction: Double { capacityBytes > 0 ? Double(requiredBytes) / Double(capacityBytes) : 1 }
    }

    private static let emptyPartBytesKey = "library.emptyPartAvailableBytes"
    private static let emptyPartUnitKey = "library.emptyPartAllocationUnit"

    var partCapacity: PartCapacity? {
        guard let preparedCopy, assignedPadCount > 0 else { return nil }
        let measured = partitions
            .filter { $0.isEmpty && $0.volumeSpace != nil }
            .max { ($0.volumeSpace?.availableBytes ?? 0) < ($1.volumeSpace?.availableBytes ?? 0) }
        let space: ExportVolumeSpace
        if let measured, let volume = measured.volumeSpace {
            space = volume
        } else {
            let bytes = Int64(preferences.integer(forKey: Self.emptyPartBytesKey))
            let unit = Int64(preferences.integer(forKey: Self.emptyPartUnitKey))
            guard bytes > 0, unit > 0 else { return nil }
            space = ExportVolumeSpace(allocationUnitBytes: unit, availableBytes: bytes)
        }
        guard let required = try? ExportSpace.estimate(fileSizes: preparedCopy.fileSizes, volume: space).requiredBytes
        else { return nil }
        return PartCapacity(requiredBytes: required, capacityBytes: space.availableBytes,
                            measuredLetter: measured?.letter)
    }

    /// The PART view details PARTs with content or a problem; empty ones share one summary.
    var partsWithContent: [LibraryPartition] { partitions.filter { !$0.isEmpty } }
    var emptyParts: [LibraryPartition] { partitions.filter(\.isEmpty) }

    /// Free space of an empty PART, measured now or remembered, used for fill bars.
    var emptyPartCapacityBytes: Int64? {
        if let measured = partitions.filter(\.isEmpty).compactMap(\.volumeSpace).map(\.availableBytes).max() {
            return measured
        }
        let remembered = Int64(preferences.integer(forKey: Self.emptyPartBytesKey))
        return remembered > 0 ? remembered : nil
    }

    /// Keeps the largest empty PART seen, so the gauge still works with the card out.
    func rememberEmptyPartCapacity(_ parts: [LibraryPartition]) {
        guard let space = parts.filter({ $0.isEmpty }).compactMap(\.volumeSpace)
            .max(by: { $0.availableBytes < $1.availableBytes }) else { return }
        preferences.set(Int(space.availableBytes), forKey: Self.emptyPartBytesKey)
        preferences.set(Int(space.allocationUnitBytes), forKey: Self.emptyPartUnitKey)
    }

    var documentSaveLabel: String {
        if localSaveURL != nil { return isDirty ? "Modifications non enregistrées" : "Enregistré sur le Mac" }
        if isDirty { return "À enregistrer sur le Mac" }
        return programURL == nil ? "Nouveau .PGM" : "Source ouverte · enregistrer sur le Mac pour la conserver"
    }

    var kitLocationPath: String { (localSaveURL ?? programURL ?? lastExportURL)?.path ?? "" }

    var selectedDestinationLabel: String {
        guard let destination = exportDestinationURL else { return "Choisir une destination" }
        return partitions.first { $0.url == destination.standardizedFileURL }.map { "PART \($0.letter)" } ?? destination.lastPathComponent
    }

    var exportDestinationIssue: String? {
        if validatingExportDestination { return "Vérification de l’emplacement en cours… Tu peux annuler sans modifier le .PGM." }
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
        if let url = localSaveURL ?? programURL ?? lastExportURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// Saving on the Mac and copying to the SD both write DOS 8.3 names. Show the
    /// resulting name while it is edited, rather than discovering it on the MPC.
    var programFileNamePreview: String? {
        let stem = KitExport.dosStem(kitName, fallback: "KIT")
        return stem == kitName ? nil : stem + ".PGM"
    }

    var soundFileNamePreview: String? {
        guard let name = sound?.name else { return nil }
        let stem = KitExport.dosStem(name, fallback: "SOUND")
        return stem == name ? nil : stem + ".SND"
    }

    /// On an SD PART, macOS moves a trashed file into a hidden .Trashes on that same PART:
    /// its clusters stay occupied and the PART can no longer be verified as a destination.
    func trashRefusal(for kit: LibraryKit) -> String? {
        guard let letter = kit.partitionLetter else { return nil }
        return "La corbeille n’est pas proposée sur la SD. macOS garderait \(kit.url.lastPathComponent) dans un dossier caché .Trashes de la PART \(letter) : la place resterait occupée et la PART ne pourrait plus être vérifiée. Supprime ce .PGM depuis la MPC si nécessaire."
    }

    /// A kit is a program. Its samples and sequences remain independent on disk.
    @discardableResult
    func requestTrashKit(_ kit: LibraryKit) -> Task<Void, Never>? {
        guard !documentActionsDisabled else { return nil }
        if let refusal = trashRefusal(for: kit) {
            errorMessage = refusal
            return nil
        }
        awaitingKitTrashConfirmation = true
        stop()
        errorMessage = nil
        return Task { [weak self] in
            let prepared: KitTrash.Prepared
            do {
                prepared = try await Task.detached(priority: .userInitiated) {
                    try KitTrash.prepare(kit.url)
                }.value
            } catch {
                self?.awaitingKitTrashConfirmation = false
                self?.errorMessage = error.localizedDescription
                return
            }
            self?.confirmTrash(prepared)
        }
    }

    /// The confirmation names the exact file; only an explicit yes moves it.
    private func confirmTrash(_ prepared: KitTrash.Prepared) {
        let confirmation: (Bool) -> Void = { [weak self] approved in
            guard let self, self.awaitingKitTrashConfirmation else { return }
            if approved { self.moveConfirmedKitToTrash(prepared) }
            else { self.awaitingKitTrashConfirmation = false }
        }
        if let trashPresenter {
            trashPresenter(prepared, confirmation)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Mettre \(prepared.url.lastPathComponent) à la corbeille ?"
        alert.informativeText = "Le programme .PGM se trouve ici :\n\(prepared.url.path)\n\nLes samples .SND et les séquences .SEQ restent sur le disque. Cette action libère très peu d’espace. Le .PGM ouvert reste en mémoire ; tu peux l’enregistrer à nouveau."
        alert.addButton(withTitle: "Mettre à la corbeille")
        alert.addButton(withTitle: "Annuler")
        alert.buttons.first?.hasDestructiveAction = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            confirmation(response == .alertFirstButtonReturn)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
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
                let wasCurrent = self.programURL?.standardizedFileURL == deletedURL ||
                    self.localSaveURL?.standardizedFileURL == deletedURL ||
                    (self.localSaveURL == nil && self.lastExportURL?.standardizedFileURL == deletedURL)
                if self.localSaveURL?.standardizedFileURL == deletedURL { self.localSaveURL = nil }
                if self.programURL?.standardizedFileURL == deletedURL { self.programURL = nil }
                if self.lastExportURL?.standardizedFileURL == deletedURL { self.lastExportURL = nil }
                if wasCurrent { self.savedRevision = nil; self.isDirty = true }
                self.libraryKits.removeAll { $0.url == deletedURL }
                self.busy = false
                self.status = "\(deletedURL.lastPathComponent) mis à la corbeille. Les samples et les séquences sont conservés."
                self.refreshLocations()
            } catch {
                self.busy = false
                self.errorMessage = error.localizedDescription
                self.status = "La mise à la corbeille n’a pas abouti ; le .PGM en mémoire est conservé."
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
        repairFolderLocations()
        libraryGeneration += 1
        let token = libraryGeneration
        let mounted = Set(volumeProvider().map(\.standardizedFileURL))
        // Retain known PARTs after disconnection, with an explicit unavailable scan.
        let partURLs = Array(Set(mounted.filter { LibraryIndex.partitionLetter(for: $0) != nil }).union(partitions.map(\.url)))
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let folders = kitFolders
        let store = localStore
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
                let local = store.scan()
                kits += local.kits
                issues += local.issues
                for folder in folders {
                    if let part = partURLs.first(where: { folder.pathComponents.starts(with: $0.pathComponents) }),
                       !mounted.contains(part) { continue }
                    do {
                        kits += try LibraryIndex.scanKits(in: folder).map { kit in
                            // A local backup named MPC-PART--X is still a folder,
                            // not proof that a programme is present on a mounted SD.
                            let part = partURLs.first { kit.url.pathComponents.starts(with: $0.pathComponents) }
                            return LibraryKit(url: kit.url, rootURL: kit.rootURL,
                                              partitionLetter: part.flatMap(LibraryIndex.partitionLetter(for:)),
                                              relativeFolder: kit.relativeFolder)
                        }
                    }
                    catch { issues.append(error.localizedDescription) }
                }
                kits = Array(Dictionary(kits.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first }).values)
                    .sorted { $0.title == $1.title ? $0.url.path < $1.url.path :
                        $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let associations = ProgramAssociationIndex.scan(programs: kits, upstreamIssues: issues)
                return (parts, kits, associations)
            }.value
            guard token == self.libraryGeneration else { return }
            self.partitions = result.0
            self.rememberEmptyPartCapacity(result.0)
            self.libraryKits = result.1
            self.associations = result.2
            self.libraryIssue = result.2.issues.isEmpty ? nil : result.2.issues.joined(separator: "\n")
            self.mountedPartURLs = Set(partURLs.filter(mounted.contains))
            self.validateSDSampleSelection()
            if let folder = self.sampleFolder {
                await self.loadSamplesFolder(folder, preservingSelection: true)?.value
            } else {
                self.updateScopedSampleSelection()
            }
            self.libraryScanning = false
            self.libraryTask = nil
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
        panel.title = "Ajouter un dossier de .PGM"
        panel.prompt = "Ajouter"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        presentFilePanel(panel) { [weak self] response in
            guard response == .OK, let self, let url = panel.url?.standardizedFileURL else { return }
            if !self.kitFolders.contains(url) { self.kitFolders.append(url) }
            self.persistFolderLists()
            self.filterPrograms(to: url)
            self.refreshLocations()
        }
    }

    func showAllLibrarySamples() {
        preferences.removeObject(forKey: "library.lastSamplePlace")
        switchSampleScope(to: .library)
    }

    func showSamples(in kit: LibraryKit) {
        switchSampleScope(to: .program(kit))
    }

    /// Library navigation never replaces or clears the document being edited.
    private func switchSampleScope(to scope: LibrarySampleScope) {
        guard sampleScope != scope else { return }
        rememberSampleNavigation()
        sampleBrowseGeneration += 1
        stop()
        sampleScope = scope
        sampleProblem = nil
        sampleFolderReading = false
        selectedSampleRoot = nil
        sampleFolder = nil
        sampleListing = LibraryFolderListing(folders: [], samples: [], issue: nil)
        selectedSampleURL = nil
        sampleQuery = ""
        updateScopedSampleSelection()
    }

    private func updateScopedSampleSelection() {
        guard let selectedSampleURL, !scopedSamples.contains(selectedSampleURL) else { return }
        stop()
        self.selectedSampleURL = nil
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
            self.persistFolderLists()
            self.selectSampleRoot(url)
        }
    }

    /// Paths stay the stored order; each reachable folder also gets a bookmark.
    private func persistFolderLists() {
        preferences.set(kitFolders.map(\.path), forKey: "library.kitFolders")
        preferences.set(sampleRoots.map(\.path), forKey: "library.sampleRoots")
        FolderMemory.remember(kitFolders + sampleRoots, defaults: preferences)
    }

    /// A volume remounted under another name ("T9 1" → "T9") keeps its folders reachable.
    private func repairFolderLocations() {
        let kits = FolderMemory.resolve(kitFolders, defaults: preferences)
        let roots = FolderMemory.resolve(sampleRoots, defaults: preferences)
        guard kits != kitFolders || roots != sampleRoots else { return }
        kitFolders = kits
        sampleRoots = roots
        persistFolderLists()
    }

    /// Folders added to the library, without the SD PARTs.
    var addedKitFolders: [URL] { kitFolders }

    /// Forgets a folder in the library list only: no file is moved, renamed or deleted.
    func removeKitFolder(_ url: URL) {
        guard !documentLocked else { return }
        let path = url.standardizedFileURL.path
        guard kitFolders.contains(where: { $0.standardizedFileURL.path == path }) else { return }
        kitFolders.removeAll { $0.standardizedFileURL.path == path }
        persistFolderLists()
        if let selected = selectedLocation?.standardizedFileURL.pathComponents,
           selected.starts(with: URL(fileURLWithPath: path).pathComponents) {
            selectedLocation = nil
        }
        status = "\(url.lastPathComponent) retiré de la liste. Ses fichiers restent sur le disque."
        refreshLocations()
    }

    /// Forgets a sample source in the list only: no file is moved, renamed or deleted.
    func removeSampleRoot(_ url: URL) {
        guard !documentLocked else { return }
        let path = url.standardizedFileURL.path
        guard sampleRoots.contains(where: { $0.standardizedFileURL.path == path }) else { return }
        sampleRoots.removeAll { $0.standardizedFileURL.path == path }
        persistFolderLists()
        if sampleScope == .folder, selectedSampleRoot?.standardizedFileURL.path == path {
            showAllLibrarySamples()
        }
        status = "\(url.lastPathComponent) retiré des sources de samples. Ses fichiers restent sur le disque."
    }

    /// The computer pane reopens on the source left last time, without a back step.
    private func restoreLastSamplePlace() {
        guard let path = preferences.string(forKey: "library.lastSamplePlace"),
              let root = sampleRoots.first(where: { $0.standardizedFileURL.path == path }) else { return }
        selectedSampleRoot = root.standardizedFileURL
        _ = loadSamplesFolder(root, preservingSelection: false)
    }

    /// The returned task ends when the source's tree has been read.
    @discardableResult
    func selectSampleRoot(_ url: URL) -> Task<Void, Never>? {
        rememberSampleNavigation()
        if sampleRoots.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            preferences.set(url.standardizedFileURL.path, forKey: "library.lastSamplePlace")
        }
        selectedSampleRoot = url.standardizedFileURL
        sampleQuery = ""
        return loadSamplesFolder(url, preservingSelection: false)
    }

    private func loadSamplesFolder(_ url: URL, preservingSelection: Bool) -> Task<Void, Never>? {
        guard let root = selectedSampleRoot?.standardizedFileURL else { return nil }
        let folder = url.standardizedFileURL
        sampleScope = .folder
        if let part = partitions.first(where: { folder.pathComponents.starts(with: $0.url.pathComponents) }),
           !Set(volumeProvider().map(\.standardizedFileURL)).contains(part.url) {
            invalidateSampleFolder(folder, issue: "Cette PART n’est plus montée. Rebranche la SD puis actualise.",
                                   problem: "PART indisponible.")
            return nil
        }
        guard folder.pathComponents.starts(with: root.pathComponents),
              folder.resolvingSymlinksInPath().pathComponents.starts(with: root.resolvingSymlinksInPath().pathComponents) else {
            if preservingSelection {
                invalidateSampleFolder(folder, issue: "Ce dossier ne se trouve plus dans la source de samples sélectionnée.",
                                       problem: "Dossier indisponible.")
            }
            return nil
        }
        sampleBrowseGeneration += 1
        let token = sampleBrowseGeneration
        sampleFolder = folder
        if !preservingSelection {
            stop()
            selectedSampleURL = nil
            sampleQuery = ""
            sampleListing = LibraryFolderListing(folders: [], samples: [], issue: nil)
            sampleTreeListings = [:]
            sampleFolderReading = true
            sampleProblem = nil
        }
        let loader = sampleFolderLoader
        let expanded = expandedSampleFolders
        return Task {
            // The folders left open are read again with it, so the tree comes back whole.
            let (listing, children) = await Task.detached(priority: .utility) {
                let listing = loader(folder)
                var children: [URL: LibraryFolderListing] = [:]
                var pending = listing.issue == nil ? listing.folders.filter(expanded.contains) : []
                while let next = pending.popLast() {
                    guard Self.isInside(next, root: root) else { continue }
                    let child = loader(next)
                    children[next] = child
                    if child.issue == nil { pending += child.folders.filter(expanded.contains) }
                }
                return (listing, children)
            }.value
            guard token == self.sampleBrowseGeneration else { return }
            self.sampleFolderReading = false
            self.sampleListing = listing
            self.sampleTreeListings = children
            // Validate the current selection: it may have changed while the
            // refresh was reading. Never restore a selection captured earlier.
            let known = Set(listing.samples + children.values.flatMap(\.samples)
                            + (self.sampleSearch?.result?.samples ?? []))
            if listing.issue != nil || self.selectedSampleURL.map({ !known.contains($0) }) == true {
                self.stop()
                self.selectedSampleURL = nil
            }
            if !self.sampleQuery.isEmpty, preservingSelection { self.scheduleSampleSearch() }
            // A folder opened while this read was running is read on its own.
            _ = self.loadMissingTreeFolders(root: folder)
            self.sampleProblem = listing.issue == nil
                ? nil : "Dossier indisponible ou inventaire incomplet. Actualise la bibliothèque."
        }
    }

    private func invalidateSampleFolder(_ folder: URL, issue: String, problem: String) {
        sampleBrowseGeneration += 1
        stop()
        sampleFolder = folder
        sampleTreeListings = [:]
        sampleSearch = nil
        sampleFolderReading = false
        selectedSampleURL = nil
        sampleListing = LibraryFolderListing(folders: [], samples: [], issue: issue)
        sampleProblem = problem
    }

    func selectSample(_ url: URL) {
        if selectedSampleURL != url { stop() }
        selectedSampleURL = url
        selectedSDSampleURL = nil
        if autoPreviewSamples { startPreview(url) }
    }

    /// One click on a sample selects it and plays it, replacing a preview in progress.
    func playSample(_ url: URL) {
        if selectedSampleURL != url { stop() }
        selectedSampleURL = url
        selectedSDSampleURL = nil
        startPreview(url)
    }

    // MARK: SD pane

    /// The sample "Affecter au pad" uses: the one chosen last, in either pane.
    var chosenSampleURL: URL? { selectedSampleURL ?? selectedSDSampleURL }

    struct SDSampleRow: Identifiable, Equatable {
        enum Kind: Equatable {
            case part(letter: String, count: Int, expanded: Bool, issue: String?)
            case sample
        }
        let id: String
        let url: URL
        let kind: Kind
    }

    /// Mounted PARTs that hold samples, in letter order; one opens to list its samples.
    /// A search opens every PART that matches.
    var sdSampleRows: [SDSampleRow] {
        let query = sdSampleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [SDSampleRow] = []
        for part in partitions where mountedPartURLs.contains(part.url) && (part.audioCount > 0 || !part.issues.isEmpty) {
            let samples = query.isEmpty ? part.samples : part.samples.filter {
                LibraryIndex.sampleMatches(relativePath: Self.relativePath(of: $0, in: part.url), query: query)
            }
            if !query.isEmpty && samples.isEmpty { continue }
            let expanded = !query.isEmpty || expandedSDParts.contains(part.url)
            rows.append(SDSampleRow(id: part.url.path, url: part.url, kind: .part(
                letter: part.letter, count: samples.count, expanded: expanded,
                issue: part.issues.isEmpty ? nil : part.issues.joined(separator: "\n"))))
            if expanded {
                rows += samples.map { SDSampleRow(id: $0.path, url: $0, kind: .sample) }
            }
        }
        return rows
    }

    var visibleSDSamples: [URL] { sdSampleRows.compactMap { $0.kind == .sample ? $0.url : nil } }
    var sdSampleCount: Int { partitions.filter { mountedPartURLs.contains($0.url) }.reduce(0) { $0 + $1.samples.count } }
    var sdIsMounted: Bool { !mountedPartURLs.isEmpty }
    var mountedPartsWithContent: [LibraryPartition] { partsWithContent.filter { mountedPartURLs.contains($0.url) } }

    /// A PART that cannot be fully read is said once in the SD pane header.
    var sdSamplesIssue: String? {
        let issues = partitions.filter { mountedPartURLs.contains($0.url) }.flatMap { part in
            part.issues.map { "PART \(part.letter) : \($0)" }
        }
        return issues.isEmpty ? nil : issues.joined(separator: "\n")
    }

    func toggleSDPart(_ url: URL) {
        if expandedSDParts.contains(url) { expandedSDParts.remove(url) } else { expandedSDParts.insert(url) }
    }

    func selectSDSample(_ url: URL) {
        if selectedSDSampleURL != url { stop() }
        selectedSDSampleURL = url
        selectedSampleURL = nil
        if autoPreviewSamples { startPreview(url) }
    }

    func playSDSample(_ url: URL) {
        if selectedSDSampleURL != url { stop() }
        selectedSDSampleURL = url
        selectedSampleURL = nil
        startPreview(url)
    }

    func moveSDSampleSelection(by offset: Int) {
        let samples = visibleSDSamples
        guard !samples.isEmpty else { return }
        let next: Int
        if let current = selectedSDSampleURL, let index = samples.firstIndex(of: current) {
            next = min(samples.count - 1, max(0, index + offset))
        } else {
            next = offset >= 0 ? 0 : samples.count - 1
        }
        guard samples[next] != selectedSDSampleURL else { return }
        selectSDSample(samples[next])
    }

    /// After a refresh or an unmount, an SD sample that is no longer listed is not kept.
    private func validateSDSampleSelection() {
        guard let selected = selectedSDSampleURL else { return }
        let listed = partitions.contains { mountedPartURLs.contains($0.url) && $0.samples.contains(selected) }
        if !listed {
            stop()
            selectedSDSampleURL = nil
        }
    }

    /// Filters the .PGM column only; the sample panes keep what they show.
    func filterPrograms(to url: URL?) {
        selectedLocation = url?.standardizedFileURL
    }

    var macLibraryURL: URL { localStore.rootURL }

    /// Paths, not URLs: the same folder may be spelled with or without its final slash.
    func isMacLibraryKit(_ kit: LibraryKit) -> Bool {
        kit.rootURL.standardizedFileURL.path == localStore.rootURL.standardizedFileURL.path
    }

    /// The .PGM column's own caveat: the chosen PART's, or the whole inventory's.
    var programListIssue: String? {
        if let part = partition(containing: selectedLocation) {
            return part.issues.isEmpty ? nil : part.issues.joined(separator: "\n")
        }
        return libraryIssue
    }

    /// An empty tree is called empty only when the inventory can conclude it.
    var emptySampleTreeTitle: String {
        if sampleListing.issue != nil { return "Dossier indisponible" }
        return sampleBrowserIssue == nil ? "Dossier vide" : "Aucun sample visible"
    }

    var emptySampleTreeDetail: String {
        if let issue = sampleListing.issue { return issue }
        return sampleBrowserIssue == nil
            ? "Aucun sample ni sous-dossier ici."
            : "Les fichiers visibles ne permettent pas de conclure que ce dossier est vide."
    }

    /// The computer pane's own caveat, never the SD's.
    var sampleBrowserIssue: String? {
        var issues: [String] = []
        let shownFrom: URL? = switch sampleScope {
        case .folder: sampleFolder ?? selectedSampleRoot
        case .program(let kit): kit.url
        case .library: nil
        }
        if let part = partition(containing: shownFrom) { issues += part.issues }
        if let issue = sampleScopeIssue { issues.append(issue) }
        if sampleSearch?.query == sampleQuery, let issue = sampleSearch?.result?.issue { issues.append(issue) }
        let unique = Array(NSOrderedSet(array: issues)).compactMap { $0 as? String }
        return unique.isEmpty ? nil : unique.joined(separator: "\n")
    }

    /// Arrow keys walk the visible samples; with auto preview, each one plays in turn.
    func moveSampleSelection(by offset: Int) {
        let samples = filteredSamples
        guard !samples.isEmpty else { return }
        let next: Int
        if let current = selectedSampleURL, let index = samples.firstIndex(of: current) {
            next = min(samples.count - 1, max(0, index + offset))
        } else {
            next = offset >= 0 ? 0 : samples.count - 1
        }
        guard samples[next] != selectedSampleURL else { return }
        selectSample(samples[next])
    }

    /// The newest request wins: an earlier load still decoding is ignored when it ends.
    private func startPreview(_ url: URL) {
        guard !documentActionsDisabled else { return }
        samplePreviewGeneration += 1
        let token = samplePreviewGeneration
        samplePreviewBusy = true
        sampleProblem = nil
        Task {
            do {
                let sample = try await Task.detached(priority: .userInitiated) { try AudioImporter.load(url) }.value
                guard token == self.samplePreviewGeneration else { return }
                self.audio.stop()
                try self.audio.play(sample)
                self.samplePreviewBusy = false
            } catch {
                guard token == self.samplePreviewGeneration else { return }
                self.samplePreviewBusy = false
                self.sampleProblem = "Écoute impossible : \(error.localizedDescription)"
            }
        }
    }

    func assignChosenSample() {
        if let url = chosenSampleURL { assignSample(url) }
    }

    func assignSample(_ url: URL) {
        guard !documentActionsDisabled else { return }
        samplePreviewGeneration += 1
        samplePreviewBusy = false
        audio.stop()
        importURLs([url], atPad: selectedPad)
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
                self.programURL = url
                self.localSaveURL = self.localStore.contains(url) ? url : nil
                self.resetHistory()
                self.lastExportURL = nil
                self.kitName = url.deletingPathExtension().lastPathComponent
                self.isDirty = false
                self.busy = false
                self.selectPad(0)
                self.bank = 0
                let trailing = loaded.sounds.values.reduce(0) { $0 + $1.trailingByteCount }
                self.status = loaded.missing.isEmpty ? (trailing > 0 ?
                    "Programme .PGM ouvert. \(trailing) octets hors PCM seront omis à l’enregistrement et à la copie." :
                    "Programme .PGM ouvert. Les fichiers d’origine restent intacts ; ⌘S l’enregistre sur le Mac.") :
                    "Sons indisponibles : \(loaded.missing.joined(separator: ", ")). L’enregistrement et la copie exigent tous les samples du .PGM."
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
        program = MPCProgram.blank(name: "NEWPROG")
        sounds = [:]
        audioRangeReports = [:]
        kitName = "NEWPROG"
        programURL = nil
        localSaveURL = nil
        resetHistory()
        lastExportURL = nil
        bank = 0
        selectedPad = 0
        sound = nil
        isDirty = false
        errorMessage = nil
        status = "Nouveau .PGM. Importe des WAV, AIFF ou SND sur les pads."
    }

    func selectPad(_ index: Int) {
        guard !documentActionsDisabled, (0..<64).contains(index) else { return }
        if selectedPad != index { history.endCoalescing() }
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

    func padHasSound(index: Int) -> Bool {
        guard let program, (0..<64).contains(index) else { return false }
        return program.slot(forNote: program.midiNote(forPad: index)) != nil
    }

    static func padLabel(_ index: Int) -> String {
        String(format: "%@%02d", String(UnicodeScalar(65 + index / 16)!), index % 16 + 1)
    }

    /// Pads that play the same sample slot: name, trim and processing edit all of them,
    /// while tuning stays per pad. Copying an assignment creates such a share.
    func padsSharingSample(with index: Int) -> [Int] {
        guard let program, (0..<64).contains(index),
              let slot = program.slot(forNote: program.midiNote(forPad: index)) else { return [] }
        return (0..<64).filter { $0 != index && program.slot(forNote: program.midiNote(forPad: $0)) == slot }
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
                self.status = "Import interrompu ; le .PGM est conservé."
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
        status = "Dépôt annulé ; le .PGM et ses modifications sont conservés."
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
                throw StudioError.message("Le programme utilise déjà 128 samples.")
            }
            let retainedBytes = referenced.reduce(0) { sum, existing in
                if replacesExclusive && existing == old { return sum }
                guard let sample = pool[existing] else { return sum }
                return sum + sample.frameCount * sample.channels.count * 2
            }
            let remaining = maximumPCMBytes - retainedBytes
            guard remaining > 0 else {
                throw StudioError.message("L’import ferait dépasser 32 Mio de mémoire PCM.")
            }
            let sample = try loadAudio(url, remaining)
            let sampleBytes = sample.frameCount * sample.channels.count * 2
            guard sampleBytes <= remaining else {
                throw StudioError.message("L’import ferait dépasser 32 Mio de mémoire PCM.")
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
            self.recordEdit("Importer des samples")
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
            self.status = "Import interrompu ; le .PGM est conservé."
        }
    }

    func setKitName(_ value: String) {
        guard !documentActionsDisabled, value != kitName else { return }
        recordEdit("Renommer le .PGM", coalescingKey: "programName")
        kitName = value
        program?.name = value
        isDirty = true
    }

    func setSoundName(_ name: String) {
        guard !documentActionsDisabled, var sample = sound, sample.name != name, var updated = program,
              let slot = updated.slot(forNote: updated.midiNote(forPad: selectedPad)) else { return }
        recordEdit("Renommer le sample", coalescingKey: "sampleName-\(selectedPad)")
        sample.name = name
        updated.setSound(slot: slot, name: name, wordCount: sample.frameCount * sample.channels.count)
        program = updated
        replaceSelected(sample, updateRangeReport: false)
    }

    func setTrim(start: Int, end: Int) {
        guard !documentActionsDisabled, var sample = sound else { return }
        let lo = min(max(0, start), max(0, sample.frameCount - 1))
        let hi = min(sample.frameCount, max(lo + 1, end))
        guard sample.start != lo || sample.end != hi else { return }
        recordEdit("Régler la découpe", coalescingKey: "trim-\(selectedPad)")
        sample.start = lo
        sample.end = hi
        replaceSelected(sample, updateRangeReport: false)
    }

    func transform(_ kind: String) {
        guard !documentActionsDisabled, let sound else { return }
        switch kind {
        case "trim":
            guard sound.end - sound.start >= 441 else {
                errorMessage = "La découpe doit conserver au moins 441 échantillons (10 ms)."
                return
            }
            recordEdit("Découper le sample")
            replaceSelected(sound.trimmed())
        case "normalize": recordEdit("Normaliser le sample"); replaceSelected(sound.normalized())
        case "mono": recordEdit("Convertir en mono"); replaceSelected(sound.mono())
        case "fade": recordEdit("Appliquer le fondu"); replaceSelected(sound.faded(milliseconds: 3))
        case "reverse":
            recordEdit("Inverser le sample")
            var copy = sound
            copy.channels = sound.channels.map { Array($0.reversed()) }
            copy.start = sound.frameCount - sound.end
            copy.end = sound.frameCount - sound.start
            replaceSelected(copy)
        default: return
        }
        status = "Sample modifié · ⌘S pour enregistrer sur le Mac."
    }

    func setPadTune(_ value: Int) {
        guard !documentActionsDisabled, var updated = program else { return }
        let tune = min(120, max(-120, value))
        guard tune != padTune else { return }
        recordEdit("Accorder le pad", coalescingKey: "tune-\(selectedPad)")
        updated.setTune(tune, forNote: updated.midiNote(forPad: selectedPad))
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
        cancelExportDestinationValidation()
        exportDestinationURL = partition.url
        exportDestinationReceipt = partition.isEmpty ? receipt.requiringEmpty() : receipt
    }

    @discardableResult
    func selectExportFolder(_ url: URL) -> Task<Void, Never>? {
        guard !documentLocked else { return nil }
        cancelExportDestinationValidation()
        let selected = url.standardizedFileURL
        let token = exportDestinationValidationGeneration
        let capture = exportDestinationCapture
        exportDestinationURL = selected
        // Never leave the previous selection's receipt usable while probing a new one.
        exportDestinationReceipt = nil
        validatingExportDestination = true
        errorMessage = nil
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                // Path traversal and volume probes can block in the kernel. Their
                // completion is detached from both the main actor and the panel callback.
                let receipt = try await Task.detached(priority: .userInitiated) { try capture(selected) }.value
                guard let self, token == self.exportDestinationValidationGeneration,
                      self.validatingExportDestination, self.exportDestinationURL == selected else { return }
                guard receipt.url.standardizedFileURL == selected else { throw ExportDestinationError.changed }
                self.exportDestinationReceipt = receipt
                self.validatingExportDestination = false
                self.exportDestinationValidationTask = nil
            } catch {
                guard let self, token == self.exportDestinationValidationGeneration,
                      self.validatingExportDestination else { return }
                self.validatingExportDestination = false
                self.exportDestinationValidationTask = nil
                self.errorMessage = error.localizedDescription
            }
        }
        exportDestinationValidationTask = task
        return task
    }

    /// Releases the UI immediately. Task cancellation does not interrupt a native
    /// filesystem syscall already in progress; its eventual result is ignored.
    func cancelExportDestinationValidation() {
        exportDestinationValidationGeneration += 1
        exportDestinationValidationTask?.cancel()
        exportDestinationValidationTask = nil
        if validatingExportDestination {
            exportDestinationURL = nil
            exportDestinationReceipt = nil
        }
        validatingExportDestination = false
    }

    func cancelExportDialog() {
        cancelExportDestinationValidation()
        showExportSheet = false
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
            status = "L’export attend ta décision sur le niveau des samples ; le .PGM est conservé."
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
                self.lastExportURL = output
                self.selectedLocation = nil
                if LibraryIndex.partitionLetter(for: destination) == nil && !self.kitFolders.contains(destination) {
                    self.kitFolders.append(destination)
                    self.persistFolderLists()
                }
                self.status = "Export terminé · \(self.sampleLocationLabel(for: output)) · \(output.lastPathComponent)."
                self.refreshLocations()
            } catch {
                self.busy = false
                self.errorMessage = error.localizedDescription
                self.status = "L’export n’a pas abouti ; le .PGM est conservé."
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
        guard let oldSlot = updated.slot(forNote: note) else { return }
        recordEdit("Vider le pad")
        updated.assign(slot: nil, toNote: note)
        if !updated.referencedSlots.contains(oldSlot) {
            sounds.removeValue(forKey: oldSlot)
            audioRangeReports.removeValue(forKey: oldSlot)
            updated.setSound(slot: oldSlot, name: "", wordCount: 0)
        }
        program = updated
        sound = nil
        isDirty = true
    }

    private var documentState: StudioDocumentState {
        StudioDocumentState(program: program, sounds: sounds, reports: audioRangeReports,
                            name: kitName, selectedPad: selectedPad, revision: revision)
    }

    private func resetHistory() {
        history = DocumentHistory()
        revision = UUID()
        savedRevision = revision
    }

    private func recordEdit(_ title: String, coalescingKey: String? = nil) {
        history.record(documentState, title: title, coalescingKey: coalescingKey)
        revision = UUID()
    }

    var canUndo: Bool { !documentActionsDisabled && history.undoTitle != nil }
    var canRedo: Bool { !documentActionsDisabled && history.redoTitle != nil }
    var undoTitle: String { history.undoTitle.map { "Annuler · \($0)" } ?? "Annuler" }
    var redoTitle: String { history.redoTitle.map { "Rétablir · \($0)" } ?? "Rétablir" }

    func undo() {
        guard canUndo, let state = history.undo(documentState) else { return }
        restore(state)
        status = "Modification annulée."
    }

    func redo() {
        guard canRedo, let state = history.redo(documentState) else { return }
        restore(state)
        status = "Modification rétablie."
    }

    private func restore(_ state: StudioDocumentState) {
        stop()
        program = state.program
        sounds = state.sounds
        audioRangeReports = state.reports
        kitName = state.name
        selectedPad = state.selectedPad
        bank = selectedPad / 16
        revision = state.revision
        isDirty = revision != savedRevision
        errorMessage = nil
        updateSound()
    }

    func padTransfer(from source: Int, to destination: Int, copy: Bool = false) {
        guard !documentActionsDisabled, source != destination, var updated = program else { return }
        do {
            try updated.transferPad(from: source, to: destination, copy: copy)
            recordEdit(copy ? "Copier l’affectation" : "Déplacer les pads")
            program = updated
            // Copy may replace the last reference to the destination's old sound.
            let references = updated.referencedSlots
            sounds = sounds.filter { references.contains($0.key) }
            audioRangeReports = audioRangeReports.filter { references.contains($0.key) }
            selectPad(destination)
            isDirty = true
            stop()
            status = copy ? "Affectation copiée ; les deux pads partagent le même sample."
                : "Pads réorganisés · ⌘Z pour annuler."
        } catch { errorMessage = error.localizedDescription }
    }

    private struct PadDrag: Codable {
        let session: UUID
        let revision: UUID
        let pad: Int
    }
    static let padDragType = "com.nicolasrewolf.mpckitstudio.pad"

    func padDragProvider(index: Int) -> NSItemProvider? {
        guard !documentActionsDisabled, let program, (0..<64).contains(index),
              program.slot(forNote: program.midiNote(forPad: index)) != nil,
              let data = try? JSONEncoder().encode(PadDrag(session: padDragSession, revision: revision, pad: index)) else { return nil }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: Self.padDragType, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    func dropPads(providers: [NSItemProvider], onPad: Int) -> Bool {
        guard !documentActionsDisabled, (0..<64).contains(onPad), providers.count == 1,
              let provider = providers.first, provider.hasItemConformingToTypeIdentifier(Self.padDragType) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: Self.padDragType) { [weak self] data, _ in
            guard let data, let drag = try? JSONDecoder().decode(PadDrag.self, from: data) else { return }
            Task { @MainActor in
                guard let self, drag.session == self.padDragSession, drag.revision == self.revision else { return }
                self.padTransfer(from: drag.pad, to: onPad)
            }
        }
        return true
    }

    @discardableResult
    func saveProgram() -> Task<Void, Never>? { saveProgram(completion: { _ in }) }

    @discardableResult
    private func saveProgram(completion: @escaping (Bool) -> Void) -> Task<Void, Never>? {
        guard !documentActionsDisabled, let program else { completion(false); return nil }
        if !isDirty, let localSaveURL, localStore.contains(localSaveURL) {
            status = "Le .PGM est déjà enregistré sur le Mac."
            completion(true)
            return nil
        }
        if let issue = exportAudioIssue {
            errorMessage = issue
            completion(false)
            return nil
        }
        let store = localStore
        let pool = sounds
        let name = kitName
        let previous = localSaveURL
        let savedState = revision
        busy = true
        stop()
        errorMessage = nil
        status = "Enregistrement sur le Mac…"
        return Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try store.save(program: program, sounds: pool, name: name, existingProgramURL: previous)
                }.value
                self.localSaveURL = output
                self.programURL = output
                self.selectedLocation = nil
                if case .program(let viewed) = self.sampleScope, viewed.url == previous {
                    self.sampleScope = .program(LibraryKit(url: output, rootURL: store.rootURL,
                                                          partitionLetter: nil, relativeFolder: ""))
                }
                self.savedRevision = savedState
                self.history.endCoalescing()
                self.isDirty = self.revision != savedState
                self.busy = false
                self.status = "\(output.lastPathComponent) enregistré dans la bibliothèque sur le Mac."
                self.refreshLocations()
                completion(true)
            } catch {
                self.busy = false
                self.errorMessage = error.localizedDescription
                self.status = "Enregistrement interrompu ; tes modifications restent en mémoire."
                completion(false)
            }
        }
    }

    var canGoBackInSamples: Bool { !sampleHistory.isEmpty }

    private func rememberSampleNavigation() {
        sampleHistory.append(SampleNavigation(scope: sampleScope, root: selectedSampleRoot,
                                              folder: sampleFolder, query: sampleQuery, selection: selectedSampleURL))
        if sampleHistory.count > 30 { sampleHistory.removeFirst() }
    }

    func goBackInSamples() {
        guard let previous = sampleHistory.popLast() else { return }
        sampleBrowseGeneration += 1
        stop()
        sampleScope = previous.scope
        selectedSampleRoot = previous.root
        sampleFolder = previous.folder
        sampleQuery = previous.query
        selectedSampleURL = previous.selection
        scheduleSampleSearch()
        if let folder = previous.folder {
            _ = loadSamplesFolder(folder, preservingSelection: true)
        } else {
            sampleListing = LibraryFolderListing(folders: [], samples: [], issue: nil)
            updateScopedSampleSelection()
        }
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
        let decide: (UnsavedDecision) -> Void = { [weak self] decision in
            guard let self, self.awaitingDiscardConfirmation else { return }
            self.awaitingDiscardConfirmation = false
            switch decision {
            case .save: self.saveProgram(completion: completion)
            case .discard: completion(true)
            case .cancel: completion(false)
            }
        }
        if let unsavedPresenter { unsavedPresenter(decide); return }
        if let discardPresenter { discardPresenter { decide($0 ? .discard : .cancel) }; return }
        let alert = NSAlert()
        alert.messageText = "Enregistrer les modifications de \(kitName).PGM ?"
        alert.informativeText = "Le .PGM et ses samples seront conservés dans la bibliothèque sur le Mac."
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Abandonner les modifications")
        alert.addButton(withTitle: "Annuler")
        alert.buttons[1].hasDestructiveAction = true
        alert.buttons[2].keyEquivalent = "\u{1b}"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            decide(response == .alertFirstButtonReturn ? .save :
                    response == .alertSecondButtonReturn ? .discard : .cancel)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
