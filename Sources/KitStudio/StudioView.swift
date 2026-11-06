import SwiftUI
import UniformTypeIdentifiers
import MPCCore

enum StudioPalette {
    static let background = Color(red: 0.075, green: 0.081, blue: 0.091)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.135)
    static let inset = Color(red: 0.065, green: 0.071, blue: 0.08)
    static let border = Color.white.opacity(0.09)
    static let orange = Color(red: 1, green: 0.49, blue: 0.22)
    static let muted = Color(red: 0.56, green: 0.60, blue: 0.65)
}

/// Orange primary action with a dark label. `.borderedProminent` with a forced black
/// label became black on grey while the window was inactive (during a Finder drag)
/// and nearly invisible when disabled; this style stays legible in both states.
struct StudioProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.black : StudioPalette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isEnabled ? StudioPalette.orange.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct StudioView: View {
    @EnvironmentObject private var model: StudioModel
    @State private var statusVisible = true

    var body: some View {
        VStack(spacing: 0) {
            // Take on the left, build in the middle, keep on the right: the samples
            // touch the pads they are dragged onto.
            HStack(spacing: 0) {
                SampleColumn()
                    .frame(width: 380)
                Divider()
                workspace
                Divider()
                ProgramColumn()
                    .frame(width: 280)
            }
            statusBar
        }
        .background(StudioPalette.background)
        .toolbar {
            // Every action says what it does: an icon alone did not.
            ToolbarItemGroup {
                Button(action: model.newKit) {
                    Label("Nouveau .PGM", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .help("Créer un programme vide")
                .disabled(model.documentActionsDisabled)
                Button(action: model.importAudio) {
                    Label("Importer un son…", systemImage: "waveform.badge.plus").labelStyle(.titleAndIcon)
                }
                .help("Choisir un WAV, AIFF ou SND pour le pad \(model.selectedLabel)")
                .disabled(model.program == nil || model.documentActionsDisabled)
                Button { _ = model.saveProgram() } label: {
                    Label("Enregistrer sur le Mac", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon)
                }
                .help("Conserver le .PGM et ses samples dans la bibliothèque de l’app, sur ce Mac (⌘S)")
                .disabled(model.program == nil || model.documentActionsDisabled)
                Button(action: model.exportKit) {
                    Label("Copier sur la SD…", systemImage: "sdcard").labelStyle(.titleAndIcon)
                }
                .help("Choisir une PART et y copier le .PGM et ses samples (⇧⌘S)")
                .disabled(model.program == nil || model.documentActionsDisabled)
            }
        }
        .sheet(isPresented: $model.showExportSheet) {
            ExportDestinationSheet()
                .environmentObject(model)
        }
        .alert("Impossible de terminer", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            padPanel
                .frame(maxWidth: 600, alignment: .leading)
            // The editor sits under the pads, as wide; an empty pad needs a single line.
            SampleEditor()
                .frame(maxWidth: 600, maxHeight: model.sound == nil ? nil : .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(16)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    TextField("Nom du .PGM", text: Binding(
                        get: { model.kitName },
                        set: { model.setKitName($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .accessibilityLabel("Nom du .PGM")
                    .focusedValue(\.editsProgramDocument, true)
                    .disabled(model.program == nil || model.documentActionsDisabled)
                    if model.isDirty {
                        Circle().fill(StudioPalette.orange).frame(width: 7, height: 7)
                            .help("Modifications non enregistrées sur le Mac")
                            .accessibilityLabel("Modifications non enregistrées")
                    }
                }
                HStack(spacing: 7) {
                    Image(systemName: model.localSaveURL == nil ? "doc" : "internaldrive")
                    Text(model.documentSaveLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !model.kitLocationPath.isEmpty {
                        Button("Finder", action: model.revealKitLocation)
                            .buttonStyle(.borderless)
                            .help(model.kitLocationPath)
                            .accessibilityLabel("Afficher le .PGM dans le Finder")
                    }
                }
                .font(.caption)
                .foregroundStyle(StudioPalette.muted)
                .help(model.kitLocationPath)
                if model.programTitle != model.kitName {
                    Text("Titre sur la MPC : \(model.programTitle)")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.muted)
                }
                if let file = model.programFileNamePreview {
                    Text("Enregistré sous \(file)")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.muted)
                        .help("Nom 8.3 utilisé sur le Mac et sur la SD. Si ce nom existe déjà, un chiffre remplace sa fin.")
                }
            }
            Spacer(minLength: 12)
            // One figure that decides something: does the bank fit in a PART?
            if let capacity = model.partCapacity {
                PartCapacityGauge(capacity: capacity)
                    .help("Mémoire audio sur la MPC : \(ByteCountFormatter.string(fromByteCount: Int64(model.memoryBytes), countStyle: .memory)). La jauge compare la copie sur la SD à une PART vide.")
            } else if model.memoryBytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(model.memoryBytes), countStyle: .memory))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(StudioPalette.muted)
                    .help("Mémoire audio du .PGM sur la MPC")
            }
        }
    }

    private var padPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<4) { bank in
                        Button {
                            model.bank = bank
                            model.selectPad(bank * 16 + model.selectedPad % 16)
                        } label: {
                            Text(["A", "B", "C", "D"][bank])
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .frame(width: 35, height: 30)
                                .background(model.bank == bank ? StudioPalette.orange : StudioPalette.panel)
                                .foregroundStyle(model.bank == bank ? Color.black : Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Banque \(["A", "B", "C", "D"][bank])")
                        .disabled(model.documentActionsDisabled)
                        .accessibilityAddTraits(model.bank == bank ? .isSelected : [])
                        .onDrop(of: [UTType(importedAs: "com.nicolasrewolf.mpckitstudio.pad")], delegate: BankDragDestination {
                            guard !model.documentActionsDisabled else { return }
                            model.bank = bank
                            model.selectPad(bank * 16 + model.selectedPad % 16)
                        })
                        .help("Survole cette banque pendant le déplacement d’un pad pour y accéder")
                    }
                }
                Spacer()
                Button(action: model.clearPad) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(StudioPalette.muted)
                .disabled(model.program == nil || model.documentActionsDisabled)
                .help("Vider le pad sélectionné")
                .accessibilityLabel("Vider le pad sélectionné")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(0..<16) { position in
                    let localPad = (3 - position / 4) * 4 + position % 4
                    let index = model.bank * 16 + localPad
                    PadButton(
                        number: localPad + 1,
                        name: model.padName(index),
                        hasSound: model.padHasSound(index: index),
                        selected: model.selectedPad == index,
                        missing: model.padIsMissing(index),
                        shared: !model.padsSharingSample(with: index).isEmpty,
                        onPress: { model.selectPad(index); model.playPad(index) },
                        onDropFiles: { model.dropFiles($0, onPad: index) },
                        onDragPad: { model.padDragProvider(index: index) },
                        onDropPads: { model.dropPads(providers: $0, onPad: index) }
                    )
                    .contextMenu { padActions(for: index) }
                }
            }
            .disabled(model.program == nil || model.documentActionsDisabled)
        }
    }

    @ViewBuilder
    private func padActions(for source: Int) -> some View {
        let target = model.selectedPad
        let canTransfer = source != target && model.padHasSound(index: source)
        let targetHasSound = model.padHasSound(index: target)
        Button(targetHasSound ? "Échanger avec \(model.selectedLabel)" : "Déplacer vers \(model.selectedLabel)") {
            model.padTransfer(from: source, to: target)
        }
        .disabled(!canTransfer || model.documentActionsDisabled)
        Button("Copier l’affectation vers \(model.selectedLabel)") {
            model.padTransfer(from: source, to: target, copy: true)
        }
        .disabled(!canTransfer || model.documentActionsDisabled)
        .help("Les deux pads partagent le même sample.")
        Divider()
        Button("Vider ce pad") {
            model.selectPad(source)
            model.clearPad()
        }
        .disabled(!model.padHasSound(index: source) || model.documentActionsDisabled)
    }

    /// Feedback, not furniture: a message shows for a few seconds, then the bar stays quiet.
    private var statusBar: some View {
        HStack(spacing: 9) {
            if model.busy {
                ProgressView().controlSize(.small).scaleEffect(0.75)
            }
            if statusVisible || model.busy {
                Text(model.status)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(StudioPalette.muted)
                    .help(model.status)
            }
            if model.resolvingDroppedFiles {
                Button("Annuler le dépôt", action: model.cancelDroppedFiles)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Annuler la lecture des fichiers déposés")
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 32)
        .task(id: model.status) {
            statusVisible = true
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            statusVisible = false
        }
        .background(StudioPalette.inset)
        .overlay(alignment: .top) { Rectangle().fill(StudioPalette.border).frame(height: 1) }
    }

}

