import AppKit
import AuditorCore
import SwiftUI

// MARK: window

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            Banners(model: model)
            InfoLine(model: model, hover: model.hover)
            ZStack {
                TreemapView(model: model)
                if model.showAccessCard { AccessCard(model: model) }
                if model.scanning { ScanningCard(model: model) }
                if case .failed(let message) = model.phase { Text(message).foregroundStyle(.secondary) }
                if let outcome = model.last {
                    VStack { Spacer(); OutcomeToast(model: model, outcome: outcome).padding(16) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Theme.canvas)
        .toolbar { Toolbar(model: model, showInspector: $showInspector) }
        .searchable(text: $model.filter, placement: .toolbar, prompt: "Filter by name")
        .inspector(isPresented: $showInspector) {
            InspectorPanel(model: model)
                .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
        }
        // Opaque, so the inspector's content never shows through the bar.
        .toolbarBackground(.visible, for: .windowToolbar)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.reviewing) { ReviewView(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckAccess()
        }
        .animation(.easeOut(duration: 0.2), value: model.last?.message)
    }
}

struct Toolbar: ToolbarContent {
    @ObservedObject var model: Model
    @Binding var showInspector: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(model.back.isEmpty)
                Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(model.forward.isEmpty)
            }
            .controlGroupStyle(.navigation)
            .help("Back and forward (⌘[ ⌘])")
        }
        ToolbarItem(placement: .principal) {
            PathBar(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Depth", selection: $model.depth) {
                    ForEach(1...6, id: \.self) { Text("\($0) level\($0 == 1 ? "" : "s")").tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Depth \(model.depth)", systemImage: "square.stack.3d.down.right")
                    .labelStyle(.titleAndIcon)
            }
            .help("Levels drawn at once ([ and ])")
            Menu {
                Button("Home Folder") { model.scan(model.home) }
                Button("Whole Disk") { model.scan("/") }
                Divider()
                Button("Choose Folder…") { model.chooseFolder() }
                Divider()
                Button("Scan Again") { model.rescan() }
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            } primaryAction: {
                model.rescan()
            }
            .help("Scan again; hold for other places")
            .disabled(model.scanning)
            if model.marks.count > 0 {
                Button { model.reviewing = true } label: {
                    Text("Review \(model.marks.count) · \(Format.size(model.marks.total))")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.amber)
                .foregroundStyle(.black)
                .help("Review what is marked before anything moves (⇧⌘R)")
            }
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector")
        }
    }
}

/// The trail from the scanned root, Finder-style: every crumb opens it.
struct PathBar: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 3) {
            let trail = model.trail
            ForEach(Array(trail.enumerated()), id: \.offset) { index, node in
                if index > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).font(.caption) }
                Button {
                    model.open(node)
                } label: {
                    Text(index == 0 ? model.pretty(node.path) : node.name)
                        .fontWeight(index == trail.count - 1 ? .semibold : .regular)
                        .foregroundStyle(index == trail.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            if let current = model.current {
                Text(Format.size(current.bytes)).monospacedDigit().foregroundStyle(.secondary).padding(.leading, 6)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: 520)
    }
}

/// One slim line over the map: what the pointer is on, or the scan's
/// totals; and what the colours mean.
struct InfoLine: View {
    @ObservedObject var model: Model
    @ObservedObject var hover: Hover

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let node = hover.node {
                    HStack(spacing: 6) {
                        Swatch(color: node.category.accent)
                        Text(model.pretty(node.path)).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary)
                        Text(Format.size(node.bytes)).monospacedDigit()
                    }
                } else if !model.filter.isEmpty {
                    Text(model.matchCount == 0 ? "No matches" : "\(model.matchCount) match\(model.matchCount == 1 ? "" : "es") · \(Format.size(model.matchBytes))")
                        .foregroundStyle(Theme.amber)
                } else if let scan = model.scan {
                    Text("\(Format.size(scan.root.bytes)) · \(scan.root.files.formatted(.number.notation(.compactName))) files · read in \(String(format: "%.1f", scan.seconds)) s")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Legend(model: model)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
    }
}

struct Legend: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 11) {
            HStack(spacing: 4) { HatchSwatch(); Text("Reclaimable") }
            ForEach(present, id: \.self) { c in
                HStack(spacing: 4) { Swatch(color: c.accent); Text(c.label) }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var present: [AuditorCore.Category] {
        guard let scan = model.scan else { return [] }
        let totals = Classify.totals(scan.root)
        return AuditorCore.Category.allCases.filter { $0 != .other && (totals[$0] ?? 0) > scan.root.bytes / 200 }
    }
}

struct Swatch: View {
    let color: Color
    var body: some View { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9) }
}

struct HatchSwatch: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.3)))
            var p = Path()
            for x in stride(from: -9.0, to: 9, by: 3) { p.move(to: CGPoint(x: x, y: 9)); p.addLine(to: CGPoint(x: x + 9, y: 0)) }
            ctx.stroke(p, with: .color(.white.opacity(0.55)), lineWidth: 1)
        }
        .frame(width: 9, height: 9)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

// MARK: overlays

struct Banners: View {
    @ObservedObject var model: Model

