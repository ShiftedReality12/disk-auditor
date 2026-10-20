import Foundation

/// What is marked for removal, keyed by absolute path. Marks never nest: a
/// marked folder takes what is inside it with it, so the saving shown is
/// never counted twice.
public struct Marks: Sendable, Hashable {
    public private(set) var bytes: [String: UInt64] = [:]

    public init() {}

    public var total: UInt64 { bytes.values.reduce(0, +) }
    public var count: Int { bytes.count }
    public var paths: [String] { bytes.keys.sorted { bytes[$0]! > bytes[$1]! } }

    public func contains(_ path: String) -> Bool { bytes[path] != nil }

    /// The marked folder that already covers `path`, if any.
    public func covering(_ path: String) -> String? {
        bytes.keys.first { path.hasPrefix($0 + "/") }
    }

    /// Marks or unmarks `path`. Marking a folder absorbs marks inside it;
    /// something inside a marked folder cannot be marked on its own.
    /// Returns false when nothing changed for that reason.
    @discardableResult
    public mutating func toggle(_ path: String, bytes size: UInt64) -> Bool {
        if bytes[path] != nil {
            bytes[path] = nil
            return true
        }
        if covering(path) != nil { return false }
        for inside in bytes.keys where inside.hasPrefix(path + "/") { bytes[inside] = nil }
        bytes[path] = size
        return true
    }

    public mutating func remove(_ path: String) { bytes[path] = nil }
    public mutating func clear() { bytes = [:] }
}

public enum Format {
    /// Binary units, as `df -h` and Finder's "Get Info" in bytes mode read.
    public static func size(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 100 { return String(format: "%.0f GB", gib) }
        if gib >= 1 { return String(format: "%.1f GB", gib) }
        let mib = Double(bytes) / 1_048_576
        return mib >= 1 ? String(format: "%.0f MB", mib) : String(format: "%.0f KB", Double(bytes) / 1024)
    }

    public static func age(_ days: Int) -> String {
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case ..<60: return "\(days) days ago"
        case ..<730: return "\(days / 30) months ago"
        default: return "\(days / 365) years ago"
        }
    }
}

public enum AgentPrompt {
    /// A hand-off for a coding agent: exactly these paths, each checked
    /// first, reclaimed the owner's way, never with `rm -rf`.
    public static func text(_ items: [(path: String, finding: Finding?)]) -> String {
        var lines = [
            "Free disk space on this Mac by removing exactly the paths below — nothing else.",
            "",
            "For each path, first check it:",
            "- If it is or holds a git checkout, confirm every change is committed and pushed. If not, stop and tell me.",
            "- If a tool owns it (docker, brew, uv, npm, bun, pnpm, xcrun simctl, cargo), use that tool's own clean command instead of removing files.",
            "- Otherwise move it to the Trash with `trash <path>` (macOS 15+), never `rm -rf`.",
            "- Quit an app before removing its data.",
            "",
            "Paths:",
        ]
        for item in items {
            // A name holding a newline could pass for a second path.
            guard !item.path.contains("\n") else { continue }
            var line = "- \(item.path)"
            if let f = item.finding {
                line += "  (\(Format.size(f.bytes)), \(f.kind.rawValue): \(f.why)"
                if let git = f.git { line += "; \(git.summary)" }
                if let clean = f.clean { line += "; cleaner: `\(clean.joined(separator: " "))`" }
                line += ")"
            }
            lines.append(line)
        }
        lines += ["", "Report the free space before and after (`df -h /System/Volumes/Data`)."]
        return lines.joined(separator: "\n")
    }
}
