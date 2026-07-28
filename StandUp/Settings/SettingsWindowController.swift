import AppKit
import SwiftUI

/// Owns the single settings window. SwiftUI's MenuBarExtra + Settings scenes
/// don't work reliably for an LSUIElement (no Dock icon) app, so we manage one
/// NSWindow directly and toggle the activation policy while it's open.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func open(appState: AppState) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(appState: appState))
            let w = NSWindow(contentViewController: hosting)
            w.title = "StandUp Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}