    var body: some View {
        if model.needsRelaunch {
            Banner(icon: "checkmark.shield.fill", tint: .green, text: "Full Disk Access is on. Relaunch once to count everything.") {
                Button("Relaunch") { model.relaunch() }
            }
        } else if let scan = model.scan, scan.unreadable > 0, !model.scanning, !model.fullAccess {
            Banner(icon: "lock.fill", tint: .orange, text: "macOS hid \(scan.unreadable) folders from the scan. Allow Full Disk Access to count them.") {
                Button("Open Settings") { model.openFullDiskAccess() }
            }
        }
    }
}

struct Banner<Action: View>: View {
    let icon: String
    let tint: Color
    let text: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer()
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(0.1))
    }
}

struct ScanningCard: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .scanning(let what) = model.phase {
                Text("Scanning \(what)").font(.headline)
            }
            if model.expected > 0 {
                ProgressView(value: min(1, Double(model.progress) / Double(model.expected))).tint(Theme.amber)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Theme.amber)
            }
            Text("\(model.progress.formatted()) entries read")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AccessCard: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Allow Full Disk Access once", systemImage: "lock.open").font(.title3.weight(.semibold))
            Text("So every folder is counted, and macOS stops asking about Desktop, Documents, Downloads and other apps' data one prompt at a time. It stays granted for every later version.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Open Settings, turn on Disk Auditor (or add it with +), then relaunch.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings") { model.openFullDiskAccess() }.buttonStyle(.borderedProminent)
                Button("Show App in Finder") { model.showInFinder(Bundle.main.bundlePath) }
                Spacer()
                Button("Scan Without It") { model.scanWithoutFullAccess() }.buttonStyle(.link)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct OutcomeToast: View {
    @ObservedObject var model: Model
    let outcome: Model.Outcome

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.message).font(.headline)
                Text(outcome.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !outcome.trashed.isEmpty { Button("Undo") { model.undo() }.keyboardShortcut("z") }
            Button { model.dismissOutcome() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}

// MARK: review

struct ReviewView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Model.Item] = []
    @State private var copied = false
    @State private var working = false

    private var toTrash: [Model.Item] { items.filter { $0.include && $0.ok && $0.clean == nil } }
    private var toClean: [Model.Item] { items.filter { $0.include && $0.ok && $0.clean != nil } }
    private var checking: Bool { items.contains { $0.verdict == nil } }
    private var largest: UInt64 { items.map(\.bytes).max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review").font(.title2.weight(.semibold))
                Text("Folders go to the Trash, and Undo puts them back. A folder its tool owns is reclaimed by that tool's own cleaner, which cannot be undone.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($items) { $item in
                        ReviewRow(model: model, item: $item, largest: largest)
                        Divider().padding(.leading, 44)
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(copied ? "Copied" : "Copy Agent Prompt") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.agentPrompt(items.filter(\.include)), forType: .string)
                    copied = true
                }
                .help("A checked hand-off for Claude or Codex instead of acting here")
                Spacer()
                if working || checking { ProgressView().controlSize(.small) }
                if !toClean.isEmpty {
                    Button("Run \(toClean.count) Cleaner\(toClean.count == 1 ? "" : "s")…") {
                        guard confirmCleaners() else { return }
                        working = true
                        Task {
                            await model.clean(toClean)
                            working = false
                            dismiss()
                        }
                    }
                    .disabled(checking || working)
                }
                if !toTrash.isEmpty {
                    Button("Move \(toTrash.count) to Trash · \(Format.size(toTrash.reduce(0) { $0 + $1.bytes }))") {
                        model.trash(toTrash)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.amber)
                    .foregroundStyle(.black)
                    .disabled(checking || working)
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 480)
        .task {
            items = model.reviewItems()
            let home = model.home
            await withTaskGroup(of: (Int, Model.Item.Verdict).self) { group in
                for (i, item) in items.enumerated() {
                    group.addTask { (i, await Task.detached { Model.verdict(for: item, home: home) }.value) }
                }
                for await (i, verdict) in group {
                    items[i].verdict = verdict
                    if case .refused = verdict { items[i].include = false }
                }
            }
        }
    }

    /// A cleaner cannot be undone, so it is asked in a plain modal alert
    /// (always shown, unlike a dialog stacked on a sheet) whose default
    /// button is Cancel: Return and Esc both leave everything as it is.
    private func confirmCleaners() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run " + toClean.compactMap { $0.clean?.joined(separator: " ") }.joined(separator: " and ") + "?"
        alert.informativeText = "A cleaner deletes what its tool can fetch or rebuild again. It cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Run").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}

struct ReviewRow: View {
    @ObservedObject var model: Model
    @Binding var item: Model.Item
    let largest: UInt64

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $item.include).toggleStyle(.checkbox).labelsHidden().disabled(!item.ok)
            VStack(alignment: .leading, spacing: 3) {
                Text((item.path as NSString).lastPathComponent).fontWeight(.medium)
                Text(model.pretty((item.path as NSString).deletingLastPathComponent))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Group {
                    switch item.verdict {
                    case nil: Text("Checking…").foregroundStyle(.secondary)
                    case .ok?:
                        if let clean = item.clean {
                            Text("Runs \(clean.joined(separator: " "))").foregroundStyle(.orange)
                        } else {
                            Text("Goes to the Trash").foregroundStyle(.green)
                        }
                    case .refused(let why)?:
                        Text("Kept: \(why)").foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.caption)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text((item.clean == nil ? "" : "up to ") + Format.size(item.bytes)).monospacedDigit().fontWeight(.medium)
                ShareBar(fraction: Double(item.bytes) / Double(max(largest, 1)), color: Theme.amber).frame(width: 80)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

struct ShareBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 3)
    }
}
