@testable import AuditorCore
import Foundation
import Testing

// Every test works on real files in a fresh temporary directory, which also
// stands in for the home folder so the guards can be exercised without
// pointing them at the real one.

final class Sandbox {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = Guard.real(base.path)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    func dir(_ path: String) throws -> String {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 4096) throws -> String {
        let full = root + "/" + path
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        // Random bytes, so APFS cannot compress or dedupe them away.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: URL(fileURLWithPath: full))
        return full
    }

    func sh(_ args: String..., in dir: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir ?? root)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "sh", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")])
        }
    }

    func repo(_ path: String) throws -> String {
        let full = try dir(path)
        try sh("git", "init", "-q", "-b", "main", in: full)
        try file(path + "/a.txt")
        try sh("git", "add", ".", in: full)
        try sh("git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "one", in: full)
        return full
    }

    func duBytes(_ path: String) throws -> UInt64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return UInt64(text.split(separator: "\t").first ?? "0")! * 1024
    }
}

// MARK: measuring

@Test func totalsMatchDu() throws {
    let s = try Sandbox()
    for i in 0..<40 { try s.file("a/b\(i % 4)/f\(i)", bytes: 1000 * (i + 1)) }
    try s.file("big/one", bytes: 70 << 20)
    let scan = Scanner.scan(s.root)
    #expect(scan.root.bytes == (try s.duBytes(s.root)))
    #expect(scan.root.files == 41)
    // The 70 MB file is big enough to be named; the small ones are only counted.
    #expect(scan.root.child(named: "big")?.children.first?.name == "one")
    #expect(scan.root.child(named: "a")?.child(named: "b0")?.children.isEmpty == true)
}

@Test func hardlinksCountOnce() throws {
    let s = try Sandbox()
    let first = try s.file("x/one", bytes: 1 << 20)
    try FileManager.default.linkItem(atPath: first, toPath: s.root + "/x/two")
    let scan = Scanner.scan(s.root)
    let x = try #require(scan.root.child(named: "x"))
    #expect(x.bytes >= 1 << 20)
    #expect(x.bytes < 2 << 20)
}

@Test func sparseFileCountsAllocatedNotApparent() throws {
    let s = try Sandbox()
    let path = s.root + "/sparse"
    let fd = open(path, O_CREAT | O_WRONLY, 0o644)
    ftruncate(fd, 1 << 30)
    close(fd)
    #expect(Scanner.scan(s.root).root.bytes < 1 << 20)
}

@Test func symlinksAreNotFollowed() throws {
    let s = try Sandbox()
    try s.file("real/data", bytes: 2 << 20)
    try FileManager.default.createSymbolicLink(atPath: s.root + "/link", withDestinationPath: s.root + "/real")
    let scan = Scanner.scan(s.root)
    #expect(scan.root.child(named: "link") == nil)
    #expect(scan.root.bytes < 3 << 20)
}

// MARK: classifying

@Test func buildOutputNeedsItsManifest() throws {
    let s = try Sandbox()
    try s.file("rust/Cargo.toml", bytes: 10)
    try s.file("rust/target/big", bytes: 70 << 20)
    try s.file("other/target/big", bytes: 70 << 20)  // no Cargo.toml: someone's own folder
    let found = Findings.worthALook(Scanner.scan(s.root), home: s.root)
    #expect(found.map(\.path) == [s.root + "/rust/target"])
    #expect(found.first?.kind == .build)
}

@Test func specificRuleBeatsGenericAndParentIsNotSwallowed() throws {
    let s = try Sandbox()
    try s.file(".cache/uv/wheels", bytes: 70 << 20)
    try s.file(".cache/someapp/blob", bytes: 70 << 20)
    let found = Findings.worthALook(Scanner.scan(s.root), home: s.root)
    let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.path, $0) })
    #expect(byPath[s.root + "/.cache"] == nil)
    #expect(byPath[s.root + "/.cache/uv"]?.clean == ["uv", "cache", "clean"])
    #expect(byPath[s.root + "/.cache/someapp"]?.kind == .cache)
}

@Test func findingsNeverNest() throws {
    let s = try Sandbox()
    try s.file("old - STALE/app/package.json", bytes: 10)
    try s.file("old - STALE/app/node_modules/x", bytes: 70 << 20)
    let found = Findings.worthALook(Scanner.scan(s.root), home: s.root)
    #expect(found.map(\.path) == [s.root + "/old - STALE"])
    #expect(found.first?.kind == .archive)
}

