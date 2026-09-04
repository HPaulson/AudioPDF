import SwiftUI

@MainActor
final class AudioPDFApplicationDelegate: NSObject, NSApplicationDelegate {
    private weak var readerController: ReaderController?
    private var terminationStarted = false

    func register(readerController: ReaderController) {
        self.readerController = readerController
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationStarted else { return .terminateNow }
        terminationStarted = true

        let controller = readerController
        Task { @MainActor in
            await controller?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct AudioPDFApp: App {
    @NSApplicationDelegateAdaptor(AudioPDFApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(applicationDelegate: applicationDelegate)
        }

        Settings {
            SettingsView()
        }
    }
}