/// What the copy needs on the SD against one empty PART, visible while the bank is built.
struct PartCapacityGauge: View {
    let capacity: StudioModel.PartCapacity

    private var tint: Color {
        capacity.fits ? (capacity.fraction > 0.9 ? .yellow : StudioPalette.orange) : .yellow
    }

    private var label: String {
        let required = ByteCountFormatter.string(fromByteCount: capacity.requiredBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: capacity.capacityBytes, countStyle: .file)
        return capacity.fits ? "\(required) / \(total) sur une PART" : "Ne tient pas dans une PART · \(required) / \(total)"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule().fill(tint)
                            .frame(width: geometry.size.width * min(1, max(0.02, capacity.fraction)))
                    }
                }
                .frame(width: 150, height: 4)
            Text(label)
                .font(.caption)
                .foregroundStyle(capacity.fits ? StudioPalette.muted : Color.yellow)
        }
        .help(capacity.measuredLetter.map {
            "Espace nécessaire pour copier ce .PGM et ses samples, allocation FAT et réserve comprises, comparé à la plus grande PART vide de la SD (PART \($0))."
        } ?? "Espace nécessaire pour copier ce .PGM et ses samples, allocation FAT et réserve comprises, comparé à la dernière PART vide observée. La SD n’est pas branchée.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Hovering over a bank during a pad drag reveals its pads without consuming the drop.
private struct BankDragDestination: DropDelegate {
    let reveal: () -> Void

    func dropEntered(info: DropInfo) { reveal() }
    func performDrop(info: DropInfo) -> Bool { false }
}

private struct PadButton: View {
    let number: Int
    let name: String
    let hasSound: Bool
    let selected: Bool
    let missing: Bool
    let shared: Bool
    let onPress: () -> Void
    let onDropFiles: ([NSItemProvider]) -> Bool
    let onDragPad: () -> NSItemProvider?
    let onDropPads: ([NSItemProvider]) -> Bool
    @State private var dropTarget = false

    private static let padType = UTType(importedAs: "com.nicolasrewolf.mpckitstudio.pad")

    var body: some View {
        draggableButton
            .onDrop(of: [Self.padType, UTType.fileURL], isTargeted: $dropTarget) { providers in
                let pads = providers.filter { $0.hasItemConformingToTypeIdentifier(Self.padType.identifier) }
                return pads.isEmpty ? onDropFiles(providers) : onDropPads(pads)
            }
            .accessibilityLabel("Pad \(number), \(hasSound ? name : "vide")\(shared ? ", sample partagé" : "")\(missing ? ", sample introuvable" : "")")
            .accessibilityHint("Écouter et sélectionner. Glisser pour déplacer ; déposer sur un pad occupé pour échanger.")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var draggableButton: some View {
        if !hasSound {
            padButton
        } else {
            padButton.onDrag { onDragPad() ?? NSItemProvider() }
        }
    }

    private var padButton: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(format: "%02d", number))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(selected ? StudioPalette.orange : StudioPalette.muted)
                    Spacer()
                    if shared {
                        Image(systemName: "link")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(StudioPalette.orange)
                            .help("Ce pad partage son sample avec un autre pad.")
                    }
                    if missing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                    }
                }
                Spacer(minLength: 0)
                Text(hasSound ? name : "—")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(hasSound ? Color.white : StudioPalette.muted)
            }
            .padding(9)
            .frame(height: 64)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(selected ? 0.12 : 0.08), Color.white.opacity(0.025)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(dropTarget || selected ? StudioPalette.orange : StudioPalette.border, lineWidth: dropTarget ? 2 : 1)
            }
            .overlay(alignment: .bottom) {
                if selected { Capsule().fill(StudioPalette.orange).frame(width: 22, height: 3).padding(.bottom, 5) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

private struct SampleEditor: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selectedLabel)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    if model.sound != nil {
                        TextField("Nom du sample", text: Binding(
                            get: { model.sound?.name ?? "" }, set: { model.setSoundName($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, weight: .medium))
                        .accessibilityLabel("Nom du sample du pad \(model.selectedLabel)")
                        .focusedValue(\.editsProgramDocument, true)
                        .help(model.sound?.name ?? "")
                        .disabled(model.busy)
                        if let file = model.soundFileNamePreview {
                            Text("Enregistré sous \(file)")
                                .font(.caption)
                                .foregroundStyle(StudioPalette.muted)
                                .help("Nom 8.3 utilisé dans le .PGM et sur la SD. Si ce nom existe déjà, un chiffre remplace sa fin.")
                        }
                        let sharing = model.padsSharingSample(with: model.selectedPad)
                        if !sharing.isEmpty {
                            Label("Sample partagé avec \(sharing.map(StudioModel.padLabel).joined(separator: ", "))", systemImage: "link")
                                .font(.caption)
                                .foregroundStyle(StudioPalette.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .help("Le nom, la découpe et les traitements s’appliquent aussi à ces pads. L’accordage reste propre à chaque pad.")
                        }
                    }
                }
                Spacer()
                if let sound = model.sound {
                    Text(sound.channels.count == 1 ? "MONO" : "STÉRÉO")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.06), in: Capsule())
                }
            }
            if let sound = model.sound, sound.frameCount > 0 {
                ScrollView(.vertical, showsIndicators: true) {
                    if let warning = model.selectedAudioRangeWarning {
                        Text("Crête \(String(format: "%.2f", warning.report.peakMagnitude)) : ce sample dépasse le niveau du PCM 16 bits. Normalise-le avant l’export pour éviter l’écrêtage.")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    loadedEditor(sound)
                }
                .scrollIndicators(.visible)
            } else {
                emptyEditor
            }
        }
        .padding(14)
        .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(StudioPalette.border) }
    }

    private func loadedEditor(_ sound: MPCSound) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WaveformView(sound: sound, onTrim: model.setTrim)
                .frame(height: 110)
                .background(StudioPalette.inset, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Forme d’onde du sample, début \(sound.start), fin \(sound.end)")
            HStack {
                Label(String(format: "%.3f s", Double(sound.frameCount) / 44_100), systemImage: "waveform")
                Spacer()
                Text("\(sound.frameCount.formatted()) échantillons")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(StudioPalette.muted)
            trimControls(sound)
            HStack(spacing: 8) {
                Button { model.playPad(model.selectedPad) } label: { Label("Écouter", systemImage: "play.fill") }
                    .buttonStyle(StudioProminentButtonStyle())
                Button(action: model.stop) { Image(systemName: "stop.fill") }
                    .buttonStyle(.bordered)
                    .help("Arrêter la lecture")
                Spacer()
                Text(String(format: "Sélection : %.3f s", Double(max(0, sound.end - sound.start)) / 44_100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StudioPalette.muted)
            }
            transformControls
            HStack {
                Label("Accordage", systemImage: "tuningfork")
                    .font(.callout)
                Spacer()
                Stepper(value: Binding(
                    get: { model.padTune },
                    set: { model.setPadTune($0) }
                ), in: -120...120) {
                    Text(String(format: "%+.1f demi-tons", Double(model.padTune) / 10))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 120, alignment: .trailing)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .disabled(model.busy)
    }

    private func trimControls(_ sound: MPCSound) -> some View {
        VStack(spacing: 4) {
            trimSlider(
                title: "DÉBUT", value: sound.start, upper: max(1, sound.frameCount - 1)
            ) { model.setTrim(start: min($0, sound.end - 1), end: sound.end) }
            trimSlider(
                title: "FIN", value: sound.end, upper: max(1, sound.frameCount)
            ) { model.setTrim(start: sound.start, end: max(sound.start + 1, $0)) }
        }
    }

    private func trimSlider(title: String, value: Int, upper: Int, onChange: @escaping (Int) -> Void) -> some View {
        SampleTrimSlider(title: title, value: value, upper: upper, onChange: onChange)
    }

    /// One row under the pads' width; it wraps only in a narrow window.
    private var transformControls: some View {
        FlowLayout(spacing: 7, lineSpacing: 7) {
            operation("Découper", symbol: "scissors", kind: "trim")
            operation("Normaliser", symbol: "waveform", kind: "normalize")
            operation("Mono", symbol: "speaker.wave.1", kind: "mono")
            operation("Petits fondus", symbol: "waveform.path", kind: "fade")
            operation("Inverser", symbol: "backward.end", kind: "reverse")
        }
    }

    private func operation(_ title: String, symbol: String, kind: String) -> some View {
        Button { model.transform(kind) } label: {
            Label(title, systemImage: symbol).font(.system(size: 11))
        }
        .buttonStyle(.bordered)
    }

    private var emptyEditor: some View {
        HStack(spacing: 12) {
            Text("Pad vide")
                .foregroundStyle(StudioPalette.muted)
            Spacer(minLength: 0)
            Button("Importer un sample…", action: model.importAudio)
                .buttonStyle(.bordered)
                .disabled(model.program == nil || model.documentActionsDisabled)
                .help("Ou glisse un WAV, AIFF ou SND sur le pad")
        }
    }
}

/// Keep the native slider continuous: a stepped macOS slider allocates one
/// visual tick per step, which stalls layout for audio with thousands of frames.
/// The binding still rounds the selected position to a whole audio frame.
struct SampleTrimSlider: View {
    let title: String
    let value: Int
    let upper: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioPalette.muted)
                .frame(width: 35, alignment: .leading)
            Slider(value: Binding(
                get: { Double(min(upper, max(0, value))) },
                set: { onChange(Int($0.rounded())) }
            ), in: 0...Double(upper))
            .accessibilityLabel(title == "DÉBUT" ? "Début du sample" : "Fin du sample")
            Text(value.formatted())
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 66, alignment: .trailing)
        }
    }
}

