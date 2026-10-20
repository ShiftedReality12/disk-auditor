import Foundation

/// A large folder that no rule explains, described by what the scan
/// already knows: names, sizes and ages. No file contents, ever.
public struct Suspect: Codable, Sendable {
    public let path: String
    public let bytes: UInt64
    public let files: UInt64
    public let ageDays: Int
    public let isRepo: Bool
    public let children: [Entry]

    public struct Entry: Codable, Sendable {
        public let name: String
        public let bytes: UInt64
        public let ageDays: Int
        public let dir: Bool
    }

    enum CodingKeys: String, CodingKey {
        case path, bytes, files, ageDays = "age_days", isRepo = "is_repo", children
    }
}

/// The model's judgement of one suspect. It is advice: it never marks
/// anything, is never shown as ✓, and its command is displayed, never run.
public struct Advice: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable { case bloat, stale, regenerable, active, userData = "user_data", unsure }
    public enum Action: String, Codable, Sendable { case remove, clean, review, keep }

    public let path: String
    /// What it is, in a few words.
    public let what: String
    /// The app or tool that made it, when known.
    public let owner: String?
    public let verdict: Verdict
    public let action: Action
    /// The owner's own cleanup command, when there is one.
    public let command: String?
    public let why: String
    /// 0…1: how sure the model is of `what`.
    public let confidence: Double

    /// Worth listing: the model thinks it can go or deserves a look.
    public var worthALook: Bool { action == .remove || action == .clean || action == .review }
}

public enum Advisor {
    /// Folders smaller than this are not worth a model's time.
    public static let minBytes: UInt64 = 500 << 20
    public static let defaultModel = "sonnet"

