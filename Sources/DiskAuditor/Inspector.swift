import AppKit
import AuditorCore
import SwiftUI

struct InspectorPanel: View {
    @ObservedObject var model: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SelectionSection(model: model)
                if model.inside != nil || model.lookingInside { InsideSection(model: model) }
                WorthSection(model: model)
                DiskSection(model: model)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.never)
        .modifier(HardTopEdge())
        // The panel's content stops at its own top edge: nothing shows
        // through the toolbar's glass.
        .clipped()
    }
}

/// On macOS 26 content scrolls under the glass toolbar with a soft fade,
/// which over this panel reads as stray text; the hard edge is Apple's
/// alternative for dense content.
struct HardTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

/// Small capitals over a section, as the reference sets them.
struct SectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.amber)
            }
        }
    }
}

// MARK: selection

struct SelectionSection: View {
    @ObservedObject var model: Model

    var body: some View {
        if let node = model.selected ?? model.current {
            let total = max(model.scan?.root.bytes ?? 1, 1)
            let share = Double(node.bytes) / Double(total)
            let finding = model.covering(node)
            let isRoot = node === model.scan?.root
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "Selection")
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(isRoot ? Theme.amber : node.category.accent).frame(width: 3, height: 20)
                    Text(isRoot ? model.pretty(node.path) : node.name)
                        .font(.system(size: 18, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                }
                if !isRoot {
                    Text(model.pretty((node.path as NSString).deletingLastPathComponent))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                BigSize(bytes: node.bytes)
                ShareBar(fraction: share, color: Theme.amber)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        Stat(label: "Of scan", value: share >= 0.999 ? "100%" : String(format: share < 0.001 ? "<0.1%" : "%.1f%%", share * 100))
                        Stat(label: "Files", value: node.files.formatted(.number.notation(.compactName)))
                    }
                    GridRow {
                        Stat(label: "Last write", value: Format.age(Int(max(0, Date().timeIntervalSince1970 - Double(node.newest)) / 86_400)))
                        Stat(label: "Kind", value: isRoot ? "Everything" : node.category.label)
                    }
                }
                if let f = finding, f.advice == nil {
                    Callout(icon: f.safe ? "checkmark.seal.fill" : "info.circle", tint: f.safe ? .green : .secondary) {
                        Text(f.why)
                        if let git = f.git {
                            Text(git.summary).foregroundStyle(git.isClean ? Color.secondary : Theme.danger)
                        }
                        if let clean = f.clean {
                            Text(clean.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                if let a = model.advice[node.path] { AdviceCallout(advice: a) }
                if !isRoot {
                    HStack(spacing: 8) {
                        if let cover = model.marks.covering(node.path) {
                            Button("Unmark Parent") { model.marks.remove(cover) }
                                .help("Inside \((cover as NSString).lastPathComponent), which is marked")
                        } else {
                            let marked = model.marks.contains(node.path)
                            Button(marked ? "Unmark" : "Mark") { model.toggleMark(node) }
                                .keyboardShortcut(.space, modifiers: [])
                                .help("Mark for removal (Space). Nothing moves until you review.")
                                .buttonStyle(.borderedProminent)
                                .tint(marked ? .gray : Theme.amber)
                                .foregroundStyle(marked ? .white : .black)
                        }
                        if node.isDir {
                            Button("Look Inside") { model.lookInside() }
                                .keyboardShortcut("i", modifiers: [.command])
                                .disabled(model.lookingInside || model.inside?.path == node.path)
                        }
                        Spacer()
                        Button { model.showInFinder(node.path) } label: { Image(systemName: "folder") }
                            .help("Show in Finder")
                        if node.isDir && node !== model.current {
                            Button { model.open(node) } label: { Image(systemName: "arrow.down.right.square") }
                                .keyboardShortcut(.return, modifiers: [])
                                .help("Open in the map (Return)")
                        }
                    }
                    .controlSize(.regular)
                }
            }
        }
    }
}

struct BigSize: View {
    let bytes: UInt64

    var body: some View {
        let text = Format.size(bytes)
        let parts = text.split(separator: " ")
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(parts.first.map(String.init) ?? text).font(.system(size: 42, weight: .light)).monospacedDigit()
            if parts.count > 1 { Text(String(parts[1])).font(.system(size: 17)).foregroundStyle(.secondary) }
        }
    }
}

struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 10, weight: .medium)).tracking(0.6).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 14)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Callout<Content: View>: View {
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) { content }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AdviceCallout: View {
    let advice: Advice

    var body: some View {
        Callout(icon: "sparkles", tint: .purple) {
            Text(advice.what + (advice.owner.map { " · \($0)" } ?? "")).fontWeight(.medium)
            Text(advice.why).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Tag(text: advice.verdict.rawValue.replacingOccurrences(of: "_", with: " "))
                Tag(text: advice.action.rawValue)
                Text("\(Int(advice.confidence * 100))% sure").font(.caption).foregroundStyle(.tertiary)
            }
            if let command = advice.command {
                Text(command).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.white.opacity(0.08), in: Capsule())
    }
}

