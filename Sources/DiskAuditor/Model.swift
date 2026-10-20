import AppKit
import AuditorCore
import Foundation
import SwiftUI

/// Everything the window shows and every action it can take. The views only
/// read this and call its methods.
@MainActor
final class Model: ObservableObject {
    enum Phase: Equatable { case scanning(String), ready, failed(String) }

    @Published private(set) var phase = Phase.scanning("~")
    @Published private(set) var scan: ScanResult?
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var checkingGit = false
    @Published private(set) var space: Space
    /// The folder the treemap shows.
    @Published var current: Node?
    @Published var selected: Node? { didSet { if oldValue !== selected { closeInside() } } }
    /// The pointer's tile lives apart, so moving the mouse redraws only the
    /// outline layer, not the window.
    let hover = Hover()
    /// Only matches, and the folders on the way to them, keep their colour.
    @Published var filter = "" { didSet { if filter != oldValue { refilter() } } }
    /// Nodes that match the filter or hold a match, anywhere in the scan.
    @Published private(set) var onPath: Set<ObjectIdentifier> = []
    @Published private(set) var matchCount = 0
    @Published private(set) var matchBytes: UInt64 = 0
    @Published private(set) var back: [String] = []
    @Published private(set) var forward: [String] = []
    /// Entries read so far in the running scan, and in the last complete one.
    @Published private(set) var progress = 0
    private(set) var expected = UserDefaults.standard.integer(forKey: "lastEntries")
    /// What is inside the selected folder, and the model's close look at it.
    @Published private(set) var inside: Inside?
    @Published private(set) var lookingInside = false
    @Published private(set) var judging = false
    @Published private(set) var judgeError: String?
    @Published var marks = Marks()
    @Published var reviewing = false
    /// Levels of nesting drawn at once.
    @Published var depth = 3
    @Published private(set) var last: Outcome?
    /// The model's judgement of folders no rule explains, by path.
    @Published private(set) var advice: [String: Advice] = [:]
    @Published private(set) var advising = false
    @Published private(set) var adviceError: String?
    @Published private(set) var suspects: [Suspect] = []
    /// Rule findings, before any advice is merged in.
    private var ruleFindings: [Finding] = []

    let home: String
    private(set) var rootPath: String
    private var byPath: [String: Finding] = [:]

    /// The result of the last removal, kept so it can be undone.
    struct Outcome {
        let message: String
        let detail: String
        /// Original path → where it landed in the Trash.
        let trashed: [(String, String)]
    }

    /// Whether macOS lets this app read everything. Without it, scanning the
    /// home folder makes macOS ask about Desktop, Documents, Downloads and
    /// other apps' data one prompt at a time.
    @Published private(set) var fullAccess: Bool
    @Published var accessCardDismissed: Bool
    /// Access granted while running applies only after a relaunch.
    let launchedWithAccess: Bool

    init(root: String?) {
        home = Guard.real(FileManager.default.homeDirectoryForCurrentUser.path)
        rootPath = root.map(Scanner.normalize) ?? home
        space = Space.of(home)
        let access = Self.hasFullDiskAccess()
        fullAccess = access
        launchedWithAccess = access
        accessCardDismissed = UserDefaults.standard.bool(forKey: "scanWithoutFullAccess")
        if fullAccess || accessCardDismissed || root != nil { rescan() } else { phase = .ready }
    }

    var showAccessCard: Bool { !fullAccess && !accessCardDismissed && scan == nil }
    var needsRelaunch: Bool { fullAccess && !launchedWithAccess }

    /// The whole disk, measured: what the findings are, by kind; the rest
    /// of the scan; what lies outside it (macOS, apps, other users,
    /// unreadable folders); and free space.
    struct Segment: Identifiable {
        var id: String { label }
        let label: String
        let bytes: UInt64
        let color: Color
    }

    var segments: [Segment] {
        let used = space.total > space.free ? space.total - space.free : 0
        guard let scan else {
            return [Segment(label: "Used", bytes: used, color: Color(white: 0.4)), Segment(label: "Free", bytes: space.free, color: Theme.free)]
        }
        let totals = Classify.totals(scan.root)
        var out = Category.allCases.compactMap { c in
            totals[c].flatMap { $0 > 0 ? Segment(label: c.label, bytes: $0, color: c.accent) : nil }
        }
        .sorted { $0.bytes > $1.bytes }
        let outside = used > scan.root.bytes ? used - scan.root.bytes : 0
        out.append(Segment(label: "Outside \(pretty(scan.root.path)): macOS, apps", bytes: outside, color: Color(white: 0.28)))
        out.append(Segment(label: "Free", bytes: space.free, color: Theme.free))
        return out
    }

