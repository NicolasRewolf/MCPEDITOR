import SwiftUI
import AppKit

@main
@MainActor
struct KitStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @StateObject private var model = StudioModel()

    var body: some Scene {
        WindowGroup("MPC Kit Studio") {
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
        .defaultSize(width: 1_320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouveau kit", action: model.newKit)
                    .keyboardShortcut("n")
                    .disabled(model.documentActionsDisabled)
                Button("Ouvrir un dossier…", action: model.chooseFolder)
                    .keyboardShortcut("o")
                    .disabled(model.documentLocked)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Enregistrer le kit…", action: model.exportKit)
                    .keyboardShortcut("s")
                    .disabled(model.program == nil || model.documentActionsDisabled)
            }
            CommandGroup(after: .importExport) {
                Button("Importer des samples…", action: model.importAudio)
                    .keyboardShortcut("i")
                    .disabled(model.program == nil || model.documentActionsDisabled)
            }
        }
    }
}

@MainActor
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: StudioModel?
    var mainWindow: NSWindow?

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