    /// The most specific large folders the findings do not already cover.
    /// A folder is described whole when no single child of it is itself
    /// large and unexplained; a checkout is always described whole.
    public static func suspects(_ scan: ScanResult, findings: [Finding], limit: Int = 30) -> [Suspect] {
        let covered = Set(findings.map(\.path))
        let now = Int64(Date().timeIntervalSince1970)
        // Bytes the findings already explain, per node, in one pass.
        var known: [ObjectIdentifier: UInt64] = [:]
        @discardableResult
        func tally(_ node: Node, _ path: String) -> UInt64 {
            let bytes = covered.contains(path) ? node.bytes
                : node.children.reduce(0) { $0 + tally($1, path + "/" + $1.name) }
            known[ObjectIdentifier(node)] = bytes
            return bytes
        }
        let rootPath = scan.root.name == "/" ? "" : scan.root.name
        for child in scan.root.children { tally(child, rootPath + "/" + child.name) }
        func explained(_ node: Node, _: String) -> UInt64 { known[ObjectIdentifier(node)] ?? 0 }
        func age(_ node: Node) -> Int { Int(max(0, now - node.newest) / 86_400) }
        var out: [Suspect] = []
        func visit(_ node: Node, _ path: String) {
            // A covered folder has nothing unexplained, so it stops below.
            guard node.isDir else { return }
            let unexplained = node.bytes - min(node.bytes, explained(node, path))
            guard unexplained >= minBytes else { return }
            // A checkout, a dated or run folder, or anything five levels down
            // is judged as one unit: the question is whether the whole run
            // or copy can go, not one file inside it.
            let depth = path.dropFirst(rootPath.count).split(separator: "/").count
            let unit = node.isRepo || depth >= 5 || looksLikeARun(node.name)
            let big = unit ? [] : node.children.filter { child in
                let childPath = path + "/" + child.name
                return child.isDir && child.bytes - min(child.bytes, explained(child, childPath)) >= minBytes
            }
            if big.isEmpty {
                out.append(Suspect(
                    path: path, bytes: unexplained, files: node.files, ageDays: age(node), isRepo: node.isRepo,
                    children: node.children.prefix(12).map {
                        .init(name: $0.name, bytes: $0.bytes, ageDays: age($0), dir: $0.isDir)
                    }
                ))
            } else {
                for child in big { visit(child, path + "/" + child.name) }
            }
        }
        for child in scan.root.children { visit(child, rootPath + "/" + child.name) }
        return Array(out.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    /// Names that mark one run, snapshot or copy: a date, a timestamp, a
    /// long hex id, or a "copy"/numbered duplicate.
    static func looksLikeARun(_ name: String) -> Bool {
        name.range(of: #"\d{4}-?\d{2}-?\d{2}|[0-9a-f]{16,}|\bcopy\b| \d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static let system = """
    You audit disk usage on one developer's Mac. You get folders the user's own rules could not explain, \
    with sizes, ages and the names of what is inside. You never see file contents.
    For each folder, say what it is and which app or tool made it (`owner`: an app or tool name, \
    or null when the person made it; never a person's name or email), then judge it honestly:
    - bloat: serves no purpose now (orphaned leftovers, old installers, duplicate copies)
    - stale: was useful, untouched long enough that it likely is not any more
    - regenerable: a cache or build output its owner recreates on its own
    - active: in use by an app or tool; removing it would break or reset something
    - user_data: something the person made or chose to keep
    - unsure: the evidence does not say
    Action: remove (goes to the Trash), clean (use the owner's own command, given in `command`), \
    review (the person must look), keep. Prefer keep or review whenever removal could lose work or \
    break an app. Never invent a command; leave it null unless it is the owner's documented one. \
    Keep `what` under 8 words and `why` under 25 words. Confidence below 0.6 means you are guessing.
    """

    static let schema = """
    {"type":"object","required":["advice"],"properties":{"advice":{"type":"array","items":{"type":"object",\
    "required":["path","what","verdict","action","why","confidence"],"properties":{\
    "path":{"type":"string"},"what":{"type":"string"},"owner":{"type":["string","null"]},\
    "verdict":{"enum":["bloat","stale","regenerable","active","user_data","unsure"]},\
    "action":{"enum":["remove","clean","review","keep"]},"command":{"type":["string","null"]},\
    "why":{"type":"string"},"confidence":{"type":"number","minimum":0,"maximum":1}}}}}}
    """

    public enum Failure: Error, CustomStringConvertible {
        case noClaude, failed(String)
        public var description: String {
            switch self {
            case .noClaude: return "Claude Code was not found (looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin)."
            case .failed(let why): return "The model call failed: \(why)"
            }
        }
    }

    /// Asks Claude Code about the suspects in one call, and answers from
    /// the cache for any it judged recently at about the same size.
    public static func advise(
        _ suspects: [Suspect], home: String, model: String = defaultModel
    ) throws -> [Advice] {
        var cache = Cache.load()
        let fresh = suspects.filter { cache.answer(for: $0) == nil }
        if !fresh.isEmpty {
            let answers = try ask(fresh, home: home, model: model)
            for advice in answers {
                if let s = fresh.first(where: { $0.path == advice.path }) { cache.store(advice, bytes: s.bytes) }
            }
            try? cache.save()
        }
        return suspects.compactMap { cache.answer(for: $0) }
    }

    /// Past answers only, without asking: free, so the app shows them
    /// after every scan.
    public static func cached(_ suspects: [Suspect]) -> [Advice] {
        let cache = Cache.load()
        return suspects.compactMap { cache.answer(for: $0) }
    }

    static func ask(_ suspects: [Suspect], home: String, model: String) throws -> [Advice] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let evidence = String(decoding: try encoder.encode(suspects), as: UTF8.self)
        return try run("Home folder: \(home). Folders:\n\(evidence)\nAnswer for every path, using the path exactly as given.",
                       home: home, model: model)
    }

    /// A close look at one folder the person chose: its file types, largest
    /// and newest files, short redacted excerpts, and what was measured to
    /// rely on it. The answer replaces any earlier, names-only one.
    public static func judge(_ inside: Inside, home: String, model: String = defaultModel) throws -> Advice {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let evidence = String(decoding: try encoder.encode(inside), as: UTF8.self)
        let prompt = """
        Home folder: \(home). One folder, looked at closely. `reliance` lists facts measured on this Mac \
        (open files, launch jobs, config mentions, links, whether the owning app is installed); weigh them \
        above anything you infer. Excerpts are the first bytes of a few files, with secrets removed.
        \(evidence)
        Answer for this one path, using it exactly as given.
        """
        guard let advice = try run(prompt, home: home, model: model).first else { throw Failure.failed("no answer") }
        var cache = Cache.load()
        cache.store(advice, bytes: inside.bytes)
        try? cache.save()
        return advice
    }

    static func run(_ prompt: String, home: String, model: String) throws -> [Advice] {
        guard let claude = claudePath(home: home) else { throw Failure.noClaude }
        // An empty folder to run in, so no project instructions load.
        let quiet = FileManager.default.temporaryDirectory.appendingPathComponent("dsa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: quiet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: quiet) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.currentDirectoryURL = quiet
        // One call that judges only what it is shown: no tools, so it cannot
        // read files or run anything; no settings, hooks, MCP servers or
        // session transcript, which would cost ~60x more and add nothing.
        process.arguments = [
            "-p", "--model", model, "--tools", "", "--setting-sources", "", "--strict-mcp-config",
            "--no-session-persistence", "--system-prompt", system,
            "--output-format", "json", "--json-schema", schema, prompt,
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try parse(data)
    }

    /// Reads Claude Code's `--output-format json` envelope.
    static func parse(_ data: Data) throws -> [Advice] {
        struct Envelope: Decodable {
            let is_error: Bool?
            let result: String?
            let structured_output: Body?
        }
        struct Body: Decodable { let advice: [Advice] }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw Failure.failed(String(decoding: data.prefix(300), as: UTF8.self))
        }
        if envelope.is_error == true { throw Failure.failed(envelope.result ?? "unknown error") }
        guard let body = envelope.structured_output else { throw Failure.failed("no structured answer") }
        return body.advice
    }

    static func claudePath(home: String) -> String? {
        [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Past answers, so a folder is not paid for twice while it stays the same.
    struct Cache: Codable {
        struct Entry: Codable { let advice: Advice; let bytes: UInt64; let when: Date }
        var entries: [String: Entry] = [:]

        static var file: URL { Snapshot.file.deletingLastPathComponent().appendingPathComponent("advice.json") }

        static func load() -> Cache {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? Data(contentsOf: file)).flatMap { try? decoder.decode(Cache.self, from: $0) } ?? Cache()
        }

        func save() throws {
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: Self.file, options: .atomic)
        }

        /// Still good for two weeks, while the folder is within a fifth of
        /// the size it was judged at.
        func answer(for suspect: Suspect) -> Advice? {
            guard let entry = entries[suspect.path], Date().timeIntervalSince(entry.when) < 14 * 86_400 else { return nil }
            let ratio = Double(suspect.bytes) / Double(max(entry.bytes, 1))
            return (0.8...1.25).contains(ratio) ? entry.advice : nil
        }

        mutating func store(_ advice: Advice, bytes: UInt64) {
            entries[advice.path] = Entry(advice: advice, bytes: bytes, when: Date())
        }
    }
}
