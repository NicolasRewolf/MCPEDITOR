import AppKit
import MPCCore
import SwiftUI

/// A caveat is one icon; its explanation is the tooltip.
struct IssueBadge: View {
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
struct PlaceChip: View {
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
struct FilterLetter: View {
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
struct SampleLinksPopover: View {
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

/// Free space of a PART against an empty one, so a bank's room is visible at a glance.
struct PartFillBar: View {
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

struct KitGroupHeader: View {
    let title: String
    let count: Int
    var unit = ".PGM"

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1)
            Spacer()
            Text(unit == ".PGM" ? "\(count) \(unit)" : LibraryFormat.count(count, unit))
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
struct SampleTreeRowView: View {
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
struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

/// Only samples are dragged onto pads; folders and notices stay put.
struct SampleRowDrag: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.onDrag { NSItemProvider(object: url as NSURL) }
        } else {
            content
        }
    }
}

struct BrowserRow: View {
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

struct LibraryEmptyState: View {
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
