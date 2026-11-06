import AppKit
import MPCCore
import SwiftUI

struct LibraryBrowser: View {
    @EnvironmentObject private var model: StudioModel
    @FocusState private var sampleListFocused: Bool
    @State private var linksSample: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("Bibliothèque", selection: $model.libraryMode) {
                    Text(".PGM").tag(LibraryMode.kits)
                    Text("Samples").tag(LibraryMode.samples)
                    Text("PART").tag(LibraryMode.parts)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.libraryScanning {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Actualisation de la bibliothèque")
                }
            }

            switch model.libraryMode {
            case .kits: kitBrowser
            case .samples: sampleBrowser
            case .parts: partitionBrowser
            }
        }
        .padding(12)
        .background(StudioPalette.inset)
    }

    private var partitionBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.partitions.isEmpty {
                LibraryEmptyState(symbol: "sdcard", title: "Aucune PART montée",
                                  detail: "Branche la SD pour retrouver ses .PGM et ses samples.")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !model.emptyParts.isEmpty {
                        EmptyPartsSummary(parts: model.emptyParts, capacity: model.emptyPartCapacityBytes)
                    }
                    ForEach(model.partsWithContent, id: \.url) { partition in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("PART \(partition.letter)", systemImage: "sdcard")
                                    .font(.callout.weight(.semibold))
                                Spacer()
                                if !partition.issues.isEmpty {
                                    Label("À vérifier", systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.yellow)
                                        .help(partition.issues.joined(separator: "\n"))
                                }
                            }
                            if let available = partition.availableBytes {
                                PartFillBar(available: available, capacity: model.emptyPartCapacityBytes)
                            }
                            if !partition.kits.isEmpty {
                                Text(partition.kits.map { $0.url.lastPathComponent }.joined(separator: " · "))
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if !partition.issues.isEmpty {
                                Text("Aucun .PGM visible · inventaire incomplet")
                                    .font(.caption).foregroundStyle(StudioPalette.muted)
                            }
                            if let metadata = partition.macOSMetadata, let summary = Self.macOSSummary(metadata) {
                                Label(summary, systemImage: "applelogo")
                                    .font(.caption)
                                    .foregroundStyle(StudioPalette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help("Créés par macOS quand la carte est montée : copies du Finder (._), index et corbeille. Ils occupent des grappes de la PART. Kit Studio n’en crée pas et ne les supprime pas.\nDossiers système : \(metadata.systemFolders.joined(separator: ", "))")
                            }
                            let otherFiles = max(0, partition.fileCount - partition.kits.count - partition.audioCount)
                            if otherFiles > 0 || partition.folderCount > 0 {
                                Text("\(otherFiles) autre(s) fichier(s) · \(partition.folderCount) dossier(s)")
                                    .font(.caption).foregroundStyle(StudioPalette.muted)
                                    .help("Dont \(partition.sequenceCount) séquence(s) .SEQ. Ces fichiers occupent aussi la PART.")
                            }
                            HStack {
                                Button("\(partition.kits.count) .PGM") { model.showPrograms(in: partition) }
                                    .accessibilityLabel("Voir les .PGM de PART \(partition.letter)")
                                Button("\(partition.audioCount) samples") { model.showSamples(in: partition) }
                                    .accessibilityLabel("Voir les samples de PART \(partition.letter)")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// `.fseventsd` exists on every mounted PART; only what costs or blocks is shown inline.
    static func macOSSummary(_ metadata: MacOSMetadata) -> String? {
        var parts: [String] = []
        if metadata.appleDoubleCount > 0 {
            let size = ByteCountFormatter.string(fromByteCount: metadata.appleDoubleBytes, countStyle: .file)
            parts.append("\(metadata.appleDoubleCount) fichier\(metadata.appleDoubleCount > 1 ? "s" : "") ._ (\(size))")
        }
        parts += metadata.systemFolders.filter { $0 != ".fseventsd" }
        guard !parts.isEmpty else { return nil }
        return "macOS : " + parts.joined(separator: " · ") + (metadata.isComplete ? "" : " · relevé incomplet")
    }

    private var kitBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Tous les .PGM", action: model.showAllKits)
                    .buttonStyle(.borderless)
                    .foregroundStyle(model.selectedLocation == nil ? StudioPalette.orange : Color.primary)
                Spacer()
                Menu {
                    ForEach(
                        model.locations.filter { location in !model.partitions.contains { $0.url == location } }, id: \.self
                    ) { folder in
                        Button(folder.lastPathComponent) { model.selectLocation(folder) }
                            .help(folder.path)
                    }
                    Divider()
                    Button("Ajouter un dossier de .PGM…", action: model.chooseFolder)
                    if !model.addedKitFolders.isEmpty {
                        Menu("Retirer de la liste") {
                            ForEach(model.addedKitFolders, id: \.self) { folder in
                                Button(folder.lastPathComponent) { model.removeKitFolder(folder) }
                                    .help("\(folder.path)\nLes fichiers restent sur le disque.")
                            }
                        }
                        .disabled(model.documentLocked)
                    }
                } label: {
                    Label("Dossiers", systemImage: "folder")
                }
                .help("Parcourir les dossiers de .PGM ajoutés")
            }
            TextField("Rechercher un .PGM ou une PART", text: $model.kitSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Rechercher un .PGM ou une PART")
            HStack(spacing: 6) {
                Text("\(model.filteredKits.count) .PGM")
                inventoryBadge
                Spacer()
                if let location = model.selectedLocation {
                    Text(location.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(location.path)
                }
            }
            .font(.caption)
            .foregroundStyle(StudioPalette.muted)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 5, pinnedViews: [.sectionHeaders]) {
                        if model.filteredKits.isEmpty {
                            LibraryEmptyState(
                                symbol: "square.grid.3x3",
                                title: model.libraryContentIssue == nil ? "Aucun .PGM dans cette vue" : "Aucun .PGM visible dans cette vue",
                                detail: model.libraryContentIssue == nil
                                    ? "Choisis une autre PART, affiche tous les .PGM ou ajoute un dossier."
                                    : "Actualise la bibliothèque pour vérifier les fichiers accessibles."
                            )
                        }
                        ForEach(model.groupedFilteredKits) { group in
                        Section {
                        ForEach(group.kits, id: \.url) { kit in
                            HStack(spacing: 0) {
                                BrowserRow(
                                    title: kit.title,
                                    subtitle: model.kitRowSubtitle(for: kit),
                                    symbol: "square.grid.3x3",
                                    selected: (model.localSaveURL ?? model.programURL) == kit.url,
                                    path: kit.url.path + (model.kitTitleOnMPC(for: kit).map { "\nTitre sur la MPC : \($0)" } ?? "")
                                ) { model.openProgram(kit.url) }
                                .accessibilityLabel("\(kit.title), \(model.libraryLocationLabel(for: kit))")
                                .accessibilityHint("Ouvrir ce programme MPC")
                                Button { model.showSamples(in: kit) } label: {
                                    Image(systemName: "list.bullet")
                                }
                                .buttonStyle(.borderless)
                                .frame(width: 28)
                                .help("Voir les samples de \(kit.url.lastPathComponent) · \(model.libraryLocationLabel(for: kit))")
                                .accessibilityLabel("Voir les samples de \(kit.url.lastPathComponent), \(model.libraryLocationLabel(for: kit))")
                                Menu {
                                    kitActions(kit)
                                } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .frame(width: 28)
                                .help("Actions pour \(kit.url.lastPathComponent)")
                                .accessibilityLabel("Actions pour \(kit.title), \(model.libraryLocationLabel(for: kit))")
                            }
                            .id(kit.url)
                            .disabled(model.documentActionsDisabled)
                            .contextMenu { kitActions(kit) }
                        }
                        } header: {
                            KitGroupHeader(title: group.title, count: group.kits.count)
                        }
                        }
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.visible)
                .onChange(of: model.libraryKits) { _ in
                    if let url = model.localSaveURL ?? model.programURL {
                        proxy.scrollTo(url, anchor: .center)
                    }
                }
                .onChange(of: model.localSaveURL) { url in
                    if let url { proxy.scrollTo(url, anchor: .center) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// An inventory caveat is one icon beside the count; its explanation is the tooltip.
    @ViewBuilder
    private var inventoryBadge: some View {
        let folderScope = model.libraryMode == .samples && model.sampleScope == .folder
        if let issue = folderScope ? model.sampleFolderIssue : (model.libraryContentIssue ?? model.libraryIssue) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
                .help("\(model.libraryInventoryWarningTitle). \(model.libraryInventoryWarningDetail)\n\n\(issue)")
                .accessibilityLabel(model.libraryInventoryWarningTitle)
        }
    }

    @ViewBuilder
    private func kitActions(_ kit: LibraryKit) -> some View {
        Button("Voir les samples") { model.showSamples(in: kit) }
        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([kit.url]) }
        if model.trashRefusal(for: kit) == nil {
            Button("Mettre le programme à la corbeille…", role: .destructive) {
                model.requestTrashKit(kit)
            }
            .disabled(model.documentActionsDisabled)
        } else {
            Button("Corbeille indisponible sur la SD") {}
                .disabled(true)
        }
    }

    private var sampleBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            samplePlaces
            Divider().opacity(0.6)
            if model.selectedSamplePlace == nil || model.canGoUpSamples {
                HStack(spacing: 7) {
                    if model.canGoBackInSamples {
                        Button(action: model.goBackInSamples) { Image(systemName: "chevron.backward") }
                            .buttonStyle(.borderless)
                            .help("Revenir à la vue de samples précédente")
                            .accessibilityLabel("Retour aux samples précédents")
                    }
                    if model.canGoUpSamples {
                        Button(action: model.sampleGoUp) { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless)
                            .help("Ouvrir le dossier parent")
                            .accessibilityLabel("Dossier parent")
                    }
                    Text(model.sampleScopeTitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.sampleFolder?.path ?? model.sampleScopeTitle)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 6) {
                TextField(searchPrompt, text: $model.sampleQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(searchPrompt)
                Button { model.autoPreviewSamples.toggle() } label: {
                    Image(systemName: "headphones")
                        .foregroundStyle(model.autoPreviewSamples ? StudioPalette.orange : StudioPalette.muted)
                }
                .buttonStyle(.borderless)
                .help(model.autoPreviewSamples ? "Écoute en parcourant avec ↑ ↓ : activée" : "Écouter en parcourant avec ↑ ↓")
                .accessibilityLabel("Écouter en parcourant")
                .accessibilityValue(model.autoPreviewSamples ? "activée" : "désactivée")
            }
            if let line = sampleCountLine {
                HStack(spacing: 6) {
                    if model.sampleSearchInProgress { ProgressView().controlSize(.mini) }
                    Text(line)
                    inventoryBadge
                }
                .font(.caption)
                .foregroundStyle(StudioPalette.muted)
            }
            if model.sampleScope == .folder && !model.isSampleTreeSearch {
                sampleTree
            } else {
                sampleFileList
            }
            sampleActions
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var searchPrompt: String {
        guard model.sampleScope == .folder, let folder = model.sampleFolder ?? model.selectedSampleRoot else {
            return "Rechercher dans cette vue"
        }
        return "Rechercher dans \(folder.lastPathComponent)"
    }

    /// The tree speaks only when asked: a search answer or a list that is not a tree.
    private var sampleCountLine: String? {
        if model.isSampleTreeSearch {
            if model.sampleSearchInProgress { return "Recherche…" }
            let count = model.filteredSamples.count
            return model.sampleSearchTruncated ? "\(count)+ résultats · précise ta recherche" : Self.count(count, "résultat")
        }
        if model.sampleScope == .folder { return model.libraryContentIssue == nil ? nil : "Dossier à vérifier" }
        return Self.count(model.filteredSamples.count, "sample")
    }

    /// Like a DAW browser: the sources stay in view, one click opens one.
    private var samplePlaces: some View {
        VStack(alignment: .leading, spacing: 1) {
            let place = model.selectedSamplePlace
            PlaceRow(title: "Bibliothèque et SD", symbol: "square.stack", detail: nil,
                     selected: place == .library, help: "Les samples de la bibliothèque sur le Mac et de la SD",
                     action: model.showAllLibrarySamples)
            if !model.partitions.isEmpty {
                PlaceRow(title: "Carte SD", symbol: "sdcard",
                         detail: "\(model.partsWithContent.count) PART",
                         selected: place == .sd, help: "Les samples de la SD, rangés par PART",
                         action: model.showAllSDSamples)
            }
            ForEach(model.sampleRoots, id: \.self) { root in
                PlaceRow(title: root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent,
                         symbol: Self.volumeName(of: root) == nil ? "folder" : "externaldrive",
                         detail: Self.volumeName(of: root),
                         selected: place == .root(root.standardizedFileURL), help: root.path) {
                    model.selectSampleRoot(root)
                }
                .contextMenu {
                    Button("Afficher dans le Finder") { model.revealInFinder(root) }
                    Button("Retirer de la liste") { model.removeSampleRoot(root) }
                        .disabled(model.documentLocked)
                }
            }
            Button(action: model.chooseSampleFolder) {
                Label("Ajouter un dossier…", systemImage: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioPalette.muted)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
            }
            .buttonStyle(.plain)
            .disabled(model.documentLocked)
            .help("Ajouter un dossier de samples, par exemple sur ton SSD")
        }
    }

    /// "/Volumes/T9/…" → "T9"; a folder of the Mac's own disk has no volume to name.
    static func volumeName(of url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return nil }
        return components[2]
    }

    private var sampleTree: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let rows = model.sampleTreeRows
                    if rows.isEmpty && model.sampleFolderReading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Lecture du dossier…").font(.caption).foregroundStyle(StudioPalette.muted)
                        }
                        .padding(.vertical, 14)
                    } else if rows.isEmpty {
                        LibraryEmptyState(
                            symbol: "folder",
                            title: model.sampleListing.issue == nil ? "Dossier vide" : "Dossier indisponible",
                            detail: model.sampleListing.issue ?? "Aucun sample ni sous-dossier ici."
                        )
                    }
                    ForEach(rows) { row in
                        SampleTreeRowView(row: row, selected: row.kind == .sample && model.selectedSampleURL == row.url) {
                            switch row.kind {
                            case .folder: model.toggleSampleFolder(row.url)
                            case .sample: model.playSample(row.url)
                            case .notice: break
                            }
                            sampleListFocused = true
                        }
                        .id(row.id)
                        .modifier(SampleRowDrag(url: row.kind == .sample ? row.url : nil))
                        .contextMenu {
                            if row.kind == .sample {
                                Button("Affecter au pad \(model.selectedLabel)") { model.assignSample(row.url) }
                                    .disabled(model.program == nil || model.documentActionsDisabled)
                            }
                            if !row.isNotice { Button("Afficher dans le Finder") { model.revealInFinder(row.url) } }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.visible)
            .focusable()
            .modifier(NoFocusRing())
            .focused($sampleListFocused)
            .onMoveCommand { direction in
                switch direction {
                case .up: model.moveSampleSelection(by: -1)
                case .down: model.moveSampleSelection(by: 1)
                default: break
                }
            }
            .onChange(of: model.selectedSampleURL) { url in
                if let url { proxy.scrollTo(url.path) }
            }
        }
    }

    private var sampleFileList: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                if model.filteredSamples.isEmpty && !model.sampleSearchInProgress {
                    LibraryEmptyState(
                        symbol: "waveform",
                        title: model.isSampleTreeSearch ? "Aucun sample trouvé"
                            : (model.libraryContentIssue == nil ? "Aucun sample dans cette vue" : "Aucun sample visible dans cette vue"),
                        detail: model.isSampleTreeSearch
                            ? "Chaque mot cherché doit apparaître dans le nom du sample ou de ses dossiers."
                            : (model.libraryContentIssue == nil
                                ? "Choisis une autre source ou ajoute un dossier de ton SSD."
                                : "Actualise la bibliothèque pour vérifier les fichiers accessibles.")
                    )
                }
                let groups = model.groupedFilteredSamples
                ForEach(groups) { group in
                    Section {
                        ForEach(group.samples, id: \.self) { sample in
                            sampleRow(sample)
                        }
                    } header: {
                        if groups.count > 1 {
                            KitGroupHeader(title: group.title, count: group.samples.count, unit: "sample")
                        }
                    }
                }
            }
            .padding(.trailing, 4)
        }
        .scrollIndicators(.visible)
        .focusable()
        .modifier(NoFocusRing())
        .focused($sampleListFocused)
        .onMoveCommand { direction in
            switch direction {
            case .up: model.moveSampleSelection(by: -1)
            case .down: model.moveSampleSelection(by: 1)
            default: break
            }
        }
        .onChange(of: model.selectedSampleURL) { url in
            if let url { proxy.scrollTo(url) }
        }
        }
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value > 1 ? "s" : "")"
    }

    @ViewBuilder
    private func sampleRow(_ sample: URL) -> some View {
        let selected = model.selectedSampleURL == sample
        HStack(spacing: 0) {
            BrowserRow(title: sample.lastPathComponent, subtitle: "", symbol: "waveform",
                       selected: selected, path: sample.path) {
                model.playSample(sample)
                sampleListFocused = true
            }
            .onDrag { NSItemProvider(object: sample as NSURL) }
            .accessibilityHint("Écouter ; glisser vers un pad pour l’affecter")
            if selected {
                Button { linksSample = sample } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .frame(width: 28)
                    .help("Où ce sample est utilisé")
                    .accessibilityLabel("Où \(sample.lastPathComponent) est utilisé")
                    .popover(isPresented: Binding(get: { linksSample == sample },
                                                  set: { if !$0 { linksSample = nil } }),
                             arrowEdge: .trailing) {
                        SampleLinksPopover(sample: sample).environmentObject(model)
                    }
            }
        }
    }

    private var sampleActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let sample = model.selectedSampleURL { model.assignSample(sample) }
            } label: {
                Label("Affecter au pad \(model.selectedLabel)", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioProminentButtonStyle())
            .disabled(
                model.selectedSampleURL == nil || model.program == nil || model.documentActionsDisabled
                    || model.samplePreviewBusy
            )
            .help("Importer le sample sélectionné sur le pad \(model.selectedLabel) du .PGM en cours")
            if let problem = model.sampleBrowserProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .lineLimit(2)
                    .help(problem)
            }
        }
    }
}

