import Foundation

/// What git says about the checkouts under one path.
public struct GitState: Codable, Sendable, Equatable {
    public var repos = 0
    /// Uncommitted changes, untracked files included.
    public var dirty = 0
    /// Commits on a local branch that no remote has.
    public var unpushed = 0
    public var stashed = 0
    /// Not asked (it defines its own filter drivers) or git failed.
    public var unknown = 0
    /// Worktrees whose repository moved or was deleted: git cannot see them.
    public var orphaned = 0

    public var isClean: Bool { dirty + unpushed + stashed + unknown + orphaned == 0 }

    public var summary: String {
        if isClean { return repos == 1 ? "git: all pushed" : "git: \(repos) repos, all pushed" }
        var parts: [String] = []
        if dirty > 0 { parts.append("\(dirty) dirty") }
        if unpushed > 0 { parts.append("\(unpushed) unpushed") }
        if stashed > 0 { parts.append("\(stashed) stashed") }
        if unknown > 0 { parts.append("\(unknown) unknown") }
        if orphaned > 0 { parts.append("\(orphaned) orphaned worktree\(orphaned == 1 ? "" : "s") (repo moved: `git worktree repair`)") }
        return "git: " + parts.joined(separator: ", ") + (repos > 1 ? " of \(repos)" : "")
    }
}

public enum Git {
    /// Asks every checkout at once; one slow repository does not hold up the rest.
    public static func state(of repos: [String]) -> GitState {
        let results = Locked([Check]())
        DispatchQueue.concurrentPerform(iterations: repos.count) { i in
            let check = self.check(repos[i])
            results.with { $0.append(check) }
        }
        var state = GitState(repos: repos.count)
        for check in results.value {
            switch check {
            case .unknown: state.unknown += 1
            case .orphaned: state.orphaned += 1
            case .known(let dirty, let unpushed, let stashed):
                if dirty { state.dirty += 1 }
                if unpushed { state.unpushed += 1 }
                if stashed { state.stashed += 1 }
            }
        }
        return state
    }

    enum Check { case known(dirty: Bool, unpushed: Bool, stashed: Bool), unknown, orphaned }

    static func check(_ repo: String) -> Check {
        // A worktree's `.git` is a file naming its repository's record of it.
        if let link = try? String(contentsOfFile: repo + "/.git", encoding: .utf8),
           link.hasPrefix("gitdir: ") {
            let target = link.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
            let absolute = target.hasPrefix("/") ? target : repo + "/" + target
            if !FileManager.default.fileExists(atPath: absolute) { return .orphaned }
        }
        // A filter driver is a program the checkout names; asking for
        // status would run it. Such a checkout is reported, not asked.
        if let filters = run(["config", "--local", "--get-regexp", "^filter\\."], in: repo),
           !filters.isEmpty {
            return .unknown
        }
        guard let status = run(["status", "--porcelain"], in: repo),
              let unpushed = run(["log", "--branches", "--not", "--remotes", "--oneline", "-1"], in: repo),
              let stash = run(["stash", "list"], in: repo)
        else { return .unknown }
        return .known(dirty: !status.isEmpty, unpushed: !unpushed.isEmpty, stashed: !stash.isEmpty)
    }

    /// Runs git with its hooks, fsmonitor and pager off, so looking at a
    /// checkout never runs a program the checkout chose. `nil` on failure,
    /// except `config` which exits 1 when nothing matches.
    static func run(_ args: [String], in repo: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", repo, "--no-pager", "-c", "core.fsmonitor=false",
            "-c", "core.hooksPath=/dev/null",
        ] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0 { return text }
        if args.first == "config" && process.terminationStatus == 1 { return "" }
        return nil
    }
}
