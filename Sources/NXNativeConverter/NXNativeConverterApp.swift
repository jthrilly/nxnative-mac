// nxnative Converter: a Mac app for nxnative's Switch → Mac route (update nxnative, check the tools, convert a dropped game folder with
// build_ipa_from_nsp.py --platform mac-app, install the app into Applications, remember which nxnative built it). This file holds the scenes and the
// application delegate (Dock drops, which bring the window back; the Dock badge of the games still to convert; quitting while something runs; the
// relaunch after a rebuild). It also runs as a bare executable (swift run); the entry point is Main (EntryPoint.swift)
import AppKit
import ConverterCore
import SwiftUI

struct NXNativeConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("nxnative Converter", id: "main") {
            MainWindow()
                .environment(delegate.model)
                .environment(delegate.windowState)
                .frame(minWidth: 900, minHeight: 600)
                .modifier(KeepsWindowOpener(delegate: delegate))
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            AppCommands(model: delegate.model, window: delegate.windowState)
            InspectorCommands()
        }

        Settings {
            SettingsWindow()
                .environment(delegate.model)
        }
    }
}

/// Hands the delegate SwiftUI's way to open the main window, which a Dock drop needs once the window was closed
private struct KeepsWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    func body(content: Content) -> some View {
        content.onAppear { [openWindow] in delegate.openMainWindow = { openWindow(id: "main") } }
    }
}

@MainActor private final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let windowState = WindowState()
    var openMainWindow: (() -> Void)?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)   // a bare executable starts as a background process
        NSApp.activate()
        model.launch()
        trackDockBadge()
    }

    /// The Dock icon's badge: the games in the queue not finished yet, the running one included (those that cannot be converted start as failed)
    private func trackDockBadge() {
        withObservationTracking {
            let remaining = model.jobs.filter { !$0.state.isFinished }.count
            NSApp.dockTile.badgeLabel = remaining > 0 ? "\(remaining)" : nil
        } onChange: {
            Task { @MainActor in self.trackDockBadge() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.addFolders(urls.filter(\.isFileURL))
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshTerminalSessions()
        guard model.recheckWhenActive else { return }
        model.recheckWhenActive = false
        Task { await model.recheck() }
    }

    // Closing the window keeps the app running while something runs (the Dock icon or a drop brings the window back)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { quitPrompt == nil && !model.fetchingInBackground }

    private var quitPrompt: QuitPrompt? {
        QuitRules.prompt(conversion: model.activeJob?.name, installing: model.activeJob?.state == .installing,
                         agent: model.activePortRun.map { (name: $0.kind.displayName, game: $0.gameName) },
                         operations: [model.console.title].compactMap { $0 } + model.portOperations.values.sorted())
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        if let prompt = quitPrompt {
            model.beginQuit()   // nothing starts while the alert is up
            let alert = NSAlert()
            alert.messageText = prompt.message
            alert.informativeText = prompt.informative
            alert.addButton(withTitle: prompt.button)
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else {
                model.cancelQuit()
                return .terminateCancel
            }
        } else if !model.fetchingInBackground {
            return .terminateNow
        }
        quitting = true
        Task {
            await model.stopForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
