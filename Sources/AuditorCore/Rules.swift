import Foundation

/// What a finding is, for the eye: one word per line of the list.
public enum Kind: String, Codable, Sendable {
    case cache, build, packages, models, toolchain, container, agent
    case logs, trash, worktree, checkout, archive, file
}

/// One row of the table: a place on this Mac, what it is, and how to get
/// its space back. The table is the only place this knowledge lives.
public struct Rule: Sendable {
    public enum Match: Sendable {
        /// A home-relative path. A trailing `/*` means each entry in it.
        case path(String)
        /// A directory name anywhere, optionally only beside one of `beside`.
        case name(String, beside: [String] = [])
    }

    public let match: Match
    public let kind: Kind
    public let why: String
    /// The owning tool's own command. When present it is the way to reclaim;
    /// otherwise the directory goes to the Trash.
    public let clean: [String]?
    /// Trashing it by hand would break its owner (Docker's disk) or means
    /// nothing (the Trash itself).
    public let trashable: Bool
    /// Comes back by itself or by one command, losing nothing you made.
    public let safe: Bool

    init(
        _ match: Match, _ kind: Kind, _ why: String, clean: [String]? = nil,
        trashable: Bool = true, safe: Bool
    ) {
        self.match = match
        self.kind = kind
        self.why = why
        self.clean = clean
        self.trashable = trashable
        self.safe = safe
    }
}

public enum Rules {
    // Tuned on a Mac used heavily by coding agents (PROMPT.md, P12): most of the
    // disk is agent-host state and tool caches, so those come first.
    public static let table: [Rule] = [
        // Agent hosts.
        Rule(.path("~/.codex/sessions"), .agent, "Codex transcripts: only for resuming or searching old sessions", safe: false),
        Rule(.path("~/.codex/archived_sessions"), .agent, "Codex archived transcripts", safe: false),
        Rule(.path("~/.codex/recovery-snapshots"), .agent, "Codex recovery snapshots of past edits", safe: false),
        Rule(.path("~/.codex/artifacts"), .agent, "files Codex produced: look before removing", safe: false),
        Rule(.path("~/.codex/runtime-sandboxes"), .agent, "Codex sandboxes, rebuilt on demand", safe: true),
        Rule(.path("~/.codex/insights"), .agent, "Codex insight cache", safe: true),
        Rule(.path("~/.grok/sessions"), .agent, "Grok transcripts", safe: false),
        Rule(.path("~/.hermes/sandboxes"), .agent, "Hermes sandboxes, rebuilt on demand", safe: true),
        Rule(.path("~/.claude/projects"), .agent, "Claude Code transcripts; also holds per-project memory/", safe: false),
        Rule(.path("~/Library/Application Support/Claude/vm_bundles"), .agent, "Claude desktop's VM image, downloaded again on next use (quit Claude first)", safe: true),
        Rule(.path("~/.cache/codex-runtimes"), .agent, "Codex runtimes, downloaded again on demand", safe: true),

        // Containers, packages and toolchains that have their own cleaner.
        Rule(.path("~/Library/Containers/com.docker.docker"), .container, "Docker's VM disk: unused images, stopped containers, build cache (volumes kept)", clean: ["docker", "system", "prune", "-a", "-f"], trashable: false, safe: true),
        Rule(.path("~/Library/Caches/Homebrew"), .packages, "Homebrew downloads", clean: ["brew", "cleanup", "--prune=all"], safe: true),
        Rule(.path("~/.cache/uv"), .packages, "uv package cache", clean: ["uv", "cache", "clean"], safe: true),
        Rule(.path("~/.npm/_cacache"), .packages, "npm package cache", clean: ["npm", "cache", "clean", "--force"], safe: true),
        Rule(.path("~/.bun/install/cache"), .packages, "bun package cache", clean: ["bun", "pm", "cache", "rm"], safe: true),
        Rule(.path("~/Library/Caches/pip"), .packages, "pip cache", clean: ["pip3", "cache", "purge"], safe: true),
        Rule(.path("~/Library/Developer/CoreSimulator/Devices"), .toolchain, "iOS simulators", clean: ["xcrun", "simctl", "delete", "unavailable"], safe: true),
        Rule(.path("~/Library/Developer/Xcode/DerivedData"), .build, "Xcode build output", safe: true),
        Rule(.path("~/Library/Developer/Xcode/iOS DeviceSupport"), .cache, "device symbols, fetched again on connect", safe: true),
        Rule(.path("~/Library/Caches/ms-playwright"), .toolchain, "Playwright browsers: `npx playwright install` restores", safe: true),
        Rule(.path("~/.rustup/toolchains"), .toolchain, "Rust toolchains: remove old ones with rustup", safe: false),
        Rule(.path("~/.nvm/versions/node"), .toolchain, "Node versions installed by nvm", safe: false),

        // Models.
        Rule(.path("~/.cache/huggingface"), .models, "downloaded model weights, fetched again on use", safe: true),
        Rule(.path("~/.cache/whisper"), .models, "Whisper model weights, fetched again on use", safe: true),
        Rule(.path("~/.ollama/models"), .models, "Ollama models: `ollama rm` the ones you don't run", safe: false),

        // Caches, logs, the Trash.
        Rule(.path("~/Library/Caches/*"), .cache, "app cache, rebuilt on demand", safe: true),
        Rule(.path("~/.cache/*"), .cache, "tool cache, rebuilt on demand", safe: true),
        Rule(.path("~/Library/Logs"), .logs, "app logs", safe: true),
        Rule(.path("~/.Trash"), .trash, "already in the Trash: Finder › Empty Trash frees it", trashable: false, safe: true),

        // Anywhere: build output and dependencies beside their manifest.
        Rule(.name("node_modules", beside: ["package.json"]), .packages, "dependencies: reinstall with the project's package manager", safe: true),
        Rule(.name("target", beside: ["Cargo.toml"]), .build, "Rust build output", safe: true),
        Rule(.name(".build", beside: ["Package.swift"]), .build, "Swift build output", safe: true),
        Rule(.name(".venv", beside: ["pyproject.toml", "requirements.txt", "setup.py"]), .packages, "Python virtualenv: `uv sync` rebuilds it", safe: true),
        Rule(.name("venv", beside: ["pyproject.toml", "requirements.txt", "setup.py"]), .packages, "Python virtualenv", safe: true),
        Rule(.name(".cache"), .cache, "a project's cache, rebuilt on demand", safe: true),
        Rule(.name(".next"), .build, "Next.js build output", safe: true),
        Rule(.name(".turbo"), .build, "Turborepo cache", safe: true),
        Rule(.name(".gradle"), .build, "Gradle cache", safe: true),
        Rule(.name("__pycache__"), .build, "Python bytecode", safe: true),
        Rule(.name(".pytest_cache"), .build, "pytest cache", safe: true),
        Rule(.name(".mypy_cache"), .build, "mypy cache", safe: true),
        Rule(.name(".ruff_cache"), .build, "ruff cache", safe: true),
        Rule(.name(".pnpm-store"), .packages, "pnpm store", clean: ["pnpm", "store", "prune"], safe: true),
    ]

