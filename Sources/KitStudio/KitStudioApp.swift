import SwiftUI
import AppKit
import Combine

@main
@MainActor
struct KitStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @StateObject private var model = StudioModel()
    @State private var textEditingRevision = 0

    var body: some Scene {
        WindowGroup("MPC Kit Studio") {
            StudioRootView(model: model, appDelegate: appDelegate)
                .onReceive(Publishers.Merge3(
                    NotificationCenter.default.publisher(for: NSText.didChangeNotification),
                    NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification),
                    NotificationCenter.default.publisher(for: NSText.didEndEditingNotification)
                )) { _ in textEditingRevision &+= 1 }
        }
        .defaultSize(width: 1_320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouveau .PGM", action: model.newKit)
                    .keyboardShortcut("n")
                    .disabled(model.documentActionsDisabled)
                Button("Ouvrir un dossier…", action: model.chooseFolder)
                    .keyboardShortcut("o")
                    .disabled(model.documentLocked)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Enregistrer") { _ = model.saveProgram() }
                    .keyboardShortcut("s")
                    .disabled(model.program == nil || model.documentActionsDisabled)
                Button("Copier sur la SD…", action: model.exportKit)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.program == nil || model.documentActionsDisabled)
            }
            StudioUndoCommands(model: model, textEditingRevision: textEditingRevision)
            // Commands taken off the screen stay one menu away.
            CommandMenu("Bibliothèque") {
                Button("Actualiser") { model.refreshLocations() }
                    .keyboardShortcut("r")
                    .disabled(model.libraryScanning)
                Button("Ajouter un dossier de samples…", action: model.chooseSampleFolder)
                    .disabled(model.documentLocked)
                Divider()
                Toggle("Écouter en parcourant avec ↑ ↓", isOn: $model.autoPreviewSamples)
                Button("Arrêter l’écoute", action: model.stop)
                    .keyboardShortcut(".", modifiers: .command)
            }
            CommandGroup(after: .importExport) {
                Button("Importer des samples…", action: model.importAudio)
                    .keyboardShortcut("i")
                    .disabled(model.program == nil || model.documentActionsDisabled)
            }
        }
    }
}

/// SwiftUI names the saved window frame after the scene's content type. A private
/// type in that chain carries a per-build address, so every build stored a new
/// frame key and forgot the window position. This internal root keeps it stable.
struct StudioRootView: View {
    let model: StudioModel
    let appDelegate: StudioAppDelegate

    var body: some View {
        StudioView()
            .environmentObject(model)
            .frame(minWidth: 1_100, minHeight: 760)
            .preferredColorScheme(.dark)
            .tint(StudioPalette.orange)
            .background(WindowCloseGuard(model: model, appDelegate: appDelegate))
            .onAppear {
                appDelegate.model = model
                model.refreshLocations()
                if model.program == nil { model.newKit() }
            }
    }
}

private struct DocumentTextEditingKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var editsProgramDocument: Bool? {
        get { self[DocumentTextEditingKey.self] }
        set { self[DocumentTextEditingKey.self] = newValue }
    }
}

/// Search fields keep native undo; document names, pads and audio share one history.
private struct StudioUndoCommands: Commands {
    @ObservedObject var model: StudioModel
    @FocusedValue(\.editsProgramDocument) private var editsProgramDocument
    let textEditingRevision: Int

    private var textUndoManager: UndoManager? {
        guard editsProgramDocument != true else { return nil }
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable else { return nil }
        return editor.undoManager
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(textUndoManager?.canUndo == true ? "Annuler la saisie" : model.undoTitle) {
                if let manager = textUndoManager, manager.canUndo { manager.undo() }
                else { model.undo() }
            }
            .keyboardShortcut("z")
            .disabled(model.documentActionsDisabled || !(textUndoManager?.canUndo == true || model.canUndo))
            Button(textUndoManager?.canRedo == true ? "Rétablir la saisie" : model.redoTitle) {
                if let manager = textUndoManager, manager.canRedo { manager.redo() }
                else { model.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(model.documentActionsDisabled || !(textUndoManager?.canRedo == true || model.canRedo))
        }
    }
}

@MainActor
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: StudioModel?
    var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One document window shares one model: no tab bar, hence no second window.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !model.documentActionsDisabled else { NSSound.beep(); return .terminateCancel }
        guard model.isDirty else { return .terminateNow }
        model.requestClose { approved in
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: approved) }
        }
        return .terminateLater
    }
}

/// Keep the standard SwiftUI window delegate for all events except the document close guard.
private struct WindowCloseGuard: NSViewRepresentable {
    let model: StudioModel
    let appDelegate: StudioAppDelegate

    func makeCoordinator() -> Coordinator { Coordinator(model: model, appDelegate: appDelegate) }

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.attach = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }

    func updateNSView(_ view: WindowObserverView, context: Context) {
        if let window = view.window { context.coordinator.attach(to: window) }
    }

    final class WindowObserverView: NSView {
        var attach: (@MainActor (NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach?(window) }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var model: StudioModel?
        weak var appDelegate: StudioAppDelegate?
        weak var previousDelegate: NSWindowDelegate?

        init(model: StudioModel, appDelegate: StudioAppDelegate) {
            self.model = model
            self.appDelegate = appDelegate
        }

        @MainActor
        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            previousDelegate = window.delegate
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            appDelegate?.mainWindow = window
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard previousDelegate?.windowShouldClose?(sender) != false else { return false }
            guard let model else { return true }
            guard !model.documentActionsDisabled else { NSSound.beep(); return false }
            guard model.isDirty else { model.stop(); return true }
            model.requestClose { [weak sender] approved in
                if approved { sender?.close() }
            }
            return false
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? { previousDelegate }
    }
}