// MARK: guards

@Test func refusesOutsideHomeAndHomeItself() throws {
    let s = try Sandbox()
    let home = try s.dir("home")
    let outside = try s.file("elsewhere/x")
    #expect(Guard.refusal(for: outside, home: home) == .notUnderHome)
    #expect(Guard.refusal(for: home, home: home) == .holdsHome)
    #expect(Guard.refusal(for: s.root, home: home) == .holdsHome)
    #expect(Guard.refusal(for: "/", home: home) == .holdsHome)
    #expect(Guard.refusal(for: home + "/nope", home: home) == .missing)
    let fine = try s.file("home/junk/x")
    #expect(Guard.refusal(for: (fine as NSString).deletingLastPathComponent, home: home) == nil)
}

@Test func refusesProtectedAndSyncedAndOwnedPaths() throws {
    let s = try Sandbox()
    let home = try s.dir("home")
    try s.dir("home/Library/Caches/app")
    try s.file("home/Library/Mobile Documents/com~apple~CloudDocs/doc")
    try s.dir("home/Library/Containers/com.docker.docker/Data")
    #expect(Guard.refusal(for: home + "/Library", home: home) == .protected)
    #expect(Guard.refusal(for: home + "/Library/Caches", home: home) == .protected)
    #expect(Guard.refusal(for: home + "/Library/Caches/app", home: home) == nil)
    #expect(Guard.refusal(for: home + "/Library/Mobile Documents/com~apple~CloudDocs/doc", home: home) == .cloudSynced)
    #expect(Guard.refusal(for: home + "/Library/Containers/com.docker.docker", home: home)
        == .useTool(["docker", "system", "prune", "-a", "-f"]))
}

@Test func dotDotCannotEscapeHome() throws {
    let s = try Sandbox()
    let home = try s.dir("home")
    try s.file("secret/x")
    #expect(Guard.refusal(for: home + "/../secret", home: home) == .notUnderHome)
}

@Test func symlinkIsTrashedAsALink() throws {
    let s = try Sandbox()
    let home = try s.dir("home")
    let sentinel = try s.file("home/keep/data")
    try FileManager.default.createSymbolicLink(atPath: home + "/link", withDestinationPath: home + "/keep")
    #expect(Guard.refusal(for: home + "/link", home: home) == nil)
    let landed = try Trash.move(home + "/link")
    defer { try? FileManager.default.removeItem(atPath: landed) }
    #expect(FileManager.default.fileExists(atPath: sentinel))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: landed)) != nil)
}

@Test func hostileNamesAreJustNames() throws {
    let s = try Sandbox()
    let home = try s.dir("home")
    let odd = try s.file("home/$(touch pwned); -rf")
    #expect(Guard.refusal(for: odd, home: home) == nil)
    let landed = try Trash.move(odd)
    defer { try? FileManager.default.removeItem(atPath: landed) }
    #expect(!FileManager.default.fileExists(atPath: odd))
    #expect(!FileManager.default.fileExists(atPath: home + "/pwned"))
    #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/pwned"))
}

@Test func refusesMountPointsAndWhatHoldsThem() throws {
    let s = try Sandbox()
    let home = try s.dir("home")
    let mount = try s.dir("home/outer/disk")
    let image = s.root + "/tiny.dmg"
    try s.sh("hdiutil", "create", "-quiet", "-size", "2m", "-fs", "HFS+", "-volname", "dsa", image)
    try s.sh("hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", mount, image)
    defer { try? s.sh("hdiutil", "detach", "-quiet", "-force", mount) }
    #expect(Guard.refusal(for: mount, home: home) == .mountPoint)
    #expect(Guard.refusal(for: home + "/outer", home: home) == .holdsMount(mount))
}

// MARK: git

