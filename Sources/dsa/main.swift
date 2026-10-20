import AuditorCore
import Darwin
import Foundation

let usage = """
dsa — what fills this disk, why it can go, and how to get it back

  dsa [worth] [PATH]     the largest things that could go (default: ~)
  dsa top [PATH]         the biggest folders, -d DEPTH levels (default 2)
  dsa trash ITEM...      move to the Trash (ITEM = # from the last listing, or a path)
  dsa clean ITEM...      run the owning tool's own cleaner (docker, brew, uv, npm, …)
  dsa prompt ITEM...     a checked hand-off prompt for a coding agent
  dsa inspect PATH       what is inside a folder and whether anything relies on it
                         (--ai: also ask Claude, sending excerpts with secrets removed)
  dsa explain [PATH]     ask Claude what the large folders no rule explains are,
                         and whether they are bloat (sends names, sizes, ages only)

  --disk        the whole Data volume instead of ~
  --json        machine-readable output (worth, top)
  -n N          how many findings to list (default 25)
  -y, --yes     do not ask (required when not at a terminal)
  --allow-git   trash checkouts even with uncommitted or unpushed work
  --model M     the model for explain (default sonnet; haiku is cheaper, weaker)

Nothing is ever deleted outright: removal is the Trash, or the tool's own
clean command. The Trash frees nothing until it is emptied.
"""

// MARK: arguments

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ names: String...) -> Bool {
    let hit = args.contains { names.contains($0) }
    args.removeAll { names.contains($0) }
    return hit
}
func option(_ name: String) -> Int? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let value = Int(args[i + 1]) else { return nil }
    args.removeSubrange(i...(i + 1))
    return value
}
let json = flag("--json")
let yes = flag("-y", "--yes")
let allowGit = flag("--allow-git")
let disk = flag("--disk")
let wantHelp = flag("-h", "--help", "help")
let limit = option("-n") ?? 25
func textOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
let model = textOption("--model") ?? Advisor.defaultModel
let depth = option("-d") ?? 2
let wantAI = flag("--ai")
let commands = ["worth", "top", "trash", "clean", "prompt", "explain", "inspect"]
let command = args.first.flatMap { commands.contains($0) ? $0 : nil } ?? "worth"
if args.first == command { args.removeFirst() }
if wantHelp { print(usage); exit(0) }

let home = Guard.resolved(FileManager.default.homeDirectoryForCurrentUser.path)

// MARK: output

let tty = isatty(1) == 1
func style(_ code: String, _ text: String) -> String { tty ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
func dim(_ t: String) -> String { style("2", t) }
func bold(_ t: String) -> String { style("1", t) }
func amber(_ t: String) -> String { style("33", t) }
func green(_ t: String) -> String { style("32", t) }
func red(_ t: String) -> String { style("31", t) }

func size(_ bytes: UInt64) -> String {
    let gib = Double(bytes) / 1_073_741_824
    if gib >= 100 { return String(format: "%.0fG", gib) }
    if gib >= 1 { return String(format: "%.1fG", gib) }
    return String(format: "%.0fM", Double(bytes) / 1_048_576)
}
func signed(_ delta: Int64) -> String {
    (delta < 0 ? "−" : "+") + size(UInt64(abs(delta)))
}
func pad(_ s: String, _ n: Int, left: Bool = true) -> String {
    s.count >= n ? s : (left ? String(repeating: " ", count: n - s.count) + s : s + String(repeating: " ", count: n - s.count))
}
func pretty(_ path: String) -> String {
    path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dsa: \(message)\n".utf8))
    exit(1)
}
func emit<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try! encoder.encode(value), as: UTF8.self))
}
func spaceLine(_ space: Space) -> String {
    "\(bold(size(space.free))) free of \(size(space.total))" +
        (space.withPurgeable > space.free + (1 << 30) ? dim(" (\(size(space.withPurgeable)) counting what macOS can purge)") : "")
}

func scanRoot() -> String {
    disk ? "/" : Scanner.normalize(args.first ?? home)
}
func scanning(_ root: String) -> ScanResult {
    if !json { FileHandle.standardError.write(Data(dim("scanning \(pretty(root)) …\n").utf8)) }
    return Scanner.scan(root)
}

