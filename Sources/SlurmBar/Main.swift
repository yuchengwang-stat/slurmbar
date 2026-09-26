import AppKit
import SlurmBarCore
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            let live = args.contains("--live")
            _ = NSApplication.shared
            Task { @MainActor in
                await Snapshot.render(to: dir, live: live)
                exit(0)
            }
            RunLoop.main.run()
        } else {
            Launch.demo = args.contains("--demo")
            SlurmBarApp.main()
        }
    }
}

enum Launch {
    nonisolated(unsafe) static var demo = false
}

struct SlurmBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(mode: Launch.demo ? .demo : .live)

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
