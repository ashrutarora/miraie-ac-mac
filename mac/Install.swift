import AppKit

/// Tidies up after installing from the disk image, the way a .pkg installer
/// offers to: run from the disk image, it offers to move itself to
/// Applications; run from Applications while the disk image is still mounted,
/// it offers to eject it and put it in the Trash.
enum Install {
    static let volumeName = "MirAIe AC"
    static let applications = URL(fileURLWithPath: "/Applications/MirAIe AC.app")

    static func tidyUp() {
        let path = Bundle.main.bundlePath
        // A quarantined app opened from a disk image runs from a randomised
        // "AppTranslocation" copy, so both cases count as "not installed yet".
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            offerMoveToApplications()
        } else if path == applications.path, let image = mountedImage() {
            offerTrashDiskImage(image)
        }
    }

    private static func offerMoveToApplications() {
        let source = URL(fileURLWithPath: "/Volumes/\(volumeName)/MirAIe AC.app")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let choice = ask("Move MirAIe AC to Applications?",
                         "It's running from the disk image, so it won't be there after you eject it.",
                         ["Move to Applications", "Not Now"])
        guard choice == .alertFirstButtonReturn else { return }
        do {
            if FileManager.default.fileExists(atPath: applications.path) {
                try FileManager.default.trashItem(at: applications, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: source, to: applications)
            NSWorkspace.shared.openApplication(at: applications, configuration: .init()) { _, _ in exit(0) }
            RunLoop.main.run(until: Date().addingTimeInterval(5))
        } catch {
            _ = ask("Couldn't move it", "Drag MirAIe AC to Applications yourself. (\(error.localizedDescription))", ["OK"])
        }
    }

    private static func offerTrashDiskImage(_ image: URL) {
        let choice = ask("MirAIe AC is installed",
                         "Eject the disk image and move \(image.lastPathComponent) to the Trash?",
                         ["Move to Trash", "Keep"])
        guard choice == .alertFirstButtonReturn else { return }
        run("/usr/bin/hdiutil", ["detach", "/Volumes/\(volumeName)"])
        try? FileManager.default.trashItem(at: image, resultingItemURL: nil)
    }

    /// The disk image file behind /Volumes/MirAIe AC, if it is mounted.
    private static func mountedImage() -> URL? {
        guard FileManager.default.fileExists(atPath: "/Volumes/\(volumeName)"),
              let data = run("/usr/bin/hdiutil", ["info", "-plist"]),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]]
        else { return nil }
        for image in images {
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            if entities.contains(where: { $0["mount-point"] as? String == "/Volumes/\(volumeName)" }),
               let path = image["image-path"] as? String {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func ask(_ title: String, _ message: String, _ buttons: [String]) -> NSApplication.ModalResponse {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.icon = NSApp.applicationIconImage
        for button in buttons { alert.addButton(withTitle: button) }
        return alert.runModal()
    }
}
