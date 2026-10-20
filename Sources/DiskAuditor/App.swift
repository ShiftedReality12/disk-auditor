import AppKit
import SwiftUI

@main
struct DiskAuditorApp: App {
    @NSApplicationDelegateAdaptor private var delegate: Delegate
    // `open -a "Disk Auditor" --args -scan ~/some/folder` scans that folder.
    // A bare path argument would make AppKit treat it as a document to open,
    // and then no window appears; `-key value` lands in user defaults instead.
    @StateObject private var model = Model(root: UserDefaults.standard.string(forKey: "scan"))

    var body: some Scene {
        Window("Disk Auditor", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Again") { model.rescan() }.keyboardShortcut("r")
                Button("Choose Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Scan Home Folder") { model.scan(model.home) }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Scan Whole Disk") { model.scan("/") }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Back") { model.goBack() }.keyboardShortcut("[")
                Button("Forward") { model.goForward() }.keyboardShortcut("]")
                Button("Enclosing Folder") { model.up() }.keyboardShortcut(.upArrow)
                Divider()
                Button("Look Inside") { model.lookInside() }.keyboardShortcut("i")
                Button("Review Marked…") { model.reviewing = true }.keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.marks.count == 0)
            }
            CommandGroup(after: .toolbar) {
                Button("Draw Fewer Levels") { model.depth = max(1, model.depth - 1) }.keyboardShortcut("[", modifiers: [])
                Button("Draw More Levels") { model.depth = min(6, model.depth + 1) }.keyboardShortcut("]", modifiers: [])
            }
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}