    /// Checkouts, worktrees and big files untouched this long are listed.
    public static let staleDays = 90
    /// Smaller findings are not worth a line.
    public static let minBytes: UInt64 = 64 << 20
    static let bigFileBytes: UInt64 = 1 << 30
    static let bigCheckoutBytes: UInt64 = 256 << 20

    /// Paths a rule names exactly, and every directory above one. A generic
    /// rule never swallows a directory that holds a more specific one.
    struct Index {
        var exact: [String: Rule] = [:]
        var each: [String: Rule] = [:]
        var above: Set<String> = []
        var names: [String: [Rule]] = [:]
        let home: String

        init(home: String) {
            self.home = home
            for rule in Rules.table {
                switch rule.match {
                case .path(let pattern):
                    let full = home + pattern.dropFirst()
                    let isEach = full.hasSuffix("/*")
                    let base = isEach ? String(full.dropLast(2)) : full
                    if isEach { each[base] = rule } else { exact[base] = rule }
                    var up = (base as NSString).deletingLastPathComponent
                    // An `each` rule's own directory is above its entries.
                    if isEach { above.insert(base) }
                    while up.count > 1 {
                        above.insert(up)
                        up = (up as NSString).deletingLastPathComponent
                    }
                case .name(let name, _):
                    names[name, default: []].append(rule)
                }
            }
        }

        func rule(path: String, name: String, parent: String, hasSibling: (String) -> Bool) -> Rule? {
            if let rule = exact[path] { return rule }
            if above.contains(path) { return nil }
            if let rule = each[parent] { return rule }
            return names[name]?.first { rule in
                guard case .name(_, let beside) = rule.match else { return false }
                return beside.isEmpty || beside.contains(where: hasSibling)
            }
        }
    }

    /// The rule for one path on disk, for commands given a path by hand.
    public static func rule(for path: String, home: String) -> Rule? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let fm = FileManager.default
        return Index(home: home).rule(path: path, name: name, parent: parent) {
            fm.fileExists(atPath: parent + "/" + $0)
        }
    }
}