    /// What the rules say comes back with nothing of yours lost.
    var reclaimable: UInt64 { findings.filter(\.safe).reduce(0) { $0 + $1.bytes } }

    /// The TCC database is readable only with Full Disk Access, and reading
    /// it without never prompts: it simply fails.
    nonisolated static func hasFullDiskAccess() -> Bool {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let fd = Darwin.open(db, O_RDONLY)
        if fd >= 0 { Darwin.close(fd); return true }
        return false
    }

    /// Access is granted in System Settings and takes effect on relaunch.
    func recheckAccess() { fullAccess = Self.hasFullDiskAccess() }

    func scanWithoutFullAccess() {
        UserDefaults.standard.set(true, forKey: "scanWithoutFullAccess")
        accessCardDismissed = true
        rescan()
    }

    func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    var scanning: Bool { if case .scanning = phase { return true } else { return false } }

    func pretty(_ path: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: scanning

    func scan(_ path: String) {
        rootPath = path
        rescan()
    }

    func rescan() {
        phase = .scanning(pretty(rootPath))
        progress = 0
        let path = rootPath
        let home = home
        let counter = Locked(0)
        // The count is read a few times a second, not pushed per directory.
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.progress = counter.value }
        }
        Task.detached(priority: .userInitiated) {
            let result = Scanner.scan(path, progress: counter)
            let found = Findings.worthALook(result, home: home)
            await MainActor.run {
                ticker.invalidate()
                self.expected = counter.value
                UserDefaults.standard.set(counter.value, forKey: "lastEntries")
                self.show(result, found)
            }
        }
    }

    private func show(_ result: ScanResult, _ found: [Finding]) {
        let keep = current.map(\.path)
        let keepSelected = selected.map(\.path)
        scan = result
        ruleFindings = found
        suspects = Advisor.suspects(result, findings: found)
        advice = Dictionary(Advisor.cached(suspects).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        merge()
        current = keep.flatMap(node(at:)) ?? result.root
        selected = keepSelected.flatMap(node(at:))
        space = Space.of(home)
        // Marks survive a rescan with fresh sizes; what is gone is dropped.
        for path in marks.paths {
            marks.remove(path)
            if let node = node(at: path) { marks.toggle(path, bytes: node.bytes) }
        }
        refilter()
        back = back.filter { node(at: $0) != nil }
        forward = forward.filter { node(at: $0) != nil }
        phase = result.root.unreadable && result.root.children.isEmpty
            ? .failed("Could not read \(pretty(result.root.path)).") : .ready
        attachGit()
    }

    /// The list: rule findings, then the model's suggestions for what the
    /// rules do not cover, largest first.
    private func merge() {
        var all = ruleFindings
        for s in suspects {
            if let a = advice[s.path], a.worthALook { all.append(Finding(advice: a, suspect: s)) }
        }
        let gitByPath = Dictionary(findings.compactMap { f in f.git.map { (f.path, $0) } }, uniquingKeysWith: { a, _ in a })
        findings = all.sorted { $0.bytes > $1.bytes }.enumerated().map { i, f in
            var f = f
            f.id = i + 1
            if f.git == nil { f.git = gitByPath[f.path] }
            return f
        }
        byPath = Dictionary(findings.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var unexplainedBytes: UInt64 {
        suspects.filter { advice[$0.path] == nil }.reduce(0) { $0 + $1.bytes }
    }

    /// Asks the model about the large folders the rules leave unexplained.
    /// It sees names, sizes and ages only, and its answers are advice.
    func explain() {
        let pending = suspects
        guard !pending.isEmpty, !advising else { return }
        advising = true
        adviceError = nil
        let home = home
        Task.detached(priority: .userInitiated) {
            let result = Result { try Advisor.advise(pending, home: home) }
            await MainActor.run {
                self.advising = false
                switch result {
                case .success(let answers):
                    for a in answers { self.advice[a.path] = a }
                    self.merge()
                case .failure(let error):
                    self.adviceError = "\(error)"
                }
            }
        }
    }

    /// Git is asked after the list is on screen: it can take a few seconds.
    private func attachGit() {
        guard let scan else { return }
        checkingGit = true
        let snapshot = findings
        Task.detached(priority: .utility) {
            var local = Array(snapshot.prefix(60))
            Findings.attachGit(&local, scan: scan)
            let checked = local
            await MainActor.run {
                for f in checked { if let i = self.findings.firstIndex(where: { $0.path == f.path }) { self.findings[i].git = f.git } }
                self.byPath = Dictionary(self.findings.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                self.checkingGit = false
            }
        }
    }

    // MARK: navigation

    func node(at path: String) -> Node? {
        guard let scan else { return nil }
        return Findings.locate([path], in: scan.root).first ?? nil
    }

    func finding(for node: Node) -> Finding? { byPath[node.path] }

    /// One pass over the whole tree, off the main thread and after typing
    /// pauses: a match deep inside still lights the path down to it.
    private var filtering: Task<Void, Never>?

    private func refilter() {
        filtering?.cancel()
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard let root = scan?.root, !query.isEmpty else {
            onPath = []; matchCount = 0; matchBytes = 0
            return
        }
        filtering = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { Self.search(root, query) }.value
            guard !Task.isCancelled, let self, self.filter.trimmingCharacters(in: .whitespaces) == query else { return }
            self.onPath = found.0
            self.matchCount = found.1
            self.matchBytes = found.2
        }
    }

    nonisolated static func search(_ root: Node, _ query: String) -> (Set<ObjectIdentifier>, Int, UInt64) {
        var path = Set<ObjectIdentifier>()
        var count = 0
        var bytes: UInt64 = 0
        func walk(_ node: Node, inside: Bool) -> Bool {
            let hit = node.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            if hit { count += 1; if !inside { bytes += node.bytes } }
            var holds = hit
            for child in node.children where walk(child, inside: inside || hit) { holds = true }
            if holds { path.insert(ObjectIdentifier(node)) }
            return holds
        }
        _ = walk(root, inside: false)
        return (path, count, bytes)
    }

    func matches(_ node: Node) -> Bool { node.name.localizedCaseInsensitiveContains(filter.trimmingCharacters(in: .whitespaces)) }

    /// A finding's name, with its parent when another has the same name
    /// (`.codex/sessions` and `.grok/sessions`).
    func label(for finding: Finding) -> String {
        let name = (finding.path as NSString).lastPathComponent
        let twins = findings.filter { ($0.path as NSString).lastPathComponent == name }.count
        guard twins > 1 else { return name }
        let parent = ((finding.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent + "/" + name
    }

    /// The finding that covers a node: its own, or its nearest ancestor's.
    func covering(_ node: Node) -> Finding? {
        var n: Node? = node
        while let x = n { if let f = byPath[x.path] { return f }; n = x.parent }
        return nil
    }

    /// Every change of folder goes through here, so back and forward work.
    private func go(to node: Node, select: Node?, remember: Bool = true) {
        guard node !== current else { selected = select; return }
        if remember, let here = current?.path { back.append(here); forward = [] }
        withAnimation(.easeOut(duration: 0.18)) {
            current = node
            selected = select
        }
    }

    func open(_ node: Node) {
        guard node.isDir else { return }
        go(to: node, select: nil)
    }

    func up() {
        guard let parent = current?.parent else { return }
        go(to: parent, select: current)
    }

    func goBack() {
        guard let path = back.popLast(), let node = node(at: path) else { return }
        if let here = current?.path { forward.append(here) }
        go(to: node, select: nil, remember: false)
    }

    func goForward() {
        guard let path = forward.popLast(), let node = node(at: path) else { return }
        if let here = current?.path { back.append(here) }
        go(to: node, select: nil, remember: false)
    }

    func reveal(_ finding: Finding) {
        guard let node = node(at: finding.path) else { return }
        go(to: node.parent ?? node, select: node)
    }

    // MARK: look inside

    /// Reads the selected folder locally: types, largest and newest files,
    /// excerpts, and what relies on it. Free, and nothing leaves the Mac.
    func lookInside() {
        guard let node = selected ?? current, node.isDir, !lookingInside else { return }
        lookingInside = true
        judgeError = nil
        let path = node.path
        let home = home
        Task.detached(priority: .userInitiated) {
            let found = Inspector.look(path, home: home)
            await MainActor.run {
                guard (self.selected ?? self.current)?.path == path else { self.lookingInside = false; return }
                self.inside = found
                self.lookingInside = false
            }
        }
    }

    /// Sends what Look Inside found, secrets removed, to the model.
    func askAI() {
        guard let inside, !judging else { return }
        judging = true
        judgeError = nil
        let home = home
        Task.detached(priority: .userInitiated) {
            let result = Result { try Advisor.judge(inside, home: home) }
            await MainActor.run {
                self.judging = false
                switch result {
                case .success(let advice):
                    self.advice[advice.path] = advice
                    self.merge()
                case .failure(let error): self.judgeError = "\(error)"
                }
            }
        }
    }

    private func closeInside() {
        inside = nil
        judgeError = nil
    }

    var trail: [Node] {
        var out: [Node] = []
        var n = current
        while let x = n { out.insert(x, at: 0); n = x.parent }
        return out
    }

    // MARK: marking

    func toggleMark(_ node: Node) {
        marks.toggle(node.path, bytes: node.bytes)
    }

    func toggleMark(_ finding: Finding) {
        marks.toggle(finding.path, bytes: finding.bytes)
    }

    func isMarked(_ node: Node) -> Bool {
        marks.contains(node.path) || marks.covering(node.path) != nil
    }

    // MARK: removal

    struct Item: Identifiable {
        var id: String { path }
        let path: String
        let bytes: UInt64
        let finding: Finding?
        /// The owning tool's cleaner, when there is one: then it is the action.
        let clean: [String]?
        /// `nil` while the guards are still checking.
        var verdict: Verdict?
        var include = true

        enum Verdict { case ok, refused(String) }
        var ok: Bool { if case .ok = verdict { return true } else { return false } }
    }

    func reviewItems() -> [Item] {
        marks.paths.map { path in
            let f = byPath[path]
            return Item(
                path: path, bytes: marks.bytes[path] ?? 0, finding: f,
                clean: f?.clean ?? Rules.rule(for: path, home: home)?.clean
            )
        }
    }

    /// The guards run off the main thread: the git check walks the folder.
    nonisolated static func verdict(for item: Item, home: String) -> Item.Verdict {
        if item.clean != nil { return .ok }
        if let refusal = Guard.refusal(for: item.path, home: home) { return .refused(refusal.description) }
        return .ok
    }

    func trash(_ items: [Item]) {
        let before = Space.of(home)
        var trashed: [(String, String)] = []
        var failed: [String] = []
        for item in items {
            do {
                trashed.append((item.path, try Trash.move(item.path)))
                marks.remove(item.path)
            } catch {
                failed.append("\(pretty(item.path)): \(error.localizedDescription)")
            }
        }
        let moved = items.filter { i in trashed.contains { $0.0 == i.path } }.reduce(0) { $0 + $1.bytes }
        let after = Space.of(home)
        last = Outcome(
            message: "Moved \(Format.size(moved)) to the Trash",
            detail: (failed.isEmpty ? "" : "Failed: " + failed.joined(separator: "; ") + ". ")
                + "Free space \(Format.size(before.free)) → \(Format.size(after.free)). "
                + "The Trash keeps it until you empty it in Finder.",
            trashed: trashed
        )
        rescan()
    }

    func clean(_ items: [Item]) async {
        let before = Space.of(home)
        var commands: [[String]] = []
        for item in items { if let c = item.clean, !commands.contains(c) { commands.append(c) } }
        var problems: [String] = []
        for command in commands {
            let status = await Task.detached { Cleaner.run(command) }.value
            if status == nil { problems.append("could not start \(command[0])") }
            else if status != 0 { problems.append("\(command[0]) exited \(status!)") }
        }
        for item in items { marks.remove(item.path) }
        let after = Space.of(home)
        let delta = Int64(after.free) - Int64(before.free)
        last = Outcome(
            message: "Cleaners freed \(Format.size(UInt64(max(0, delta)))) (measured)",
            detail: (problems.isEmpty ? "" : problems.joined(separator: "; ") + ". ")
                + "Free space \(Format.size(before.free)) → \(Format.size(after.free)).",
            trashed: []
        )
        rescan()
    }

    func undo() {
        guard let last, !last.trashed.isEmpty else { return }
        var failed: [String] = []
        for (original, landed) in last.trashed {
            do { try Trash.putBack(from: landed, to: original) } catch { failed.append(pretty(original)) }
        }
        self.last = Outcome(
            message: failed.isEmpty ? "Put \(last.trashed.count) item\(last.trashed.count == 1 ? "" : "s") back" : "Some items could not be put back",
            detail: failed.isEmpty ? "Everything is where it was." : "Still in the Trash: " + failed.joined(separator: ", "),
            trashed: []
        )
        rescan()
    }

    func dismissOutcome() { last = nil }

    func agentPrompt(_ items: [Item]) -> String {
        AgentPrompt.text(items.map { ($0.path, $0.finding) })
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: rootPath)
        if panel.runModal() == .OK, let url = panel.url { scan(Scanner.normalize(url.path)) }
    }

    func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

@MainActor
final class Hover: ObservableObject {
    @Published var node: Node?
}