private struct WaveformView: View {
    let sound: MPCSound
    let onTrim: (Int, Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let frames = max(1, sound.frameCount)
            let startX = width * CGFloat(sound.start) / CGFloat(frames)
            let endX = width * CGFloat(sound.end) / CGFloat(frames)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawWaveform(context: context, size: size)
                }
                Rectangle().fill(Color.black.opacity(0.48))
                    .frame(width: max(0, startX), height: geometry.size.height)
                Rectangle().fill(Color.black.opacity(0.48))
                    .frame(width: max(0, width - endX), height: geometry.size.height)
                    .offset(x: endX)
                Rectangle().fill(StudioPalette.orange.opacity(0.04))
                    .frame(width: max(0, endX - startX), height: geometry.size.height)
                    .offset(x: startX)
                trimHandle(title: "S", height: geometry.size.height)
                    .position(x: startX, y: geometry.size.height / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("waveform")).onChanged { value in
                        let point = Int(max(0, min(1, value.location.x / max(1, width))) * CGFloat(frames))
                        onTrim(min(point, max(0, sound.end - 1)), sound.end)
                    })
                trimHandle(title: "E", height: geometry.size.height)
                    .position(x: endX, y: geometry.size.height / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("waveform")).onChanged { value in
                        let point = Int(max(0, min(1, value.location.x / max(1, width))) * CGFloat(frames))
                        onTrim(sound.start, max(sound.start + 1, min(frames, point)))
                    })
            }
            .coordinateSpace(name: "waveform")
        }
    }

    private func trimHandle(title: String, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(StudioPalette.orange).frame(width: 1, height: height)
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .frame(width: 18, height: 18)
                .background(StudioPalette.orange, in: RoundedRectangle(cornerRadius: 3))
        }
        .frame(width: 28, height: height)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        let channelCount = max(1, sound.channels.count)
        let channelHeight = size.height / CGFloat(channelCount)
        let bins = max(1, Int(size.width))
        for channelIndex in sound.channels.indices {
            let samples = sound.channels[channelIndex]
            guard !samples.isEmpty else { continue }
            let center = (CGFloat(channelIndex) + 0.5) * channelHeight
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: center))
            axis.addLine(to: CGPoint(x: size.width, y: center))
            context.stroke(axis, with: .color(.white.opacity(0.08)), lineWidth: 1)
            var waveform = Path()
            for column in 0..<bins {
                let first = min(samples.count - 1, column * samples.count / bins)
                let last = min(samples.count, max(first + 1, (column + 1) * samples.count / bins))
                var low: Float = 0
                var high: Float = 0
                for index in first..<last {
                    low = min(low, samples[index])
                    high = max(high, samples[index])
                }
                let x = CGFloat(column) + 0.5
                waveform.move(to: CGPoint(x: x, y: center - CGFloat(high) * channelHeight * 0.40))
                waveform.addLine(to: CGPoint(x: x, y: center - CGFloat(low) * channelHeight * 0.40 + 0.5))
            }
            context.stroke(waveform, with: .color(StudioPalette.orange.opacity(0.87)), lineWidth: 1)
        }
    }
}
