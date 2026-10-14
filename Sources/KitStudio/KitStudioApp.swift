import SwiftUI

@main
@MainActor
struct KitStudioApp: App {
    @StateObject private var model = StudioModel()

    var body: some Scene {
        WindowGroup("MPC Kit Studio") {
            StudioView()
                .environmentObject(model)
                .frame(minWidth: 1_100, minHeight: 760)
                .preferredColorScheme(.dark)
                .tint(StudioPalette.orange)
                .onAppear {
                    model.refreshLocations()
                    if model.program == nil { model.newKit() }
                }
        }
        .defaultSize(width: 1_320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouveau kit", action: model.newKit)
                    .keyboardShortcut("n")
                Button("Ouvrir un dossier…", action: model.chooseFolder)
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Exporter le kit…", action: model.exportKit)
                    .keyboardShortcut("s")
                    .disabled(model.program == nil || model.busy)
            }
            CommandGroup(after: .importExport) {
                Button("Importer des samples…", action: model.importAudio)
                    .keyboardShortcut("i")
                    .disabled(model.program == nil || model.busy)
            }
        }
    }
}
