import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count {
            Snapshot.run(to: URL(fileURLWithPath: args[flag + 1]))
        } else {
            MirAIeACApp.main()
        }
    }
}

struct MirAIeACApp: App {
    @StateObject private var store = ACStore()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(store)
        } label: {
            MenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// `MirAIeAC --snapshot out.png [--dark]`: draws the live panel into a PNG
/// (used to check the layout without opening the menu).
enum Snapshot {
    /// `--open airflow|features|schedule|energy` renders with that row open.
    static let openSection: Section? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--open"), i + 1 < args.count else { return nil }
        return Section(rawValue: args[i + 1])
    }()

    static func run(to url: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
        MainActor.assumeIsolated {
            let store = ACStore()
            let host = NSHostingView(rootView: PanelView().environmentObject(store)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                host.setFrameSize(host.fittingSize)
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                exit(0)
            }
        }
        app.run()
    }
}
