import AppKit
import MPCCore
import SwiftUI

struct LibraryBrowser: View {
    @EnvironmentObject private var model: StudioModel
    @State private var showSDMap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("BIBLIOTHÈQUE", systemImage: "externaldrive")
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
                .help("Actualiser les partitions et les kits")
                .accessibilityLabel("Actualiser la bibliothèque")
            }
            Picker("Bibliothèque", selection: $model.libraryMode) {
                Text("Kits").tag(LibraryMode.kits)
                Text("Samples").tag(LibraryMode.samples)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let issue = model.libraryIssue, model.libraryContentIssue == nil {
                Label("Certains dossiers sont à vérifier", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .help(issue)
            }

            if model.libraryMode == .kits {
                kitBrowser
            } else {
                sampleBrowser
            }
            Divider()
            DisclosureGroup(isExpanded: $showSDMap) {
                partitionGrid.padding(.top, 8)
            } label: {
                HStack {
                    Label("Carte de la SD", systemImage: "sdcard")
                    Spacer()
                    Text("\(model.partitions.count) PART")
                        .foregroundStyle(StudioPalette.muted)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(StudioPalette.inset)
    }

    private var partitionGrid: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("PARTITIONS SD")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(StudioPalette.muted)
            if model.partitions.isEmpty {
                Text(model.libraryScanning ? "Recherche des partitions…" : "Aucune partition SD montée.")
                    .font(.caption)
                    .foregroundStyle(StudioPalette.muted)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5
                ) {
                    ForEach(model.partitions, id: \.url) { partition in
                        PartitionTile(
                            partition: partition,
                            selected: model.libraryMode == .kits
                                ? model.selectedLocation == partition.url
                                : model.selectedSampleRoot == partition.url
                        ) { model.selectLocation(partition.url) }
                    }
                }
            }
        }
    }

    private var kitBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Tous les kits", action: model.showAllKits)
                    .buttonStyle(.borderless)
                    .foregroundStyle(model.selectedLocation == nil ? StudioPalette.orange : Color.primary)
                Spacer()
                Menu {
                    ForEach(
                        model.locations.filter { LibraryIndex.partitionLetter(for: $0) == nil }, id: \.self
                    ) { folder in
                        Button(folder.lastPathComponent) { model.selectLocation(folder) }
                            .help(folder.path)
                    }
                    Divider()
                    Button("Ajouter un dossier de kits…", action: model.chooseFolder)
                } label: {
                    Label("Dossiers", systemImage: "folder")
                }
                .help("Parcourir les dossiers de kits ajoutés")
            }
            TextField("Rechercher un kit ou une PART", text: $model.kitSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Rechercher un kit ou une partition")
            HStack {
                Text("\(model.filteredKits.count) kit(s)\(model.libraryContentIssue == nil ? "" : " visibles")")
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
                                title: model.libraryContentIssue == nil ? "Aucun kit dans cette vue" : "Aucun kit visible dans cette vue",
                                detail: model.libraryContentIssue == nil
                                    ? "Choisis une autre PART, affiche tous les kits ou ajoute un dossier."
                                    : "Actualise la bibliothèque pour vérifier les fichiers accessibles."
                            )
                        }
                        ForEach(model.filteredKits, id: \.url) { kit in
                            HStack(spacing: 0) {
                                BrowserRow(
                                    title: kit.title,
                                    subtitle: "\(kit.locationLabel) · \(kit.url.lastPathComponent)",
                                    symbol: "square.grid.3x3",
                                    selected: (model.lastExportURL ?? model.programURL) == kit.url,
                                    path: kit.url.path
                                ) { model.openProgram(kit.url) }
                                .accessibilityLabel("\(kit.title), \(kit.locationLabel)")
                                .accessibilityHint("Ouvrir ce programme MPC")
                                Menu {
                                    kitActions(kit)
                                } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .frame(width: 28)
                                .help("Actions pour \(kit.url.lastPathComponent)")
                                .accessibilityLabel("Actions pour \(kit.title), \(kit.locationLabel)")
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
                    if let url = model.lastExportURL ?? model.programURL {
                        proxy.scrollTo(url, anchor: .center)
                    }
                }
                .onChange(of: model.lastExportURL) { url in
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
                Text(issue)
                    .lineLimit(3)
                    .help(issue)
            }
            .font(.caption)
            .foregroundStyle(.yellow)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func kitActions(_ kit: LibraryKit) -> some View {
        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([kit.url]) }
        Button("Mettre le programme à la corbeille…", role: .destructive) {
            model.requestTrashKit(kit)
        }
        .disabled(model.documentActionsDisabled)
    }

    private var sampleBrowser: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Menu {
                    ForEach(model.partitions, id: \.url) { partition in
                        Button("PART \(partition.letter) · \(partition.issues.isEmpty ? "\(partition.audioCount) sons" : "à vérifier")") {
                            model.selectLocation(partition.url)
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
                        model.selectedSampleRoot?.lastPathComponent ?? "Dossiers de samples",
                        systemImage: "folder"
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(model.selectedSampleRoot?.path ?? "Choisir un dossier à parcourir")
                Button(action: model.chooseSampleFolder) {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Ajouter un dossier du SSD ou du Mac")
                .accessibilityLabel("Ajouter un dossier de samples")
            }
            HStack(spacing: 8) {
                Button(action: model.sampleGoUp) { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .disabled(model.sampleFolder == nil || model.sampleFolder == model.selectedSampleRoot)
                    .help("Ouvrir le dossier parent")
                    .accessibilityLabel("Dossier parent")
                Text(model.sampleFolder?.lastPathComponent ?? "Choisis une PART ou un dossier")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .help(model.sampleFolder?.path ?? "")
                Spacer(minLength: 0)
            }
            TextField("Rechercher dans ce dossier", text: $model.sampleQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Rechercher des samples et sous-dossiers dans le dossier courant")
            Text(
                "\(model.filteredSampleFolders.count) dossier(s) · \(model.filteredSamples.count) sample(s)\(model.libraryContentIssue == nil ? "" : " visibles")"
            )
            .font(.caption)
            .foregroundStyle(StudioPalette.muted)
            inventoryWarning
            sampleFileList
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
                        subtitle: sample.pathExtension.uppercased(),
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

    private var sampleActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(model.selectedSampleURL?.lastPathComponent ?? "Sélectionne un sample")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .help(model.selectedSampleURL?.path ?? "")
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
            .help("Importer le sample sélectionné sur le pad \(model.selectedLabel) du kit en cours")
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

private struct PartitionTile: View {
    let partition: LibraryPartition
    let selected: Bool
    let action: () -> Void

    private var summary: String {
        if !partition.issues.isEmpty { return "!" }
        if !partition.kits.isEmpty { return String(partition.kits.count) }
        if partition.isEmpty { return "vide" }
        return partition.audioCount > 0 ? "sons" : "fich."
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(partition.letter)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Text(summary)
                    .font(.system(size: 8))
                    .foregroundStyle(partition.issues.isEmpty ? StudioPalette.muted : Color.yellow)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 35)
            .background(
                selected ? StudioPalette.orange.opacity(0.16) : StudioPalette.panel,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? StudioPalette.orange : StudioPalette.border)
            }
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(
            "PART \(partition.letter) · \(partition.kits.count) kit(s), \(partition.audioCount) son(s), \(partition.sequenceCount) séquence(s)\n\(partition.url.path)\n\(partition.issues.joined(separator: "\n"))"
        )
        .accessibilityLabel(
            "PART \(partition.letter), \(partition.kits.count) kits, \(partition.audioCount) sons\(partition.isEmpty && partition.issues.isEmpty ? ", vide" : "")\(partition.issues.isEmpty ? "" : ", à vérifier")"
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        guard let available = selectedPartition?.availableBytes else { return false }
        return selectedPartition.map { model.requiredExportFreeBytes(in: $0) > available } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Enregistrer le kit")
                    .font(.title2.bold())
                Text("Ton kit sera prêt à charger depuis la SD sur ta MPC.")
                    .font(.callout)
                    .foregroundStyle(StudioPalette.muted)
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nom du kit").font(.caption)
                    TextField(
                        "Nom du kit",
                        text: Binding(
                            get: { model.kitName }, set: { model.setKitName($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.documentLocked)
                    Text("Titre sur la MPC : \(model.programTitle)")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.muted)
                    Text("Modifier ce nom renomme aussi le titre du programme. Un suffixe de fichier choisi automatiquement ne change pas ce titre.")
                        .font(.caption2)
                        .foregroundStyle(StudioPalette.muted)
                }
                VStack(alignment: .trailing, spacing: 5) {
                    Text(
                        ByteCountFormatter.string(fromByteCount: model.estimatedExportBytes, countStyle: .file)
                    )
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    Text("\(model.assignedPadCount) pad(s) affecté(s)")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.muted)
                }
            }
            if model.exportDestinationURL == nil {
                Text(
                    "Aucune PART vide n’offre assez d’espace. Choisis une autre destination ou libère une PART depuis ta MPC."
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
                Button("Choisir un autre dossier…", action: model.chooseExportFolder)
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
                    Text("L’espace libre de cette partition est insuffisant pour ce kit.")
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
                    "Enregistrer sur \(model.selectedDestinationLabel)", action: model.exportKitToDestination
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
                : "\(partition.kits.count) kit(s) · \(partition.audioCount) son(s)"
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