/// Where a sample is used, asked for with its ⓘ button instead of shown permanently.
private struct SampleLinksPopover: View {
    @EnvironmentObject private var model: StudioModel
    let sample: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sample.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
            Text(model.sampleLocationLabel(for: sample))
                .font(.caption).foregroundStyle(StudioPalette.muted)
            Text("Utilisé par")
                .font(.caption.weight(.semibold))
            let programs = model.programsUsingSample(sample)
            if programs.isEmpty {
                Text(model.libraryScanning ? "Lecture des liens en cours…" : "Aucun lien trouvé dans les .PGM lus.")
                    .font(.caption)
                    .foregroundStyle(StudioPalette.muted)
            } else {
                ForEach(programs, id: \.url) { program in
                    Button { model.openProgram(program.url) } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(program.url.lastPathComponent).fontWeight(.medium)
                                Text(model.libraryLocationLabel(for: program)).foregroundStyle(StudioPalette.muted)
                            }
                            Spacer(minLength: 0)
                            Text("Ouvrir").foregroundStyle(StudioPalette.orange)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Ouvrir \(program.url.path)")
                    .disabled(model.documentActionsDisabled)
                }
            }
            if let notice = model.selectedSampleAssociationNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(StudioPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

/// Empty PARTs carry nothing to browse: one line names them and their capacity.
private struct EmptyPartsSummary: View {
    let parts: [LibraryPartition]
    let capacity: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("\(parts.count) PART vide\(parts.count > 1 ? "s" : "")", systemImage: "sdcard")
                    .font(.callout.weight(.semibold))
                Spacer()
                if let capacity {
                    Text("\(ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)) \(parts.count > 1 ? "chacune" : "")")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.muted)
                }
            }
            Text(parts.map(\.letter).joined(separator: " · "))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .help("Sans fichier visible et vérifiées : « Copier sur la SD… » propose la première qui peut recevoir la bank.")
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

