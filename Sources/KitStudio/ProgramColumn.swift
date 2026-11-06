import AppKit
import MPCCore
import SwiftUI

/// The .PGM list with a one-line PART filter: letters for the PARTs that hold
/// something, one line for the empty ones.
struct ProgramColumn: View {
    @EnvironmentObject private var model: StudioModel

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
            ForEach(model.mountedPartsWithContent, id: \.url) { part in
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
                if let metadata = part.macOSMetadata, let summary = LibraryFormat.macOSSummary(metadata) {
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
