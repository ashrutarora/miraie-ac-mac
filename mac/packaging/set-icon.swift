// Gives a file the icon of an app: swift set-icon.swift <app> <file>
// Used to show the Privacy & Security shortcut with System Settings' icon.
import AppKit
let args = CommandLine.arguments
let icon = NSWorkspace.shared.icon(forFile: args[1])
if !NSWorkspace.shared.setIcon(icon, forFile: args[2], options: []) { exit(1) }