@Test func unpushedWorkIsRefusedUntilPushed() throws {
    let s = try Sandbox()
    let home = try s.dir("home")
    let repo = try s.repo("home/proj")
    #expect(Guard.refusal(for: repo, home: home) == .gitWork(GitState(repos: 1, unpushed: 1)))
    #expect(Guard.refusal(for: repo, home: home, allowGit: true) == nil)
    try s.sh("git", "init", "-q", "--bare", s.root + "/remote.git")
    try s.sh("git", "remote", "add", "origin", s.root + "/remote.git", in: repo)
    try s.sh("git", "push", "-q", "origin", "main", in: repo)
    #expect(Guard.refusal(for: repo, home: home) == nil)
    try s.file("home/proj/new.txt")
    #expect(Guard.refusal(for: repo, home: home) == .gitWork(GitState(repos: 1, dirty: 1)))
}

@Test func orphanedWorktreeIsNamed() throws {
    let s = try Sandbox()
    let repo = try s.repo("main")
    try s.sh("git", "worktree", "add", "-q", s.root + "/wt", in: repo)
    try FileManager.default.moveItem(atPath: repo, toPath: s.root + "/moved")
    #expect(Git.state(of: [s.root + "/wt"]) == GitState(repos: 1, orphaned: 1))
}

@Test func askingGitWritesNothing() throws {
    let s = try Sandbox()
    let repo = try s.repo("r")
    try s.file("r/a.txt")  // same name, new bytes: status would want to refresh the index
    let index = repo + "/.git/index"
    let before = try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date
    Thread.sleep(forTimeInterval: 1.1)
    _ = Git.state(of: [repo])
    let after = try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date
    #expect(before == after)
}

// MARK: growth

@Test func growthNamesTheChildThatGrew() {
    let before = Snapshot(when: Date(), root: "/h", findings: [], sizes: ["/h": 10 << 30, "/h/a": 5 << 30, "/h/a/b": 1 << 30, "/h/c": 1 << 30])
    let now: [String: UInt64] = ["/h": 14 << 30, "/h/a": 9 << 30, "/h/a/b": 5 << 30, "/h/c": 1 << 30]
    let grew = before.growth(to: now)
    #expect(grew.map(\.0) == ["/h/a/b"])
}

// MARK: the JSON contract

@Test func jsonSafeAccountsForGitAndKeepsEveryKey() throws {
    var finding = Finding(
        path: "/h/p", bytes: 1, files: 1, ageDays: 1, kind: .checkout,
        why: "x", clean: nil, trashable: true, ruleSafe: true
    )
    finding.git = GitState(repos: 1, unpushed: 1)
    let data = try JSONEncoder().encode(finding)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["safe"] as? Bool == false)
    #expect(object["rule_safe"] as? Bool == true)
    #expect(object.keys.contains("clean") && object["clean"] is NSNull)
    // The snapshot reads its own output back.
    let back = try JSONDecoder().decode(Finding.self, from: data)
    #expect(back.git == finding.git && back.safe == false)
}

// MARK: treemap, marks, undo

@Test func treemapAreasAreProportionalAndInside() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
    let sizes: [Double] = [50, 0, 25, 12, 8, 3, 1, 1]
    let rects = Treemap.layout(sizes, in: bounds)
    let total = sizes.reduce(0, +)
    for (size, rect) in zip(sizes, rects) {
        let expected = size / total * 800 * 500
        #expect(abs(Double(rect.width * rect.height) - expected) < 1)
        #expect(size == 0 || bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect))
    }
    for a in rects.indices where sizes[a] > 0 {
        for b in rects.indices where b > a && sizes[b] > 0 {
            let overlap = rects[a].intersection(rects[b])
            #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
        }
    }
    // Squarified, not sliced: the largest tile is not a thin strip.
    let big = rects[0]
    #expect(max(big.width / big.height, big.height / big.width) < 3)
}

@Test func marksNeverNestOrDoubleCount() {
    var marks = Marks()
    var changed = marks.toggle("/h/a/b", bytes: 10)
    #expect(changed)
    changed = marks.toggle("/h/a/c", bytes: 5)
    changed = marks.toggle("/h/a", bytes: 100)        // absorbs b and c
    #expect(changed && marks.paths == ["/h/a"] && marks.total == 100)
    changed = marks.toggle("/h/a/b", bytes: 10)       // covered: refused
    #expect(!changed && marks.total == 100)
    changed = marks.toggle("/h/ab", bytes: 7)          // shares a prefix, is not inside
    #expect(changed && marks.total == 107)
    changed = marks.toggle("/h/a", bytes: 100)        // unmark
    #expect(changed && marks.paths == ["/h/ab"])
}

