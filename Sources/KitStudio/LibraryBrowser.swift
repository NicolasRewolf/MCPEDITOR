import AppKit
import MPCCore
import SwiftUI

struct LibraryBrowser: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("BIBLIOTHÈQUE", systemImage: "square.stack")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if model.libraryScanning {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Actualisation de la bibliothèque")
                }
                Button {
                    model.refreshLocations()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.libraryScanning)
                .help("Actualiser les PART et les .PGM")
                .accessibilityLabel("Actualiser la bibliothèque")
            }
            Picker("Bibliothèque", selection: $model.libraryMode) {
                Text(".PGM").tag(LibraryMode.kits)
                Text("Samples").tag(LibraryMode.samples)
                Text("PART").tag(LibraryMode.parts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let issue = model.libraryIssue, model.libraryContentIssue == nil {
                Label("Certains dossiers sont à vérifier", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .help(issue)
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
            Text("Retrouver un .PGM sur la MPC")
                .font(.callout.weight(.medium))
            Text("Chaque PART affiche les fichiers visibles sur la SD.")
                .font(.caption)
                .foregroundStyle(StudioPalette.muted)
            if model.partitions.isEmpty {
                LibraryEmptyState(symbol: "sdcard", title: "Aucune PART montée",
                                  detail: "Branche la SD pour retrouver ses .PGM et ses samples.")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.partitions, id: \.url) { partition in
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
                                } else if partition.isEmpty {
                                    Text("Aucun fichier visible").font(.caption).foregroundStyle(StudioPalette.muted)
                                }
                            }
                            if !partition.kits.isEmpty {
                                Text(partition.kits.map { $0.url.lastPathComponent }.joined(separator: " · "))
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if !partition.issues.isEmpty {
                                Text("Aucun .PGM visible · inventaire incomplet")
                                    .font(.caption).foregroundStyle(StudioPalette.muted)
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
                } label: {
                    Label("Dossiers", systemImage: "folder")
                }
                .help("Parcourir les dossiers de .PGM ajoutés")
            }
            TextField("Rechercher un .PGM ou une PART", text: $model.kitSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Rechercher un .PGM ou une partition")
            HStack {
                Text("\(model.filteredKits.count) .PGM\(model.libraryContentIssue == nil ? "" : " visibles")")
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
            inventoryWarning
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if model.filteredKits.isEmpty {
                            LibraryEmptyState(
                                symbol: "square.grid.3x3",
                                title: model.libraryContentIssue == nil ? "Aucun .PGM dans cette vue" : "Aucun .PGM visible dans cette vue",
                                detail: model.libraryContentIssue == nil
                                    ? "Choisis une autre PART, affiche tous les .PGM ou ajoute un dossier."
                                    : "Actualise la bibliothèque pour vérifier les fichiers accessibles."
                            )
                        }
                        ForEach(model.filteredKits, id: \.url) { kit in
                            HStack(spacing: 0) {
                                BrowserRow(
                                    title: kit.title,
                                    subtitle: "\(model.libraryLocationLabel(for: kit)) · \(kit.url.lastPathComponent)",
                                    symbol: "square.grid.3x3",
                                    selected: (model.localSaveURL ?? model.programURL) == kit.url,
                                    path: kit.url.path
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

    @ViewBuilder
    private var inventoryWarning: some View {
        if let issue = model.libraryContentIssue {
            VStack(alignment: .leading, spacing: 5) {
                Label(model.libraryInventoryWarningTitle, systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                Text(model.libraryInventoryWarningDetail)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Détails") {
                    Text(issue)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .foregroundStyle(.yellow)
        }
    }

    @ViewBuilder
    private func kitActions(_ kit: LibraryKit) -> some View {
        Button("Voir les samples") { model.showSamples(in: kit) }
        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([kit.url]) }
        Button("Mettre le programme à la corbeille…", role: .destructive) {
            model.requestTrashKit(kit)
        }
        .disabled(model.documentActionsDisabled)
    }

    private var sampleBrowser: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Button(action: model.goBackInSamples) {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canGoBackInSamples)
                .help("Revenir à la vue de samples précédente")
                .accessibilityLabel("Retour aux samples précédents")
                Menu {
                    Button("Bibliothèque et SD", action: model.showAllLibrarySamples)
                    Button("Toute la SD", action: model.showAllSDSamples)
                    Divider()
                    ForEach(model.partitions, id: \.url) { partition in
                        Button("PART \(partition.letter) · \(partition.issues.isEmpty ? "\(partition.audioCount) sons" : "à vérifier")") {
                            model.showSamples(in: partition)
                        }
                    }
                    Divider()
                    ForEach(model.sampleRoots, id: \.self) { root in
                        Button(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent) {
                            model.selectSampleRoot(root)
                        }
                        .help(root.path)
                    }
                    Divider()
                    Button("Ajouter un dossier de samples…", action: model.chooseSampleFolder)
                } label: {
                    Label(
                        model.sampleScopeTitle,
                        systemImage: "folder"
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("Choisir les samples de la bibliothèque, de la SD ou d’un dossier")
                Button(action: model.chooseSampleFolder) {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Ajouter un dossier du SSD ou du Mac")
                .accessibilityLabel("Ajouter un dossier de samples")
            }
            if model.sampleScope == .folder {
                HStack(spacing: 8) {
                    Button(action: model.sampleGoUp) { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderless)
                        .disabled(!model.canGoUpSamples)
                        .help("Ouvrir le dossier parent")
                        .accessibilityLabel("Dossier parent")
                    Text(model.sampleFolder?.lastPathComponent ?? model.sampleScopeTitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .help(model.sampleFolder?.path ?? "")
                    Spacer(minLength: 0)
                }
            }
            TextField("Rechercher dans cette vue", text: $model.sampleQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Rechercher des samples dans la vue courante")
            Text(
                (model.sampleScope == .folder ? "\(model.filteredSampleFolders.count) dossier(s) · " : "")
                    + "\(model.filteredSamples.count) sample(s)\(model.libraryContentIssue == nil ? "" : " visibles")"
            )
            .font(.caption)
            .foregroundStyle(StudioPalette.muted)
            inventoryWarning
            sampleFileList
            sampleAssociations
            sampleActions
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var sampleFileList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 4) {
                if model.filteredSampleFolders.isEmpty && model.filteredSamples.isEmpty {
                    LibraryEmptyState(
                        symbol: "waveform",
                        title: model.libraryContentIssue == nil ? "Aucun sample dans cette vue" : "Aucun sample visible dans cette vue",
                        detail: model.libraryContentIssue == nil
                            ? "Ouvre un sous-dossier, choisis une autre PART ou ajoute un dossier de ton SSD."
                            : "Actualise la bibliothèque pour vérifier les fichiers accessibles."
                    )
                }
                ForEach(model.filteredSampleFolders, id: \.self) { folder in
                    BrowserRow(
                        title: folder.lastPathComponent,
                        subtitle: "Sous-dossier",
                        symbol: "folder",
                        selected: false,
                        path: folder.path
                    ) { model.browseSamplesFolder(folder) }
                    .accessibilityHint("Parcourir ce sous-dossier")
                }
                ForEach(model.filteredSamples, id: \.self) { sample in
                    BrowserRow(
                        title: sample.lastPathComponent,
                        subtitle: "\(model.sampleLocationLabel(for: sample)) · \(model.sampleAssociationSummary(for: sample))",
                        symbol: "waveform",
                        selected: model.selectedSampleURL == sample,
                        path: sample.path
                    ) { model.selectSample(sample) }
                    .onDrag { NSItemProvider(object: sample as NSURL) }
                    .accessibilityHint(
                        "Sélectionner pour écouter ou affecter au pad ; glisser vers un pad pour importer")
                }
            }
            .padding(.trailing, 4)
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    private var sampleAssociations: some View {
        if let sample = model.selectedSampleURL {
            VStack(alignment: .leading, spacing: 7) {
                Divider()
                Text(sample.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .help(sample.path)
                Text(model.sampleLocationLabel(for: sample))
                    .font(.caption).foregroundStyle(StudioPalette.muted)
                Text("Utilisé par · .PGM enregistrés")
                    .font(.caption.weight(.semibold))
                let programs = model.programsUsingSample(sample)
                if programs.isEmpty {
                    Text(model.libraryScanning ? "Lecture des liens en cours…" : "Aucun lien trouvé dans les .PGM lus.")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.muted)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
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
                                .help("Ouvrir \(program.url.path)")
                                .accessibilityLabel("Ouvrir \(program.url.lastPathComponent), \(model.libraryLocationLabel(for: program))")
                                .disabled(model.documentActionsDisabled)
                            }
                        }
                        .font(.caption)
                    }
                    .frame(height: min(100, CGFloat(programs.count) * 36))
                }
                if let notice = model.selectedSampleAssociationNotice {
                    if model.isDirty {
                        Text("Les modifications en cours ne sont pas encore incluses dans ces liens.")
                            .font(.caption)
                            .foregroundStyle(StudioPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(notice)
                    } else {
                        Label("Liens vérifiés dans la bibliothèque", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(StudioPalette.muted)
                            .help(notice)
                    }
                }
            }
        }
    }

    private var sampleActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if model.selectedSampleURL == nil {
                Text("Sélectionne un sample")
                    .font(.system(size: 11, weight: .medium))
            }
            HStack {
                Button {
                    if let sample = model.selectedSampleURL { model.previewSample(sample) }
                } label: {
                    Label(model.samplePreviewBusy ? "Préparation…" : "Écouter", systemImage: "play.fill")
                }
                .disabled(
                    model.selectedSampleURL == nil || model.samplePreviewBusy || model.documentActionsDisabled
                )
                Button("Arrêter", action: model.stop)
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            Button {
                if let sample = model.selectedSampleURL { model.assignSample(sample) }
            } label: {
                Label("Affecter au pad \(model.selectedLabel)", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.black)
            .disabled(
                model.selectedSampleURL == nil || model.program == nil || model.documentActionsDisabled
                    || model.samplePreviewBusy
            )
            .help("Importer le sample sélectionné sur le pad \(model.selectedLabel) du .PGM en cours")
            if !model.samplePreviewStatus.isEmpty {
                Text(model.samplePreviewStatus)
                    .font(.caption)
                    .foregroundStyle(StudioPalette.muted)
                    .lineLimit(2)
                    .help(model.samplePreviewStatus)
            }
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
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(StudioPalette.muted)
                        .lineLimit(2)
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
                Text(
                    "Aucune PART proposée. Branche la SD ou choisis un dossier pour cette copie."
                )
                .font(.callout)
                .foregroundStyle(.yellow)
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
                Text("PARTITIONS SD")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(StudioPalette.muted)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 5) {
                            if model.partitions.isEmpty {
                                Text("Aucune partition SD montée. Tu peux choisir un dossier sur le Mac.")
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
                    Text("L’espace libre de cette partition est insuffisant pour ce .PGM et ses samples.")
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
                : "\(partition.kits.count) .PGM · \(partition.audioCount) son(s)"
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
