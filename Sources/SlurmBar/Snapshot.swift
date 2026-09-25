import AppKit
import SlurmBarCore
import SwiftUI

/// `SlurmBar --render <dir>` draws the README images from demo data (or, with --live, from your config).
@MainActor
enum Snapshot {
    static func render(to dir: URL, live: Bool) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(mode: live ? .live : .demo, autostart: false)
        await model.refreshAll()
        write(Showcase(model: model).environment(\.colorScheme, .light), "showcase-light.png", in: dir)
        write(Showcase(model: model).environment(\.colorScheme, .dark), "showcase-dark.png", in: dir)
        write(AppIconView(), "icon-1024.png", in: dir, scale: 1)
    }

    static func write<V: View>(_ view: V, _ name: String, in dir: URL, scale: CGFloat = 2) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("could not render \(name)")
            return
        }
        let url = dir.appendingPathComponent(name)
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}

/// The popover under a pretend menu bar, for the README.
struct Showcase: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            FakeMenuBar(model: model)
            PopoverView(model: model, renderMode: true)
                .background(scheme == .dark ? Color(white: 0.15) : Color(white: 0.975))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.22), radius: 22, y: 10)
                .padding(.trailing, 112)
                .padding(.bottom, 44)
        }
        .frame(width: 620)
        .environment(\.isSnapshot, true)
        .background(LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.10, green: 0.11, blue: 0.20), Color(red: 0.25, green: 0.13, blue: 0.27)]
                : [Color(red: 0.55, green: 0.70, blue: 0.93), Color(red: 0.90, green: 0.74, blue: 0.84)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

struct FakeMenuBar: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "applelogo")
            Spacer()
            MenuBarLabel(model: model)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.13)))
            Image(systemName: "wifi")
            Image(systemName: "battery.100")
            Text("Thu Sep 25  4:12 PM")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.45))
    }
}

struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.21, green: 0.25, blue: 0.35), Color(red: 0.07, green: 0.08, blue: 0.13)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            Image(systemName: "server.rack")
                .font(.system(size: 400, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.95))
            Circle()
                .fill(Color(red: 0.20, green: 0.84, blue: 0.40))
                .frame(width: 170, height: 170)
                .overlay(Circle().strokeBorder(Color(red: 0.07, green: 0.08, blue: 0.13), lineWidth: 24))
                .offset(x: 250, y: 250)
        }
        .frame(width: 1024, height: 1024)
    }
}
