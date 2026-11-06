import AppKit
import MPCCore
import SwiftUI

/// Formatting shared by the sample and .PGM columns.
enum LibraryBrowser {
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value > 1 ? "s" : "")"
    }

    /// "/Volumes/T9/…" → "T9"; a folder of the Mac's own disk has no volume to name.
    static func volumeName(of url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return nil }
        return components[2]
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
}

// MARK: - Samples, left: what the bank is built from

/// Only samples live on the left: the computer's folders above, the SD's PARTs below,
/// right beside the pads they are dragged onto.
struct SampleColumn: View {
    @EnvironmentObject private var model: StudioModel
    private enum Pane: Hashable { case computer, sd }
    @FocusState private var focus: Pane?
    @State private var linksSample: URL?
    @AppStorage("layout.sdPaneHeight") private var sdHeight: Double = 260
    @AppStorage("layout.sdPaneCollapsed") private var sdCollapsed = false
    @State private var dragOrigin: Double?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                computerPane
                    .padding(12)
                    .frame(maxHeight: .infinity, alignment: .top)
                if !sdCollapsed { splitHandle(total: geometry.size.height) }
                else { Divider() }
                sdPane
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(height: sdCollapsed ? nil : clampedSDHeight(total: geometry.size.height), alignment: .top)
                Divider()
                assignBar.padding(12)
            }
        }
        .background(StudioPalette.inset)
    }

    private func clampedSDHeight(total: CGFloat) -> CGFloat {
        min(max(120, CGFloat(sdHeight)), max(120, total - 300))
    }

    /// Drag to give the SD more or less room; the height is remembered.
    private func splitHandle(total: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(StudioPalette.border).frame(height: 1)
            Capsule().fill(Color.white.opacity(0.22)).frame(width: 36, height: 3)
        }
        .frame(height: 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
            let origin = dragOrigin ?? Double(clampedSDHeight(total: total))
            dragOrigin = origin
            sdHeight = Double(min(max(120, CGFloat(origin) - value.translation.height), max(120, total - 300)))
        }.onEnded { _ in dragOrigin = nil })
        .accessibilityElement()
        .accessibilityLabel("Séparation entre les samples de l’ordinateur et ceux de la SD")
        .accessibilityValue("\(Int(sdHeight)) points pour la SD")
        .accessibilityAdjustableAction { direction in
            sdHeight += direction == .increment ? 40 : -40
        }
    }

    // MARK: Computer

    private var computerPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            places
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
            if let line = countLine {
                HStack(spacing: 6) {
                    if model.sampleSearchInProgress { ProgressView().controlSize(.mini) }
                    Text(line)
                    IssueBadge(title: "Inventaire incomplet", issue: model.sampleBrowserIssue)
                }
                .font(.caption)
                .foregroundStyle(StudioPalette.muted)
            }
            if model.sampleScope == .folder && !model.isSampleTreeSearch {
                sampleTree
            } else {
                sampleList
            }
        }
    }

    private var searchPrompt: String {
        if model.sampleScope == .folder, let folder = model.sampleFolder ?? model.selectedSampleRoot {
            return "Rechercher dans \(folder.lastPathComponent)"
        }
        return "Rechercher dans cette vue"
    }

    private var countLine: String? {
        if model.isSampleTreeSearch {
            if model.sampleSearchInProgress { return "Recherche…" }
            let count = model.filteredSamples.count
            return model.sampleSearchTruncated ? "\(count)+ résultats · précise ta recherche" : LibraryBrowser.count(count, "résultat")
        }
        if model.sampleScope == .folder { return model.sampleBrowserIssue == nil ? nil : "Dossier à vérifier" }
        return LibraryBrowser.count(model.filteredSamples.count, "sample")
    }

    /// The computer's sources, side by side: the Mac collection, then each added folder.
    private var places: some View {
        FlowLayout(spacing: 5) {
            let place = model.selectedSamplePlace
            PlaceChip(title: "Mac", symbol: "desktopcomputer", selected: place == .library,
                      help: "Les samples des .PGM de la bibliothèque sur le Mac",
                      action: model.showAllLibrarySamples)
            ForEach(model.sampleRoots, id: \.self) { root in
                let name = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
                PlaceChip(title: LibraryBrowser.volumeName(of: root).map { "\(name) · \($0)" } ?? name,
                          symbol: LibraryBrowser.volumeName(of: root) == nil ? "folder" : "externaldrive",
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
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioPalette.muted)
                    .frame(width: 26, height: 24)
                    .overlay(Capsule().stroke(Color.white.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.documentLocked)
            .help("Ajouter un dossier de samples, par exemple sur ton SSD")
            .accessibilityLabel("Ajouter un dossier de samples")
        }
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
                            focus = .computer
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
            .focused($focus, equals: .computer)
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

    /// Search results and the Mac or .PGM views: samples grouped by their folder.
    private var sampleList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    if model.filteredSamples.isEmpty && !model.sampleSearchInProgress {
                        LibraryEmptyState(
                            symbol: "waveform",
                            title: model.isSampleTreeSearch ? "Aucun sample trouvé" : "Aucun sample dans cette vue",
                            detail: model.isSampleTreeSearch
                                ? "Chaque mot cherché doit apparaître dans le nom du sample ou de ses dossiers."
                                : (model.sampleScope == .library
                                    ? "Les samples des .PGM enregistrés sur le Mac apparaissent ici. Ajoute un dossier de ton SSD avec +."
                                    : "Choisis une autre source ou ajoute un dossier de ton SSD.")
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
            .focused($focus, equals: .computer)
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

    @ViewBuilder
    private func sampleRow(_ sample: URL) -> some View {
        let selected = model.selectedSampleURL == sample
        HStack(spacing: 0) {
            BrowserRow(title: sample.lastPathComponent, subtitle: "", symbol: "waveform",
                       selected: selected, path: sample.path) {
                model.playSample(sample)
                focus = .computer
            }
            .onDrag { NSItemProvider(object: sample as NSURL) }
            .accessibilityHint("Écouter ; glisser vers un pad pour l’affecter")
            if selected { linksButton(sample) }
        }
        .id(sample)
    }

    private func linksButton(_ sample: URL) -> some View {
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

    // MARK: SD

    private var sdPane: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { sdCollapsed.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: sdCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StudioPalette.muted)
                        .frame(width: 10)
                    Text("Samples de la SD")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(model.sdIsMounted
                         ? "\(model.sdSampleCount) · \(model.partsWithContent.filter { model.mountedPartURLs.contains($0.url) }.count) PART"
                         : "SD absente")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Samples de la SD")
            .accessibilityValue(sdCollapsed ? "replié" : "déplié")
            .overlay(alignment: .trailing) {
                IssueBadge(title: "Inventaire de la SD incomplet", issue: model.sdSamplesIssue)
                    .offset(x: 14)
            }
            if !sdCollapsed {
                if !model.sdIsMounted {
                    Text("Branche la SD pour piocher dans ses samples.")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.muted)
                        .padding(.vertical, 6)
                } else {
                    TextField("Rechercher sur la SD", text: $model.sdSampleQuery)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Rechercher dans les samples de la SD")
                    sdList
                }
            }
        }
    }

    private var sdList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let rows = model.sdSampleRows
                    if rows.isEmpty {
                        Text(model.sdSampleQuery.isEmpty ? "Aucun sample sur la SD." : "Aucun sample trouvé sur la SD.")
                            .font(.caption)
                            .foregroundStyle(StudioPalette.muted)
                            .padding(.vertical, 8)
                    }
                    ForEach(rows) { row in
                        sdRow(row).id(row.id)
                    }
                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.visible)
            .focusable()
            .modifier(NoFocusRing())
            .focused($focus, equals: .sd)
            .onMoveCommand { direction in
                switch direction {
                case .up: model.moveSDSampleSelection(by: -1)
                case .down: model.moveSDSampleSelection(by: 1)
                default: break
                }
            }
            .onChange(of: model.selectedSDSampleURL) { url in
                if let url { proxy.scrollTo(url.path) }
            }
        }
    }

    @ViewBuilder
    private func sdRow(_ row: StudioModel.SDSampleRow) -> some View {
        switch row.kind {
        case .part(let letter, let count, let expanded, let issue):
            Button { model.toggleSDPart(row.url) } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StudioPalette.muted)
                        .frame(width: 10)
                    Image(systemName: "sdcard")
                        .foregroundStyle(StudioPalette.muted)
                        .frame(width: 16)
                    Text("PART \(letter)").font(.system(size: 12, weight: .medium))
                    if issue != nil {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow).font(.caption)
                    }
                    Spacer(minLength: 4)
                    Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioPalette.muted)
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(issue.map { "PART \(letter) à vérifier :\n\($0)" } ?? "PART \(letter) · \(LibraryBrowser.count(count, "sample"))")
            .accessibilityLabel("PART \(letter), \(LibraryBrowser.count(count, "sample"))")
            .accessibilityValue(expanded ? "déplié" : "replié")
        case .sample:
            let selected = model.selectedSDSampleURL == row.url
            HStack(spacing: 0) {
                SampleTreeRowView(row: StudioModel.SampleTreeRow(id: row.id, url: row.url, depth: 1, kind: .sample),
                                  selected: selected) {
                    model.playSDSample(row.url)
                    focus = .sd
                }
                .onDrag { NSItemProvider(object: row.url as NSURL) }
                .contextMenu {
                    Button("Affecter au pad \(model.selectedLabel)") { model.assignSample(row.url) }
                        .disabled(model.program == nil || model.documentActionsDisabled)
                    Button("Afficher dans le Finder") { model.revealInFinder(row.url) }
                }
                if selected { linksButton(row.url) }
            }
        }
    }

    // MARK: Assign

    private var assignBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: model.assignChosenSample) {
                Label("Affecter au pad \(model.selectedLabel)", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioProminentButtonStyle())
            .disabled(model.chosenSampleURL == nil || model.program == nil || model.documentActionsDisabled
                      || model.samplePreviewBusy)
            .help("Importer le sample choisi sur le pad \(model.selectedLabel) du .PGM en cours ; ou glisse-le sur un pad")
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

// MARK: - .PGM, right: where the bank is kept

/// The .PGM list with a one-line PART filter: letters for the PARTs that hold
/// something, one line for the empty ones.
struct ProgramColumn: View {
    @EnvironmentObject private var model: StudioModel

    private var mountedParts: [LibraryPartition] {
        model.partsWithContent.filter { model.mountedPartURLs.contains($0.url) }
    }

    private var selectedPart: LibraryPartition? {
        guard let location = model.selectedLocation else { return nil }
        return model.partitions.first { $0.url == location }
    }

    private var selectedFolder: URL? {
        guard let location = model.selectedLocation, location != model.macLibraryURL, selectedPart == nil else { return nil }
        return location
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("\(model.filteredKits.count) .PGM")
                    .font(.system(size: 12, weight: .semibold))
                IssueBadge(title: "Inventaire incomplet", issue: model.programListIssue)
                if model.libraryScanning {
                    ProgressView().controlSize(.mini).accessibilityLabel("Actualisation de la bibliothèque")
                }
                Spacer()
                folderMenu
            }
            filters
            filterDetail
            Divider().opacity(0.6)
            programList
        }
        .padding(12)
        .background(StudioPalette.inset)
    }

    private var folderMenu: some View {
        Menu {
            ForEach(model.addedKitFolders, id: \.self) { folder in
                Button(folder.lastPathComponent) { model.filterPrograms(to: folder) }
                    .help(folder.path)
            }
            if !model.addedKitFolders.isEmpty { Divider() }
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
            Image(systemName: "folder")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Dossiers de .PGM")
        .accessibilityLabel("Dossiers de .PGM")
    }

    /// Tout · Mac · A B C D… : text only, the chosen one underlined.
    private var filters: some View {
        FlowLayout(spacing: 5, lineSpacing: 4) {
            FilterLetter(text: "Tout", selected: model.selectedLocation == nil, label: "Tous les .PGM") {
                model.filterPrograms(to: nil)
            }
            FilterLetter(text: "Mac", selected: model.selectedLocation == model.macLibraryURL, label: "Bibliothèque sur le Mac") {
                model.filterPrograms(to: model.macLibraryURL)
            }
            ForEach(mountedParts, id: \.url) { part in
                FilterLetter(text: part.letter, selected: model.selectedLocation == part.url,
                             warning: !part.issues.isEmpty, label: "PART \(part.letter)") {
                    model.filterPrograms(to: part.url)
                }
            }
            if let folder = selectedFolder {
                FilterLetter(text: folder.lastPathComponent, selected: true, label: folder.path) {}
            }
        }
    }

    @ViewBuilder
    private var filterDetail: some View {
        if let part = selectedPart {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let available = part.availableBytes {
                        PartFillBar(available: available, capacity: model.emptyPartCapacityBytes)
                    }
                    IssueBadge(title: "PART \(part.letter) à vérifier",
                               issue: part.issues.isEmpty ? nil : part.issues.joined(separator: "\n"))
                }
                if let metadata = part.macOSMetadata, let summary = LibraryBrowser.macOSSummary(metadata) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(StudioPalette.muted)
                        .lineLimit(2)
                        .help("Créés par macOS quand la carte est montée : copies du Finder (._), index et corbeille. Ils occupent des grappes de la PART. Kit Studio n’en crée pas et ne les supprime pas.")
                }
            }
        } else if model.selectedLocation == nil, !model.emptyParts.isEmpty {
            let empty = model.emptyParts
            Text("+ \(empty.count) PART vide\(empty.count > 1 ? "s" : "")"
                 + (model.emptyPartCapacityBytes.map { " · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))\(empty.count > 1 ? " chacune" : "")" } ?? ""))
                .font(.caption)
                .foregroundStyle(StudioPalette.muted)
                .help("PART vides : \(empty.map(\.letter).joined(separator: " ")). « Copier sur la SD… » propose la première qui peut recevoir la bank.")
        } else if let folder = selectedFolder {
            Text(folder.path)
                .font(.caption)
                .foregroundStyle(StudioPalette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder.path)
        }
    }

    private var programList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    if model.filteredKits.isEmpty {
                        LibraryEmptyState(
                            symbol: "square.grid.3x3",
                            title: model.programListIssue == nil ? "Aucun .PGM ici" : "Aucun .PGM visible ici",
                            detail: model.programListIssue == nil
                                ? "Choisis une autre PART, ou crée un .PGM avec +."
                                : "Actualise la bibliothèque (⌘R) pour vérifier les fichiers accessibles."
                        )
                    }
                    let groups = model.groupedFilteredKits
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.kits, id: \.url) { kit in
                                programRow(kit)
                            }
                        } header: {
                            if groups.count > 1 { KitGroupHeader(title: group.title, count: group.kits.count) }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.visible)
            .onChange(of: model.libraryKits) { _ in
                if let url = model.localSaveURL ?? model.programURL { proxy.scrollTo(url, anchor: .center) }
            }
            .onChange(of: model.localSaveURL) { url in
                if let url { proxy.scrollTo(url, anchor: .center) }
            }
        }
    }

    private func programRow(_ kit: LibraryKit) -> some View {
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
            Menu { kitActions(kit) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26)
                .help("Actions pour \(kit.url.lastPathComponent)")
                .accessibilityLabel("Actions pour \(kit.title), \(model.libraryLocationLabel(for: kit))")
        }
        .id(kit.url)
        .disabled(model.documentActionsDisabled)
        .contextMenu { kitActions(kit) }
    }

    @ViewBuilder
    private func kitActions(_ kit: LibraryKit) -> some View {
        Button("Voir ses samples à gauche") { model.showSamples(in: kit) }
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
}

// MARK: - Small shared pieces

/// A caveat is one icon; its explanation is the tooltip.
private struct IssueBadge: View {
    let title: String
    let issue: String?

    var body: some View {
        if let issue {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
                .font(.caption)
                .help("\(title). Les fichiers visibles ne permettent pas de conclure.\n\n\(issue)")
                .accessibilityLabel(title)
        }
    }
}

/// A source of samples, as a pill: the chosen one is filled.
private struct PlaceChip: View {
    let title: String
    let symbol: String
    let selected: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(selected ? Color.black : Color.white)
            .background(selected ? StudioPalette.orange : StudioPalette.panel, in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.clear : Color.white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One entry of the PART filter: a letter, underlined when chosen.
private struct FilterLetter: View {
    let text: String
    let selected: Bool
    var warning = false
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(selected ? StudioPalette.orange : Color.white.opacity(0.75))
                .padding(.vertical, 3)
                .overlay(alignment: .bottom) {
                    if selected { Rectangle().fill(StudioPalette.orange).frame(height: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(warning ? "\(label) · à vérifier" : label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lays its children left to right and wraps them, like words.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
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
