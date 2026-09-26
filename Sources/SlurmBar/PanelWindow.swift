import AppKit
import SwiftUI

/// The same panel in an ordinary window. On a Mac with a notch and a full menu bar, the menu bar
/// icon can end up hidden behind the notch, so SlurmBar opens this window on first run and whenever
/// it is opened again (from Finder or Spotlight) while already running.
@MainActor
final class PanelWindow {
    static let shared = PanelWindow()
    private var window: NSWindow?

    func show() {
        guard let model = AppModel.current else { return }
        if window == nil {
            let host = NSHostingController(rootView: PopoverView(model: model, inWindow: true))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "SlurmBar"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.current?.applyDockIcon()
        // first run: a small icon in a crowded menu bar is easy to miss, so start with a window
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if AppModel.current?.needsSetup == true { PanelWindow.shared.show() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PanelWindow.shared.show()
        return false
    }
}