@Test func trashIsUndoable() throws {
    let s = try Sandbox()
    let path = try s.file("undo/me", bytes: 1234)
    let landed = try Trash.move(path)
    #expect(!FileManager.default.fileExists(atPath: path))
    try Trash.putBack(from: landed, to: path)
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(!FileManager.default.fileExists(atPath: landed))
}

@Test func cleanerRunsArgvWithoutAShell() throws {
    let s = try Sandbox()
    #expect(Cleaner.run(["true"]) == 0)
    #expect(Cleaner.run(["false"]) == 1)
    #expect(Cleaner.run(["touch", s.root + "/$(touch pwned)"]) == 0)
    #expect(FileManager.default.fileExists(atPath: s.root + "/$(touch pwned)"))
    #expect(!FileManager.default.fileExists(atPath: s.root + "/pwned"))
}

// MARK: categories

@Test func everyByteHasACategoryWithNamesWinning() throws {
    let s = try Sandbox()
    try s.file("dev/app/main.swift", bytes: 5000)
    try s.file("dev/app/node_modules/x/y.js", bytes: 7000)
    try s.file(".codex/sessions/a.jsonl", bytes: 9000)
    try s.file("mystery/Pictures/a.jpg", bytes: 3000)   // unknown top folder, dominated by media
    try s.file("loose.bin", bytes: 1000)
    _ = try s.repo("Desktop/proj")                         // a checkout on the Desktop is code
    try s.file("Desktop/notes.txt", bytes: 100)
    try s.file(".codex/worktrees/wt/.git", bytes: 40)      // but an agent's worktree stays agent state
    let scan = Scanner.scan(s.root)
    let dev = try #require(scan.root.child(named: "dev"))
    #expect(dev.category == .code)
    #expect(dev.child(named: "app")?.child(named: "node_modules")?.category == .cache)
    #expect(scan.root.child(named: ".codex")?.category == .agent)
    #expect(scan.root.child(named: "mystery")?.category == .media)
    #expect(scan.root.child(named: "Desktop")?.category == .documents)
    #expect(scan.root.child(named: "Desktop")?.child(named: "proj")?.category == .code)
    #expect(scan.root.child(named: ".codex")?.child(named: "worktrees")?.child(named: "wt")?.category == .agent)
    let totals = Classify.totals(scan.root)
    #expect(totals.values.reduce(0, +) == scan.root.bytes)   // exact: nothing lost or doubled
    #expect((totals[.cache] ?? 0) > 0 && (totals[.agent] ?? 0) > 0)
}

// MARK: advisor

@Test func suspectsAreTheMostSpecificUnexplainedFolders() throws {
    let s = try Sandbox()
    try s.file("apps/Thing/blob1", bytes: 300 << 20)
    try s.file("apps/Thing/blob2", bytes: 300 << 20)      // 600 MB unexplained, no big child: a suspect
    try s.file("apps/small/x", bytes: 10 << 20)
    try s.file("proj/package.json", bytes: 10)
    try s.file("proj/node_modules/big", bytes: 700 << 20) // explained by a rule: never sent
    let repo = try s.repo("repo")
    try s.file("repo/sub/a", bytes: 600 << 20)              // big enough to be a suspect on its own:
    try s.file("repo/sub2/b", bytes: 10 << 20)              // only the checkout rule keeps it whole
    let scan = Scanner.scan(s.root)
    let found = Findings.worthALook(scan, home: s.root)
    let paths = Advisor.suspects(scan, findings: found).map(\.path)
    #expect(paths.contains(s.root + "/apps/Thing"))
    #expect(!paths.contains(s.root + "/apps"))
    #expect(!paths.contains { $0.hasPrefix(s.root + "/proj") })
    #expect(paths.contains(repo) && !paths.contains(repo + "/sub"))
}

@Test func adviceParsesAndErrorsAreNeverAdvice() throws {
    let ok = #"{"is_error":false,"structured_output":{"advice":[{"path":"/h/x","what":"Cursor updater cache","owner":"Cursor","verdict":"regenerable","action":"remove","command":null,"why":"re-downloaded on next update","confidence":0.9}]}}"#
    let advice = try Advisor.parse(Data(ok.utf8))
    #expect(advice.count == 1 && advice[0].verdict == .regenerable && advice[0].worthALook)
    let failed = #"{"is_error":true,"result":"rate limited"}"#
    #expect(throws: Advisor.Failure.self) { try Advisor.parse(Data(failed.utf8)) }
    #expect(throws: Advisor.Failure.self) { try Advisor.parse(Data("not json".utf8)) }
    // A model's suggestion is never shown as safe, whatever it says.
    let suspect = Suspect(path: "/h/x", bytes: 1 << 30, files: 3, ageDays: 90, isRepo: false, children: [])
    #expect(Finding(advice: advice[0], suspect: suspect).safe == false)
}

