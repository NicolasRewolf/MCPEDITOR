import AppKit
import MPCCore
import SwiftUI

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
                        String(localized: "Aucune PART proposée : ce .PGM et ses samples demandent \(ByteCountFormatter.string(fromByteCount: capacity.requiredBytes, countStyle: .file)), une PART vide en offre \(ByteCountFormatter.string(fromByteCount: capacity.capacityBytes, countStyle: .file)). Retire ou raccourcis des samples, ou choisis un dossier sur le Mac.")
                    )
                    .font(.callout)
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(
                        String(localized: "Aucune PART proposée. Branche la SD ou choisis un dossier pour cette copie.")
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
            DisclosureGroup(String(localized: "Changer la destination"), isExpanded: $changeDestination) {
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
                Text(model.exportDestinationURL?.path ?? String(localized: "Aucune destination choisie"))
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
                String(localized: "Un programme .PGM et ses sons .SND seront créés. Les fichiers existants sont conservés ; un nom libre est choisi si nécessaire.")
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
                    String(localized: "Copier ici"), action: model.exportKitToDestination
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
            ? String(localized: "À vérifier")
            : partition.isEmpty
                ? String(localized: "Vide (fichiers visibles)")
                : "\(LibraryFormat.programs(partition.kits.count)) · \(LibraryFormat.samples(partition.audioCount))"
        let available =
            partition.availableBytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + String(localized: " libres")
            } ?? String(localized: "Espace inconnu")
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
