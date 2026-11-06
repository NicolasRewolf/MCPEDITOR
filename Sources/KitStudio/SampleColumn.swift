import AppKit
import MPCCore
import SwiftUI

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
            if model.selectedSamplePlace == nil {
                HStack(spacing: 7) {
                    if model.canGoBackInSamples {
                        Button(action: model.goBackInSamples) { Image(systemName: "chevron.backward") }
                            .buttonStyle(.borderless)
                            .help("Revenir à la vue de samples précédente")
                            .accessibilityLabel("Retour aux samples précédents")
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
                .help(model.autoPreviewSamples ? String(localized: "Écoute en parcourant avec ↑ ↓ : activée") : String(localized: "Écouter en parcourant avec ↑ ↓"))
                .accessibilityLabel("Écouter en parcourant")
                .accessibilityValue(model.autoPreviewSamples ? String(localized: "activée") : String(localized: "désactivée"))
            }
            if let line = countLine {
                HStack(spacing: 6) {
                    if model.sampleSearchInProgress { ProgressView().controlSize(.mini) }
                    Text(line)
                    IssueBadge(title: String(localized: "Inventaire incomplet"), issue: model.sampleBrowserIssue)
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
            return String(localized: "Rechercher dans \(folder.lastPathComponent)")
        }
        return String(localized: "Rechercher dans cette vue")
    }

    private var countLine: String? {
        if model.isSampleTreeSearch {
            if model.sampleSearchInProgress { return String(localized: "Recherche…") }
            let count = model.filteredSamples.count
            return model.sampleSearchTruncated ? String(localized: "\(count)+ résultats · précise ta recherche") : LibraryFormat.results(count)
        }
        if model.sampleScope == .folder { return model.sampleBrowserIssue == nil ? nil : String(localized: "Dossier à vérifier") }
        return LibraryFormat.samples(model.filteredSamples.count)
    }

    /// The computer's sources, side by side: the Mac collection, then each added folder.
    private var places: some View {
        FlowLayout(spacing: 5) {
            let place = model.selectedSamplePlace
            PlaceChip(title: String(localized: "Mac"), symbol: "desktopcomputer", selected: place == .library,
                      help: String(localized: "Les samples des .PGM enregistrés sur le Mac. L’app les range dans son dossier :\n\(model.macLibraryURL.path)"),
                      action: model.showAllLibrarySamples)
            .contextMenu {
                Button("Afficher dans le Finder") { model.revealInFinder(model.macLibraryURL) }
            }
            ForEach(model.sampleRoots, id: \.self) { root in
                let name = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
                PlaceChip(title: LibraryFormat.volumeName(of: root).map { "\(name) · \($0)" } ?? name,
                          symbol: LibraryFormat.volumeName(of: root) == nil ? "folder" : "externaldrive",
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
                        LibraryEmptyState(symbol: "folder", title: model.emptySampleTreeTitle,
                                          detail: model.emptySampleTreeDetail)
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
                            title: model.isSampleTreeSearch ? String(localized: "Aucun sample trouvé") : String(localized: "Aucun sample dans cette vue"),
                            detail: model.isSampleTreeSearch
                                ? String(localized: "Chaque mot cherché doit apparaître dans le nom du sample ou de ses dossiers.")
                                : (model.sampleScope == .library
                                    ? String(localized: "Les samples des .PGM enregistrés sur le Mac apparaissent ici. Ajoute un dossier de ton SSD avec +.")
                                    : String(localized: "Choisis une autre source ou ajoute un dossier de ton SSD."))
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
                                KitGroupHeader(title: group.title, countText: LibraryFormat.samples(group.samples.count))
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
            HStack(spacing: 6) {
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
                             ? String(localized: "\(model.sdSampleCount) · \(model.mountedPartsWithContent.count) PART")
                             : String(localized: "SD absente"))
                            .font(.caption)
                            .foregroundStyle(StudioPalette.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Samples de la SD")
                .accessibilityValue(sdCollapsed ? String(localized: "replié") : String(localized: "déplié"))
                IssueBadge(title: String(localized: "Inventaire de la SD incomplet"), issue: model.sdSamplesIssue)
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
                        Text(model.sdSampleQuery.isEmpty ? String(localized: "Aucun sample sur la SD.") : String(localized: "Aucun sample trouvé sur la SD."))
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
            .help(issue.map { String(localized: "PART \(letter) à vérifier :\n\($0)") } ?? String(localized: "PART \(letter) · \(LibraryFormat.samples(count))"))
            .accessibilityLabel("PART \(letter), \(LibraryFormat.samples(count))")
            .accessibilityValue(expanded ? String(localized: "déplié") : String(localized: "replié"))
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
            if let problem = model.sampleProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .lineLimit(2)
                    .help(problem)
            }
        }
    }
}