// MARK: items

struct Item {
    let path: String
    let finding: Finding?
}
func items() -> [Item] {
    if args.isEmpty { fail("name what to act on: numbers from `dsa worth`, or paths") }
    let last = Snapshot.load()
    return args.map { arg in
        if let n = Int(arg) {
            guard let last else { fail("no listing yet; run `dsa worth` first") }
            guard let found = last.findings.first(where: { $0.id == n }) else { fail("no #\(n) in the last listing") }
            return Item(path: found.path, finding: found)
        }
        let path = Guard.resolved(arg)
        return Item(path: path, finding: last?.findings.first { $0.path == path })
    }
}
func confirm(_ question: String) -> Bool {
    if yes { return true }
    guard isatty(0) == 1 else { fail("not at a terminal: pass --yes to go ahead") }
    print(question + " [y/N] ", terminator: "")
    return readLine()?.lowercased().hasPrefix("y") == true
}

// MARK: commands

struct Report: Encodable {
    let root: String
    let scanned: UInt64
    let files: UInt64
    let seconds: Double
    let unreadable: Int
    let space: Space
    let findings: [Finding]
    let grew: [Grew]
    struct Grew: Encodable { let path: String; let bytes: Int64 }
}

func worth() {
    let root = scanRoot()
    let scan = scanning(root)
    var findings = Findings.worthALook(scan, home: home)
    let shown = min(limit, findings.count)
    var top = Array(findings.prefix(shown))
    Findings.attachGit(&top, scan: scan)
    findings.replaceSubrange(0..<shown, with: top)
    for i in findings.indices { findings[i].id = i + 1 }

    let previous = Snapshot.load().flatMap { $0.root == root ? $0 : nil }
    let sizes = Snapshot.sizes(of: scan.root, findings: findings)
    if let previous {
        for i in findings.indices {
            if let before = previous.sizes[findings[i].path] {
                findings[i].grown = Int64(findings[i].bytes) - Int64(before)
            }
        }
    }
    let grew = previous?.growth(to: sizes) ?? []
    try? Snapshot(when: Date(), root: root, findings: findings, sizes: sizes).save()
    let space = Space.of(disk ? Scanner.dataVolume : root)

    if json {
        emit(Report(
            root: root, scanned: scan.root.bytes, files: scan.root.files,
            seconds: scan.seconds, unreadable: scan.unreadable, space: space,
            findings: Array(findings.prefix(limit)),
            grew: grew.map { Report.Grew(path: $0.0, bytes: $0.1) }
        ))
        return
    }
    print("\(spaceLine(space))  ·  \(pretty(root)) holds \(size(scan.root.bytes)) in \(scan.root.files) files, read in \(String(format: "%.1f", scan.seconds))s")
    if scan.unreadable > 0 {
        print(dim("\(scan.unreadable) folders unreadable — give your terminal Full Disk Access (System Settings › Privacy & Security) to see them"))
    }
    if let previous, !grew.isEmpty {
        let days = Int(Date().timeIntervalSince(previous.when) / 86_400)
        print("\nGrew since the last scan (\(days == 0 ? "today" : "\(days)d ago")):")
        for (path, delta) in grew { print("  \(amber(pad(signed(delta), 7)))  \(pretty(path))") }
    }
    print("")
    for f in findings.prefix(limit) {
        let mark = f.safe ? green("✓") : " "
        let growth = f.grown.flatMap { abs($0) >= 64 << 20 ? "  " + amber(signed($0)) : nil } ?? ""
        print("\(pad(String(f.id), 3)) \(mark) \(amber(pad(size(f.bytes), 6)))  \(pad("\(f.ageDays)d", 5))  \(bold(pretty(f.path)))\(growth)")
        var detail = [f.kind.rawValue + ": " + f.why]
        if let git = f.git { detail.append(git.isClean ? git.summary : red(git.summary)) }
        detail.append(f.clean.map { "dsa clean → " + $0.joined(separator: " ") } ?? (f.trashable ? "dsa trash" : "—"))
        print(String(repeating: " ", count: 20) + dim(detail.joined(separator: " · ")))
    }
    let listed = findings.prefix(limit)
    let safe = listed.filter(\.safe).reduce(0) { $0 + $1.bytes }
    let all = listed.reduce(0) { $0 + $1.bytes }
    print("\n\(green("✓")) \(bold(size(safe))) regenerable with nothing of yours lost · \(size(all)) listed in all · the rest is your call")
    if findings.count > limit { print(dim("\(findings.count - limit) smaller findings not shown (-n \(findings.count))")) }
}

