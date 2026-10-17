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

struct StudioView: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                LibraryBrowser()
                    .frame(width: 300)
                Divider()
                workspace
            }
            statusBar
        }
        .background(StudioPalette.background)
        .toolbar {
            ToolbarItemGroup {
                Button(action: model.newKit) { Label("Nouveau kit", systemImage: "plus") }
                    .help("Créer un programme vide")
                    .disabled(model.documentActionsDisabled)
                Button(action: model.importAudio) { Label("Importer", systemImage: "square.and.arrow.down") }
                    .disabled(model.program == nil || model.documentActionsDisabled)
                Button(action: model.exportKit) { Label("Enregistrer une copie…", systemImage: "square.and.arrow.up") }
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
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(alignment: .top, spacing: 18) {
                padPanel
                    .frame(width: 310)
                SampleEditor()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("MPC KIT STUDIO")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(StudioPalette.orange)
                HStack(spacing: 9) {
                    TextField("Nom du kit", text: Binding(
                        get: { model.kitName },
                        set: { model.setKitName($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .accessibilityLabel("Nom du kit")
                    .disabled(model.program == nil || model.documentActionsDisabled)
                    if model.isDirty {
                        Circle().fill(StudioPalette.orange).frame(width: 7, height: 7)
                            .help("Modifications non exportées")
                    }
                }
                HStack(spacing: 7) {
                    Image(systemName: model.kitLocationPath.isEmpty ? "square.grid.3x3" : "externaldrive")
                    Text(model.kitLocationLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !model.kitLocationPath.isEmpty {
                        Button("Finder", action: model.revealKitLocation)
                            .buttonStyle(.borderless)
                            .help(model.kitLocationPath)
                            .accessibilityLabel("Afficher le kit dans le Finder")
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
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(model.memoryBytes), countStyle: .memory))
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                Text("EXPORT · PCM 16 BITS / 44,1 kHz")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(StudioPalette.muted)
            }
        }
    }

    private var padPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                sectionTitle("BANQUE")
                Spacer()
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
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(0..<16) { position in
                    let localPad = (3 - position / 4) * 4 + position % 4
                    let index = model.bank * 16 + localPad
                    PadButton(
                        number: localPad + 1,
                        name: model.padName(index),
                        selected: model.selectedPad == index,
                        missing: model.padIsMissing(index),
                        onPress: { model.selectPad(index); model.playPad(index) },
                        onDropFiles: { model.dropFiles($0, onPad: index) }
                    )
                }
            }
            .disabled(model.program == nil || model.documentActionsDisabled)
            HStack(spacing: 8) {
                Label("Glisse un son sur un pad", systemImage: "arrow.down.doc")
                    .font(.caption)
                    .foregroundStyle(StudioPalette.muted)
                Spacer(minLength: 0)
                Button(action: model.clearPad) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(StudioPalette.muted)
                .disabled(model.program == nil || model.documentActionsDisabled)
                .help("Vider le pad sélectionné")
                .accessibilityLabel("Vider le pad sélectionné")
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 8) {
                Label(model.kitLocationLabel, systemImage: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .help(model.kitLocationPath)
                Text(model.isDirty ? "Modifications à enregistrer" : "Aucune modification en attente")
                    .font(.caption)
                    .foregroundStyle(model.isDirty ? StudioPalette.orange : StudioPalette.muted)
                Text("\(model.assignedPadCount) pad(s) affecté(s) · \(ByteCountFormatter.string(fromByteCount: model.estimatedExportBytes, countStyle: .file)) à enregistrer")
                    .font(.caption)
                    .foregroundStyle(StudioPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Enregistrer une copie…", action: model.exportKit)
                    .buttonStyle(.bordered)
                    .disabled(model.program == nil || model.documentActionsDisabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            if model.busy {
                ProgressView().controlSize(.small).scaleEffect(0.75)
            } else {
                Circle().fill(StudioPalette.orange).frame(width: 5, height: 5)
            }
            Text(model.status)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(StudioPalette.muted)
            if model.resolvingDroppedFiles {
                Button("Annuler le dépôt", action: model.cancelDroppedFiles)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Annuler la lecture des fichiers déposés")
            }
            Spacer()
            Text("Préécoute Float ; filtre et enveloppes à vérifier sur la MPC.")
                .font(.system(size: 10))
                .foregroundStyle(StudioPalette.muted)
                .lineLimit(1)
                .help("La préécoute joue le PCM Float de travail avec son accordage. L’export le quantifie en PCM 16 bits. Le moteur audio de la MPC3000 n’est pas simulé.")
        }
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(StudioPalette.inset)
        .overlay(alignment: .top) { Rectangle().fill(StudioPalette.border).frame(height: 1) }
    }

    private func sectionTitle(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(StudioPalette.muted)
    }
}

private struct PadButton: View {
    let number: Int
    let name: String
    let selected: Bool
    let missing: Bool
    let onPress: () -> Void
    let onDropFiles: ([NSItemProvider]) -> Bool
    @State private var dropTarget = false

    var body: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(String(format: "%02d", number))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(selected ? StudioPalette.orange : StudioPalette.muted)
                    Spacer()
                    if missing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                    }
                }
                Spacer(minLength: 0)
                Text(name.isEmpty ? "—" : name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(name.isEmpty ? StudioPalette.muted : Color.white)
            }
            .padding(10)
            .frame(height: 80)
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
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget, perform: onDropFiles)
        .accessibilityLabel("Pad \(number), \(name.isEmpty ? "vide" : name)\(missing ? ", sample introuvable" : "")")
        .accessibilityHint("Écouter et sélectionner le pad")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SampleEditor: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ÉDITION DU SAMPLE")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(StudioPalette.muted)
                    Text(model.selectedLabel)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    if model.sound != nil {
                        TextField("Nom du sample", text: Binding(
                            get: { model.sound?.name ?? "" }, set: { model.setSoundName($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, weight: .medium))
                        .accessibilityLabel("Nom du sample du pad \(model.selectedLabel)")
                        .help(model.sound?.name ?? "")
                        .disabled(model.busy)
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
            ScrollView(.vertical, showsIndicators: true) {
                if let sound = model.sound, sound.frameCount > 0 {
                    if let warning = model.selectedAudioRangeWarning {
                        Text("Crête \(String(format: "%.2f", warning.report.peakMagnitude)) : ce sample dépasse le niveau du PCM 16 bits. Normalise-le avant l’export pour éviter l’écrêtage.")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    loadedEditor(sound)
                } else {
                    emptyEditor
                }
            }
            .scrollIndicators(.visible)
        }
        .padding(20)
        .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(StudioPalette.border) }
    }

    private func loadedEditor(_ sound: MPCSound) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            WaveformView(sound: sound, onTrim: model.setTrim)
                .frame(height: 210)
                .background(StudioPalette.inset, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Forme d’onde du sample, début \(sound.start), fin \(sound.end)")
            HStack {
                Label(String(format: "%.3f s", Double(sound.frameCount) / 44_100), systemImage: "waveform")
                Spacer()
                Text("\(sound.frameCount.formatted()) points")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(StudioPalette.muted)
            trimControls(sound)
            HStack(spacing: 8) {
                Button { model.playPad(model.selectedPad) } label: { Label("Écouter", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                Button(action: model.stop) { Image(systemName: "stop.fill") }
                    .buttonStyle(.bordered)
                    .help("Arrêter la lecture")
                Spacer()
                Text(String(format: "Sélection : %.3f s", Double(max(0, sound.end - sound.start)) / 44_100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StudioPalette.muted)
            }
            Divider()
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
        VStack(spacing: 12) {
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

    private var transformControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TRAITEMENT AUDIO")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(StudioPalette.muted)
            HStack(spacing: 7) {
                operation("Découper", symbol: "scissors", kind: "trim")
                operation("Normaliser", symbol: "waveform", kind: "normalize")
                operation("Mono", symbol: "speaker.wave.1", kind: "mono")
            }
            HStack(spacing: 7) {
                operation("Petits fondus", symbol: "waveform.path", kind: "fade")
                operation("Inverser", symbol: "backward.end", kind: "reverse")
            }
            Text("Les traitements modifient le son du kit en cours. L’export crée de nouveaux fichiers et conserve les originaux.")
                .font(.caption)
                .foregroundStyle(StudioPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func operation(_ title: String, symbol: String, kind: String) -> some View {
        Button { model.transform(kind) } label: {
            Label(title, systemImage: symbol).font(.system(size: 11))
        }
        .buttonStyle(.bordered)
    }

    private var emptyEditor: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundStyle(StudioPalette.orange.opacity(0.75))
            Text("Donne un son à ce pad")
                .font(.system(size: 17, weight: .medium, design: .rounded))
            Text("Glisse un WAV, AIFF ou SND sur le pad,\nou importe un sample depuis ton Mac.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .foregroundStyle(StudioPalette.muted)
            Button("Importer un sample…", action: model.importAudio)
                .buttonStyle(.bordered)
                .disabled(model.program == nil || model.documentActionsDisabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 430)
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