/// Free space of a PART against an empty one, so a bank's room is visible at a glance.
private struct PartFillBar: View {
    let available: Int64
    let capacity: Int64?

    private var used: Double? {
        guard let capacity, capacity > 0 else { return nil }
        return min(1, max(0, 1 - Double(available) / Double(capacity)))
    }

    var body: some View {
        HStack(spacing: 8) {
            if let used {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule().fill(used > 0.9 ? Color.yellow : StudioPalette.orange)
                                .frame(width: geometry.size.width * max(0.02, used))
                        }
                    }
                    .frame(height: 4)
            }
            Text("\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) libres")
                .font(.caption)
                .foregroundStyle(StudioPalette.muted)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) libres")
    }
}

private struct KitGroupHeader: View {
    let title: String
    let count: Int
    var unit = ".PGM"

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1)
            Spacer()
            Text(unit == ".PGM" ? "\(count) \(unit)" : LibraryBrowser.count(count, unit))
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(StudioPalette.muted)
        .padding(.horizontal, 9)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioPalette.inset)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One source of samples in the places list.
private struct PlaceRow: View {
    let title: String
    let symbol: String
    let detail: String?
    let selected: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? StudioPalette.orange : StudioPalette.muted)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(selected ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A folder opens in place; a sample plays on click and drags onto a pad.
private struct SampleTreeRowView: View {
    let row: StudioModel.SampleTreeRow
    let selected: Bool
    let action: () -> Void

    var body: some View {
        switch row.kind {
        case .notice(let text):
            label {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(StudioPalette.muted)
                    .lineLimit(2)
                    .help(text)
            }
        case .folder(let expanded, let loading):
            Button(action: action) {
                label {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StudioPalette.muted)
                        .frame(width: 10)
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .foregroundStyle(StudioPalette.muted)
                        .frame(width: 16)
                    name
                    if loading { ProgressView().controlSize(.mini) }
                }
            }
            .buttonStyle(.plain)
            .help(row.url.path)
            .accessibilityLabel(row.name)
            .accessibilityValue(expanded ? "déplié" : "replié")
            .accessibilityHint(expanded ? "Replier ce dossier" : "Déplier ce dossier")
        case .sample:
            Button(action: action) {
                label {
                    Color.clear.frame(width: 10, height: 1)
                    Image(systemName: "waveform")
                        .foregroundStyle(selected ? StudioPalette.orange : StudioPalette.muted)
                        .frame(width: 16)
                    name
                }
            }
            .buttonStyle(.plain)
            .help(row.url.path)
            .accessibilityLabel(row.name)
            .accessibilityHint("Écouter ; glisser vers un pad pour l’affecter")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    /// Sample names often differ only in the middle ("…Snare Roll 1_CB.wav"): they get two lines.
    private var name: some View {
        Text(row.name)
            .font(.system(size: 12, weight: selected ? .medium : .regular))
            .lineLimit(row.kind == .sample ? 2 : 1)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func label<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(minHeight: 24)
        .background(selected ? StudioPalette.orange.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }
}

/// Selection already shows where the keyboard is; the blue ring only adds noise (macOS 14+).
private struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

/// Only samples are dragged onto pads; folders and notices stay put.
private struct SampleRowDrag: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.onDrag { NSItemProvider(object: url as NSURL) }
        } else {
            content
        }
    }
}

