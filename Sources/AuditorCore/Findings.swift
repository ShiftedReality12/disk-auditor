import Foundation

/// One line of "worth a look": a directory or file a person can judge in a
/// second, with the reason it is listed and the way to reclaim it.
public struct Finding: Codable, Sendable {
    public var id = 0
    public let path: String
    public let bytes: UInt64
    public let files: UInt64
    public let ageDays: Int
    public let kind: Kind
    public let why: String
    /// The owning tool's command, run instead of trashing.
    public let clean: [String]?
    public let trashable: Bool
    /// What git says about the checkouts inside, when there are any.
    public var git: GitState?
    /// Growth since the previous scan of the same root, when there was one.
    public var grown: Int64?
    let ruleSafe: Bool
    /// Set when the finding is the model's suggestion, not a rule's.
    public var advice: Advice?

    /// Reclaiming it loses nothing you made: regenerable, and no git work
    /// that exists only here. Never true for a model's suggestion.
    public var safe: Bool { advice == nil && ruleSafe && (git?.isClean ?? true) }

    /// A model's suggestion as a line of the list. Its command is shown,
    /// never run: only the rules table's cleaners are executed.
    public init(advice: Advice, suspect: Suspect) {
        path = advice.path
        bytes = suspect.bytes
        files = suspect.files
        ageDays = suspect.ageDays
        kind = advice.verdict == .regenerable ? .cache : advice.verdict == .stale ? .archive : .file
        why = advice.what + " — " + advice.why
        clean = nil
        trashable = true
        ruleSafe = false
        self.advice = advice
    }

    init(
        path: String, bytes: UInt64, files: UInt64, ageDays: Int, kind: Kind, why: String,
        clean: [String]?, trashable: Bool, ruleSafe: Bool
    ) {
        self.path = path
        self.bytes = bytes
        self.files = files
        self.ageDays = ageDays
        self.kind = kind
        self.why = why
        self.clean = clean
        self.trashable = trashable
        self.ruleSafe = ruleSafe
    }

    enum CodingKeys: String, CodingKey {
        case id, path, bytes, files, ageDays = "age_days", kind, why, clean
        case trashable, git, grown, ruleSafe = "rule_safe", advice
    }

    /// Every key is always present, `null` when empty, so a consuming agent
    /// never has to guess whether a missing key means "no" or "unknown".
    /// `safe` is the git-aware verdict, not the rule's alone.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(bytes, forKey: .bytes)
        try c.encode(files, forKey: .files)
        try c.encode(ageDays, forKey: .ageDays)
        try c.encode(kind, forKey: .kind)
        try c.encode(why, forKey: .why)
        try c.encode(clean, forKey: .clean)
        try c.encode(trashable, forKey: .trashable)
        try c.encode(git, forKey: .git)
        try c.encode(grown, forKey: .grown)
        try c.encode(ruleSafe, forKey: .ruleSafe)
        try c.encode(advice, forKey: .advice)
        var extra = encoder.container(keyedBy: Verdict.self)
        try extra.encode(safe, forKey: .safe)
    }

    private enum Verdict: String, CodingKey { case safe }
}

public enum Findings {
    /// The largest findings beneath the scanned root, largest first. They
    /// never nest, so their sizes add up to space that really exists once.
    public static func worthALook(
        _ scan: ScanResult, home: String, now: Date = Date()
    ) -> [Finding] {
        let index = Rules.Index(home: home)
        let now = Int64(now.timeIntervalSince1970)
        var found: [Finding] = []
        visit(scan.root, scan.root.name, index, now, &found)
        found = found.filter { $0.bytes >= Rules.minBytes }
        found.sort { $0.bytes > $1.bytes }
        return found
    }

    private static func visit(
        _ node: Node, _ path: String, _ index: Rules.Index, _ now: Int64,
        _ found: inout [Finding]
    ) {
        let age = Int(max(0, now - node.newest) / 86_400)
        if !node.isDir {
            if node.bytes >= Rules.bigFileBytes && age >= Rules.staleDays {
                let synced = Guard.synced.contains { path.hasPrefix(index.home + "/" + $0 + "/") }
                found.append(finding(
                    node, path, age, .file,
                    "large file, untouched \(age) days" + (synced ? " (cloud-synced: remove it in its app)" : ""),
                    safe: false, trashable: !synced
                ))
            }
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        // Manifests are small files, which the scan only counts, so the
        // disk is asked; it happens only for a name a rule already matched.
        let sibling = { FileManager.default.fileExists(atPath: parent + "/" + $0) }
        if let rule = index.rule(path: path, name: node.name, parent: parent, hasSibling: sibling) {
            found.append(finding(
                node, path, age, rule.kind, rule.why, safe: rule.safe,
                clean: rule.clean, trashable: rule.trashable
            ))
            return
        }
        if !index.above.contains(path) && node.parent != nil {
            if node.isWorktree {
                found.append(finding(node, path, age, .worktree, "git worktree, last written \(age) days ago", safe: true))
                return
            }
            let lower = node.name.lowercased()
            if lower.contains("stale") || lower.contains("archive") {
                found.append(finding(node, path, age, .archive, "you named it stale/archived", safe: false))
                return
            }
            if node.isRepo && age >= Rules.staleDays && node.bytes >= Rules.bigCheckoutBytes {
                found.append(finding(node, path, age, .checkout, "checkout untouched \(age) days", safe: true))
                return
            }
        }
        for child in node.children {
            let childPath = path == "/" ? "/" + child.name : path + "/" + child.name
            visit(child, childPath, index, now, &found)
        }
    }

    private static func finding(
        _ node: Node, _ path: String, _ age: Int, _ kind: Kind, _ why: String,
        safe: Bool, clean: [String]? = nil, trashable: Bool = true
    ) -> Finding {
        Finding(
            path: path, bytes: node.bytes, files: node.files, ageDays: age,
            kind: kind, why: why, clean: clean, trashable: trashable, ruleSafe: safe
        )
    }

    /// Checkouts inside a node, found in the scan, so git is asked only
    /// about repositories that exist.
    public static func repos(in node: Node, limit: Int = 64) -> [String] {
        var out: [String] = []
        var stack = [node]
        while let next = stack.popLast(), out.count < limit {
            if next.isRepo { out.append(next.path) }
            stack.append(contentsOf: next.children.filter(\.isDir))
        }
        return out
    }

    /// Fills in git state for the findings that hold checkouts. Caches and
    /// other regenerable kinds are not asked: nothing there is authored.
    public static func attachGit(_ findings: inout [Finding], scan: ScanResult) {
        let asked: Set<Kind> = [.worktree, .checkout, .archive, .file, .agent]
        let nodes = locate(findings.map(\.path), in: scan.root)
        let kinds = findings.map(\.kind)
        let states = Locked([Int: GitState]())
        DispatchQueue.concurrentPerform(iterations: findings.count) { i in
            guard asked.contains(kinds[i]), let node = nodes[i] else { return }
            let repos = repos(in: node)
            guard !repos.isEmpty else { return }
            let state = Git.state(of: repos)
            states.with { $0[i] = state }
        }
        for (i, state) in states.value { findings[i].git = state }
    }

    public static func locate(_ paths: [String], in root: Node) -> [Node?] {
        paths.map { path in
            guard path.hasPrefix(root.name) else { return nil }
            let rest = path.dropFirst(root.name.count).split(separator: "/")
            var node: Node? = root
            for part in rest { node = node?.child(named: String(part)) }
            return node
        }
    }
}

/// A value shared between threads, behind a lock.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    public init(_ value: Value) { stored = value }
    public var value: Value { lock.withLock { stored } }
    public func with(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
