import Foundation

/// What a folder is, for colour: every node gets one, so the whole map
/// reads at a glance. Whether it can go is a separate question
/// (`Finding`), drawn as a hatch over the colour.
public enum Category: String, Codable, Sendable, CaseIterable {
    case code, agent, toolchain, cache, git, media, documents, synced, apps, other

    public var label: String {
        switch self {
        case .code: return "Code"
        case .agent: return "Agent state"
        case .toolchain: return "Toolchains"
        case .cache: return "Cache"
        case .git: return "Git"
        case .media: return "Media & models"
        case .documents: return "Documents"
        case .synced: return "Synced"
        case .apps: return "App data"
        case .other: return "Other"
        }
    }
}

public enum Classify {
    /// Directory names that say what they hold. Tuned for a developer's Mac: the
    /// agent hosts in `~` are their own category because they are the
    /// largest thing on it.
    static func category(of name: String) -> Category? {
        switch name.lowercased() {
        case "src", "code", "projects", "repos", "dev", "work", "workspace", "workspaces",
             "github.com", "gitlab.com", "sites", "development":
            return .code
        case ".codex", ".claude", ".grok", ".hermes", ".cursor", ".gemini", ".kimi-code", ".prime",
             ".agents", ".aider", ".continue", ".windsurf", ".codex-cli-latest", ".openai",
             "worktrees", ".worktrees", "_worktrees", "tries", "experiments", "scratch", "playground":
            return .agent
        case ".cargo", ".rustup", ".local", ".npm", ".pnpm-store", ".bun", ".deno", "go", ".gradle",
             ".m2", ".pyenv", ".nvm", ".gem", ".rbenv", ".config", ".vscode", ".conda", ".volta",
             ".yarn", ".java", ".nuget", ".mise", "mise", ".docker", ".orbstack", "homebrew",
             "xcode", "coresimulator", "developer", "com.docker.docker":
            return .toolchain
        case ".cache", "cache", "caches", "__pycache__", "node_modules", "tmp", ".tmp", "temp",
             "deriveddata", "logs", "npm-cache", "_cacache", ".trash":
            return .cache
        case ".git":
            return .git
        case "pictures", "photos", "music", "movies", "videos", "models", ".ollama", ".lmstudio",
             "whisper", "huggingface":
            return .media
        case "documents", "desktop", "downloads", "books", "notes", "obsidian":
            return .documents
        case "mobile documents", "cloudstorage", "iclouddrive", "dropbox", "google drive", "onedrive":
            return .synced
        case "application support", "containers", "group containers":
            return .apps
        default:
            return nil
        }
    }

    /// Gives every node a category: its own name's, or its parent's. A
    /// top-level folder with an unknown name takes the category of what
    /// dominates it, and a checkout counts as code.
    public static func classify(_ root: Node) {
        root.category = .other
        for child in root.children {
            let own = category(of: child.name)
                ?? (child.isRepo ? .code : nil)
                ?? dominant(child)
                ?? .other
            below(child, own)
        }
    }

    private static func below(_ node: Node, _ category: Category) {
        node.category = category
        for child in node.children {
            // A checkout kept among documents or app data is still code.
            let repo = child.isRepo && [.documents, .apps, .other].contains(category)
            below(child, child.isDir ? (Classify.category(of: child.name) ?? (repo ? .code : category)) : category)
        }
    }

    /// The first named category down the largest path, three levels at most.
    private static func dominant(_ node: Node) -> Category? {
        var node = node
        for _ in 0..<3 {
            for child in node.children where child.isDir {
                if let found = category(of: child.name) ?? (child.isRepo ? .code : nil) { return found }
            }
            guard let next = node.children.first(where: \.isDir) else { return nil }
            node = next
        }
        return nil
    }

    /// Bytes per category under `root`. Exact: every byte is counted once,
    /// under the category of the node that holds it directly.
    public static func totals(_ root: Node) -> [Category: UInt64] {
        var out: [Category: UInt64] = [:]
        func walk(_ node: Node) {
            if node.isDir {
                out[node.category, default: 0] += node.looseBytes
                for child in node.children { walk(child) }
            } else {
                out[node.category, default: 0] += node.bytes
            }
        }
        walk(root)
        return out
    }
}