struct Tree: Encodable {
    let path: String
    let bytes: UInt64
    let files: UInt64
    let ageDays: Int
    let children: [Tree]?
    enum CodingKeys: String, CodingKey { case path, bytes, files, ageDays = "age_days", children }
}

func top() {
    let scan = scanning(scanRoot())
    let now = Int64(Date().timeIntervalSince1970)
    let total = max(scan.root.bytes, 1)
    func tree(_ node: Node, _ level: Int) -> Tree {
        let kids = level < depth
            ? node.children.filter { $0.bytes * 200 >= total }.prefix(12).map { tree($0, level + 1) }
            : nil
        return Tree(path: node.path, bytes: node.bytes, files: node.files,
                    ageDays: Int(max(0, now - node.newest) / 86_400), children: kids)
    }
    let root = tree(scan.root, 0)
    if json { emit(root); return }
    func show(_ t: Tree, _ level: Int) {
        let share = Double(t.bytes) / Double(total) * 100
        let name = level == 0 ? pretty(t.path) : (t.path as NSString).lastPathComponent
        print("\(amber(pad(size(t.bytes), 6)))  \(dim(pad(String(format: "%.0f%%", share), 4)))  \(String(repeating: "  ", count: level))\(level < 2 ? bold(name) : name)")
        for child in t.children ?? [] { show(child, level + 1) }
    }
    show(root, 0)
}

func trash() {
    var ok: [(Item, UInt64)] = []
    for item in items() {
        if let refusal = Guard.refusal(for: item.path, home: home, allowGit: allowGit) {
            let hint = if case .gitWork = refusal { " (--allow-git to override)" } else { "" }
            print("\(red("✗")) \(pretty(item.path)) — \(refusal)\(hint)")
            continue
        }
        let bytes = item.finding?.bytes ?? Scanner.scan(item.path).root.bytes
        ok.append((item, bytes))
        print("\(green("✓")) \(amber(pad(size(bytes), 6)))  \(pretty(item.path))")
    }
    guard !ok.isEmpty else { exit(1) }
    let total = ok.reduce(0) { $0 + $1.1 }
    guard confirm("Move \(ok.count) item\(ok.count == 1 ? "" : "s") (\(size(total))) to the Trash?") else { exit(1) }
    let before = Space.of(home)
    var moved: UInt64 = 0
    for (item, bytes) in ok {
        do {
            _ = try Trash.move(item.path)
            moved += bytes
        } catch {
            print("\(red("✗")) \(pretty(item.path)) — \(error.localizedDescription)")
        }
    }
    let after = Space.of(home)
    print("Moved \(bold(size(moved))) to the Trash. Free space: \(size(before.free)) → \(size(after.free)).")
    print(dim("The Trash keeps it until you empty it (Finder › Empty Trash); nothing is freed before then."))
}

func clean() {
    var commands: [[String]] = []
    for item in items() {
        guard let command = item.finding?.clean ?? Rules.rule(for: item.path, home: home)?.clean else {
            print("\(red("✗")) \(pretty(item.path)) — no cleaner is known for it; use dsa trash")
            continue
        }
        if !commands.contains(command) { commands.append(command) }
    }
    guard !commands.isEmpty else { exit(1) }
    for command in commands { print("  \(bold(command.joined(separator: " ")))") }
    guard confirm("Run \(commands.count == 1 ? "this" : "these")?") else { exit(1) }
    let before = Space.of(home)
    for command in commands {
        switch Cleaner.run(command) {
        case nil: print(red("could not run \(command[0])"))
        case let status? where status != 0: print(red("\(command[0]) exited \(status)"))
        default: break
        }
    }
    let after = Space.of(home)
    let delta = Int64(after.free) - Int64(before.free)
    print("Free space: \(size(before.free)) → \(bold(size(after.free))) (\(signed(delta)), measured).")
}