@Test func aDatedRunIsJudgedWhole() throws {
    let s = try Sandbox()
    try s.file("artifacts/proof-2026-06-27/demo/work/outputs/a", bytes: 600 << 20)
    let scan = Scanner.scan(s.root)
    let paths = Advisor.suspects(scan, findings: []).map(\.path)
    #expect(paths == [s.root + "/artifacts/proof-2026-06-27"])
    #expect(Advisor.looksLikeARun("Synthetic_Corpora 3"))
    #expect(Advisor.looksLikeARun("build_2bc2b7e35bc245c8a0f7848913c640b7"))
    #expect(!Advisor.looksLikeARun("Application Support"))
}

// MARK: look inside

@Test func lookInsideSamplesSafelyAndSeesWhatItIs() throws {
    let s = try Sandbox()
    let dir = try s.dir("proj")
    try "# Proj\nA tool that does things.\nkey: sk-ant-abcdefghijklmnopqrstuvwxyz0123\n"
        .write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
    try "OPENAI_API_KEY=sk-live-should-never-be-read\n".write(toFile: dir + "/.env", atomically: true, encoding: .utf8)
    // A .json is a sampling candidate by its extension: only the name check keeps it unread.
    try "{\"client_id\": \"plain-looking-value\"}".write(toFile: dir + "/credentials.json", atomically: true, encoding: .utf8)
    try Data("SQLite format 3\u{0}".utf8 + Array(repeating: UInt8(1), count: 4000)).write(to: URL(fileURLWithPath: dir + "/data.db"))
    try s.file("proj/big.bin", bytes: 3 << 20)
    let inside = Inspector.look(dir, home: s.root)
    #expect(inside.files == 5)
    #expect(inside.largest.first?.path == "big.bin")
    let readme = try #require(inside.excerpts.first { $0.path == "README.md" })
    #expect(readme.text?.contains("A tool that does things") == true)
    #expect(readme.text?.contains("sk-ant-") == false)           // redacted
    #expect(!inside.excerpts.contains { $0.path == ".env" || $0.path == "credentials.json" })  // never read
    #expect(inside.excerpts.contains { $0.path == "data.db" && $0.kind == "sqlite" } ||
            !inside.largest.prefix(3).contains { $0.path == "data.db" })
    #expect(Inspector.sample(dir, "data.db")?.kind == "sqlite")
}

@Test func relianceFindsOpenFilesConfigAndLeftovers() throws {
    let s = try Sandbox()
    let dir = try s.dir("tool/data")
    let held = try s.file("tool/data/held.log", bytes: 100)
    let handle = try #require(FileHandle(forReadingAtPath: held))   // this test process keeps it open
    defer { try? handle.close() }
    try "export PATH=\"$HOME/tool/data/bin:$PATH\"\n".write(toFile: s.root + "/.zshrc", atomically: true, encoding: .utf8)
    let found = Inspector.reliance(dir, home: s.root)
    #expect(found.contains { $0.kind == .process && $0.blocking })
    #expect(found.contains { $0.kind == .config && $0.detail.contains(".zshrc") })
    let other = try s.dir("elsewhere")
    #expect(Inspector.reliance(other, home: s.root).isEmpty)       // nothing relies on it
    // Measured case: Cursor's updater cache is named <bundle id>.ShipIt.
    let plist = try s.dir("Applications/Cursor.app/Contents") + "/Info.plist"
    try (["CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"] as NSDictionary).write(toFile: plist, atomically: true)
    let helper = try s.dir("Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt")
    #expect(Inspector.appOwner(of: helper, home: s.root)?.detail.contains("Cursor, which is installed") == true)
    let orphan = try s.dir("Library/Application Support/com.gone.app.helper")
    let owner = try #require(Inspector.appOwner(of: orphan, home: s.root))
    #expect(owner.detail.contains("left behind"))
}