private struct BrowserRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    let path: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? StudioPalette.orange : StudioPalette.muted)
                    .frame(width: 17)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(StudioPalette.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.white.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LibraryEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(StudioPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ExportDestinationSheet: View {
    @EnvironmentObject private var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var changeDestination = false

    private var selectedPartition: LibraryPartition? {
        model.partitions.first { $0.url == model.exportDestinationURL }
    }

    private var capacityTooSmall: Bool {
        guard model.estimatedExportBytes != nil,
              let available = selectedPartition?.availableBytes else { return false }
        return selectedPartition.map { model.requiredExportFreeBytes(in: $0) > available } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Copier le .PGM sur la SD")
                    .font(.title2.bold())
                Text("Choisis où retrouver le .PGM et ses samples sur ta MPC.")
                    .font(.callout)
                    .foregroundStyle(StudioPalette.muted)
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nom du .PGM").font(.caption)
                    Text(model.kitName)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text("Titre sur la MPC : \(model.programTitle)")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.muted)
                }
                VStack(alignment: .trailing, spacing: 5) {
                    Text(model.exportSizeLabel)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    Text("\(model.assignedPadCount) pad(s) affecté(s)")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.muted)
                }
            }
            if model.exportDestinationURL == nil {
                if let capacity = model.partCapacity, !capacity.fits {
                    Text(
                        "Aucune PART proposée : ce .PGM et ses samples demandent \(ByteCountFormatter.string(fromByteCount: capacity.requiredBytes, countStyle: .file)), une PART vide en offre \(ByteCountFormatter.string(fromByteCount: capacity.capacityBytes, countStyle: .file)). Retire ou raccourcis des samples, ou choisis un dossier sur le Mac."
                    )
                    .font(.callout)
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(
                        "Aucune PART proposée. Branche la SD ou choisis un dossier pour cette copie."
                    )
                    .font(.callout)
                    .foregroundStyle(.yellow)
                }
            }
            if let issue = model.exportAudioIssue {
                VStack(alignment: .leading, spacing: 7) {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Normaliser les samples concernés", action: model.normalizeOverrangeSamples)
                        .buttonStyle(.bordered)
                        .disabled(model.documentLocked)
                }
            }
            DisclosureGroup("Changer la destination", isExpanded: $changeDestination) {
                Text("PART DE LA SD")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(StudioPalette.muted)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 5) {
                            if model.partitions.isEmpty {
                                Text("Aucune PART montée. Tu peux choisir un dossier sur le Mac.")
                                    .font(.callout)
                                    .foregroundStyle(StudioPalette.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            ForEach(model.partitions, id: \.url) { partition in
                                destinationRow(partition)
                                    .id(partition.url)
                            }
                        }
                        .padding(.trailing, 5)
                    }
                    .scrollIndicators(.visible)
                    .frame(height: 225)
                    .onAppear {
                        if let destination = model.exportDestinationURL {
                            proxy.scrollTo(destination, anchor: .center)
                        }
                    }
                }
                Button("Copier dans un dossier…", action: model.chooseExportFolder)
                    .buttonStyle(.bordered)
                    .disabled(model.documentLocked)
            }
            VStack(alignment: .leading, spacing: 5) {
                Label(model.selectedDestinationLabel, systemImage: "folder")
                    .font(.system(size: 13, weight: .medium))
                Text(model.exportDestinationURL?.path ?? "Aucune destination choisie")
                    .font(.caption)
                    .foregroundStyle(StudioPalette.muted)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .help(model.exportDestinationURL?.path ?? "")
                if capacityTooSmall {
                    Text("L’espace libre de cette PART est insuffisant pour ce .PGM et ses samples.")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                if let issue = model.exportDestinationIssue {
                    HStack(spacing: 8) {
                        if model.validatingExportDestination { ProgressView().controlSize(.small) }
                        Text(issue)
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
            }
            Text(
                "Un programme .PGM et ses sons .SND seront créés. Les fichiers existants sont conservés ; un nom libre est choisi si nécessaire."
            )
            .font(.caption)
            .foregroundStyle(StudioPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Annuler") { model.cancelExportDialog(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.documentLocked)
                Spacer()
                Button(
                    "Copier ici", action: model.exportKitToDestination
                )
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    model.exportDestinationURL == nil || model.program == nil || model.documentLocked
                        || model.exportDestinationIssue != nil || model.exportAudioIssue != nil || capacityTooSmall)
            }
        }
        .padding(24)
        .frame(width: 580)
        .onAppear { changeDestination = model.exportDestinationURL == nil }
        .onDisappear { model.cancelExportDestinationValidation() }
        .background(StudioPalette.background)
        .interactiveDismissDisabled(model.documentLocked)
    }

    private func destinationRow(_ partition: LibraryPartition) -> some View {
        let selected = model.exportDestinationURL == partition.url
        let summary =
            !partition.issues.isEmpty
            ? "À vérifier"
            : partition.isEmpty
                ? "Vide (fichiers visibles)"
                : "\(partition.kits.count) .PGM · \(partition.audioCount) sample(s)"
        let available =
            partition.availableBytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " libres"
            } ?? "Espace inconnu"
        return Button {
            model.selectExportPartition(partition)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? StudioPalette.orange : StudioPalette.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text("PART \(partition.letter)").font(.system(size: 12, weight: .semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(partition.issues.isEmpty ? StudioPalette.muted : Color.yellow)
                }
                Spacer()
                Text(available)
                    .font(.caption)
                    .foregroundStyle(StudioPalette.muted)
            }
            .padding(10)
            .background(
                selected ? StudioPalette.orange.opacity(0.10) : StudioPalette.panel,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.documentLocked || !partition.issues.isEmpty || partition.exportDestination?.isMountedMPCPartition != true)
        .help(
            partition.url.path
                + (partition.issues.isEmpty ? "" : "\n" + partition.issues.joined(separator: "\n"))
        )
        .accessibilityLabel("Destination PART \(partition.letter), \(summary), \(available)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