func prompt() {
    print(AgentPrompt.text(items().map { ($0.path, $0.finding) }))
}

struct Explained: Encodable {
    let bytes: UInt64
    let advice: Advice
}

func explain() {
    let scan = scanning(scanRoot())
    let suspects = Advisor.suspects(scan, findings: Findings.worthALook(scan, home: home))
    if suspects.isEmpty {
        if json { emit([Explained]()) } else { print("Nothing large is left unexplained.") }
        return
    }
    let total = suspects.reduce(0) { $0 + $1.bytes }
    if !json {
        FileHandle.standardError.write(Data(dim("asking \(model) about \(suspects.count) folders (\(size(total))) …\n").utf8))
    }
    let advice: [Advice]
    do { advice = try Advisor.advise(suspects, home: home, model: model) } catch { fail("\(error)") }
    let rows = suspects.compactMap { s in advice.first { $0.path == s.path }.map { Explained(bytes: s.bytes, advice: $0) } }
    if json { emit(rows); return }
    for row in rows {
        let a = row.advice
        let tone = a.action == .keep ? dim : (a.action == .review ? amber : green)
        print("\(amber(pad(size(row.bytes), 6)))  \(bold(pretty(a.path)))")
        var line = "\(a.verdict.rawValue), \(tone(a.action.rawValue)): \(a.what)"
        if let owner = a.owner { line += " (\(owner))" }
        line += String(format: " · %.0f%% sure", a.confidence * 100)
        print("        " + line)
        print("        " + dim(a.why))
        if let command = a.command { print("        " + dim("its own cleanup: \(command)")) }
    }
    print(dim("\nAdvice only: nothing is marked or run. Trash what you agree with: dsa trash PATH"))
}

func inspect() {
    guard let arg = args.first else { fail("name a folder: dsa inspect PATH") }
    let path = Guard.resolved(arg)
    let inside = Inspector.look(path, home: home)
    var advice: Advice?
    if wantAI {
        if !json { FileHandle.standardError.write(Data(dim("asking \(model) …\n").utf8)) }
        do { advice = try Advisor.judge(inside, home: home, model: model) } catch { fail("\(error)") }
    }
    if json {
        struct Report: Encodable { let inside: Inside; let advice: Advice? }
        emit(Report(inside: inside, advice: advice))
        return
    }
    print("\(bold(pretty(path)))  \(amber(size(inside.bytes))) in \(inside.files) files\(inside.truncated ? dim(" (stopped early)") : "")")
    print("\nWhat it is made of")
    for t in inside.types { print("  \(amber(pad(size(t.bytes), 6)))  .\(t.ext)  \(dim("\(t.files) files"))") }
    print("\nLargest")
    for f in inside.largest.prefix(5) { print("  \(amber(pad(size(f.bytes), 6)))  \(f.path)  \(dim("\(f.ageDays)d"))") }
    print("\nRelies on it")
    if inside.reliance.isEmpty { print(green("  nothing found: no open files, launch jobs, config mentions or links")) }
    for r in inside.reliance { print("  \(r.blocking ? red("●") : amber("○")) \(r.detail)") }
    if !inside.excerpts.isEmpty {
        print("\nInside")
        for e in inside.excerpts {
            let first = e.text?.split(whereSeparator: \.isNewline).first.map(String.init) ?? "(\(e.kind))"
            print("  \(e.path): \(dim(String(first.prefix(90))))")
        }
    }
    if let a = advice {
        print("\n\(bold("AI")): \(a.what)\(a.owner.map { " (\($0))" } ?? "") · \(a.verdict.rawValue), \(a.action.rawValue) · \(Int(a.confidence * 100))% sure")
        print("  " + a.why)
    }
}

switch command {
case "inspect": inspect()
case "explain": explain()
case "top": top()
case "trash": trash()
case "clean": clean()
case "prompt": prompt()
default: worth()
}