// MARK: inside

struct InsideSection: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Inside")
                if model.lookingInside { ProgressView().controlSize(.small) }
            }
            if let inside = model.inside {
                Reliances(items: inside.reliance)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Made of").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    let top = inside.types.first?.bytes ?? 1
                    ForEach(inside.types, id: \.ext) { t in
                        HStack(spacing: 8) {
                            Text(t.ext == "(none)" ? "no extension" : "." + t.ext).frame(width: 90, alignment: .leading).lineLimit(1)
                            ShareBar(fraction: Double(t.bytes) / Double(max(top, 1)), color: Color.white.opacity(0.35))
                            Text(Format.size(t.bytes)).monospacedDigit().frame(width: 62, alignment: .trailing)
                        }
                        .font(.caption)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Largest files").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(inside.largest.prefix(5), id: \.self) { f in
                        Button {
                            model.showInFinder(inside.path + "/" + f.path)
                        } label: {
                            HStack {
                                Text((f.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Format.size(f.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .help(f.path)
                    }
                }
                if !inside.excerpts.isEmpty {
                    DisclosureGroup("Peek at contents") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(inside.excerpts, id: \.self) { e in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(e.path).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                    Text(e.text.map { String($0.prefix(360)) } ?? "\(e.kind) file")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(6)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption)
                }
                if model.judging {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Asking Claude…").font(.caption).foregroundStyle(.secondary) }
                } else if let error = model.judgeError {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                } else {
                    Button {
                        model.askAI()
                    } label: {
                        Label(model.advice[inside.path] == nil ? "Ask AI What This Is" : "Ask AI Again", systemImage: "sparkles")
                    }
                    .help("Sends these file types, names and short excerpts (secrets removed) to Claude. Nothing is run.")
                }
                if inside.truncated {
                    Text("Very large: the numbers describe what was read in 4 seconds.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct Reliances: View {
    let items: [Reliance]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Relies on it").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if items.isEmpty {
                Label("Nothing found: no open files, launch jobs, config mentions or links", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            ForEach(items, id: \.self) { r in
                Label(r.detail, systemImage: icon(r.kind))
                    .foregroundStyle(r.blocking ? Theme.danger : (r.detail.contains("left behind") ? Theme.amber : .secondary))
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func icon(_ kind: Reliance.Kind) -> String {
        switch kind {
        case .process: return "bolt.fill"
        case .launchd: return "clock.arrow.circlepath"
        case .config: return "doc.text"
        case .symlink: return "link"
        case .app: return "app.dashed"
        case .git: return "arrow.triangle.branch"
        }
    }
}

// MARK: worth a look

struct WorthSection: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Worth a look", trailing: model.findings.isEmpty ? nil : Format.size(model.findings.reduce(0) { $0 + $1.bytes }))
                Menu {
                    Button("Mark Everything Regenerable (✓)") {
                        for f in model.findings where f.safe && !model.marks.contains(f.path) { model.toggleMark(f) }
                    }
                    .disabled(model.checkingGit)
                    Button("Explain the Rest with AI") { model.explain() }
                        .disabled(model.advising || model.unexplainedBytes == 0)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            AIStatus(model: model)
            let largest = model.findings.first?.bytes ?? 1
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.findings, id: \.path) { f in
                    WorthRow(model: model, finding: f, largest: largest)
                }
            }
        }
    }
}

struct AIStatus: View {
    @ObservedObject var model: Model

    var body: some View {
        if model.advising {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Asking Claude about \(model.suspects.count) folders…").foregroundStyle(.secondary)
            }
            .font(.caption)
        } else if let error = model.adviceError {
            Text(error).font(.caption).foregroundStyle(Theme.danger)
        } else if model.unexplainedBytes > 0 {
            Button {
                model.explain()
            } label: {
                Label("\(Format.size(model.unexplainedBytes)) no rule explains. Ask AI", systemImage: "sparkles")
            }
            .buttonStyle(.link)
            .font(.caption)
            .help("Sends folder names, sizes and ages (never contents) to Claude; answers are advice")
        }
    }
}

struct WorthRow: View {
    @ObservedObject var model: Model
    let finding: Finding
    let largest: UInt64
    @State private var hovering = false

    var body: some View {
        let marked = model.marks.contains(finding.path)
        let covered = model.marks.covering(finding.path) != nil
        let selected = model.selected?.path == finding.path
        let node = model.node(at: finding.path)
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { marked || covered }, set: { _ in model.toggleMark(finding) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(covered)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(model.label(for: finding)).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.head)
                    if finding.safe { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.system(size: 10)) }
                    if finding.advice != nil { Image(systemName: "sparkles").foregroundStyle(.purple).font(.system(size: 10)) }
                    if let git = finding.git, !git.isClean {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).font(.system(size: 10))
                            .help(git.summary)
                    }
                }
                Text(finding.advice.map { $0.what } ?? finding.why)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 5) {
                Text(Format.size(finding.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                ShareBar(fraction: Double(finding.bytes) / Double(max(largest, 1)), color: node?.category.accent ?? .gray)
                    .frame(width: 64)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Theme.amber.opacity(0.14) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.reveal(finding) }
        .help(model.pretty(finding.path) + "\n" + finding.why)
        .contextMenu {
            Button(marked ? "Unmark" : "Mark for Removal") { model.toggleMark(finding) }
            Button("Look Inside") { model.reveal(finding); model.lookInside() }
            Button("Show in Finder") { model.showInFinder(finding.path) }
        }
    }
}

// MARK: disk

struct DiskSection: View {
    @ObservedObject var model: Model

    var body: some View {
        let space = model.space
        let total = Double(max(space.total, 1))
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Disk")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.size(space.free).split(separator: " ").first.map(String.init) ?? "")
                    .font(.system(size: 30, weight: .light)).monospacedDigit()
                Text((Format.size(space.free).split(separator: " ").last.map(String.init) ?? "") + " free")
                    .foregroundStyle(.secondary)
                if model.marks.total > 0 {
                    Spacer()
                    Text("+\(Format.size(model.marks.total)) marked").font(.caption).foregroundStyle(Theme.amber)
                }
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(model.segments) { s in
                        Rectangle().fill(s.color)
                            .frame(width: max(0, geo.size.width * Double(s.bytes) / total - 1))
                            .help("\(s.label): \(Format.size(s.bytes))")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            HStack {
                Text("\(Format.size(space.total - space.free)) used")
                Spacer()
                Text("\(Format.size(space.total)) total")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if model.reclaimable > 0 {
                Text("\(Format.size(model.reclaimable)) comes back with nothing of yours lost (✓)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
