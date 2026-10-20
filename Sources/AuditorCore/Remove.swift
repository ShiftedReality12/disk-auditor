import Darwin
import Foundation

/// Why a path will not be removed. Each case is a promise the tests hold.
public enum Refusal: Equatable, CustomStringConvertible, Sendable {
    case missing
    case notUnderHome
    case holdsHome
    case protected
    case cloudSynced
    case mountPoint
    case holdsMount(String)
    case useTool([String]?)
    case gitWork(GitState)

    public var description: String {
        switch self {
        case .missing: return "not there"
        case .notUnderHome: return "only paths inside your home folder can be removed"
        case .holdsHome: return "it is, or holds, your home folder"
        case .protected: return "a folder macOS or your apps expect to exist; remove what is inside it instead"
        case .cloudSynced: return "iCloud/cloud-synced: removing it here removes it everywhere"
        case .mountPoint: return "another volume is mounted here"
        case .holdsMount(let mount): return "another volume is mounted inside it, at \(mount)"
        case .useTool(let command?): return "its owner cleans it: dsa clean (runs `\(command.joined(separator: " "))`)"
        case .useTool(nil): return "already in the Trash: Finder › Empty Trash frees it"
        case .gitWork(let state): return "\(state.summary): work that may exist nowhere else"
        }
    }
}

public enum Guard {
    /// Directories that must keep existing, relative to home.
    static let keep = [
        "Library", "Library/Application Support", "Library/Caches",
        "Library/Containers", "Library/Group Containers", "Library/Preferences",
        "Desktop", "Documents", "Downloads", "Applications", "Movies", "Music",
        "Pictures", ".config", ".local", ".cache",
    ]
    /// Subtrees whose deletion propagates to other devices or breaks login.
    static let synced = ["Library/Mobile Documents", "Library/CloudStorage", "Library/Keychains"]

    /// `nil` when `path` may go to the Trash. Checks in order of cost, so the
    /// git walk runs only for a path that passed everything else.
    public static func refusal(
        for path: String, home: String, allowGit: Bool = false
    ) -> Refusal? {
        let home = real(home)
        let target = resolved(path)
        var st = stat()
        guard lstat(target, &st) == 0 else { return .missing }
        if target == "/" || target == home || home.hasPrefix(target + "/") { return .holdsHome }
        guard target.hasPrefix(home + "/") else { return .notUnderHome }
        let relative = String(target.dropFirst(home.count + 1))
        if keep.contains(relative) { return .protected }
        if synced.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
            return .cloudSynced
        }
        if let rule = Rules.rule(for: target, home: home), !rule.trashable {
            return .useTool(rule.clean)
        }
        // A symlink is removed as a link; nothing it points at is touched.
        if st.st_mode & S_IFMT == S_IFLNK { return nil }
        var up = stat()
        if lstat((target as NSString).deletingLastPathComponent, &up) == 0, up.st_dev != st.st_dev {
            return .mountPoint
        }
        if let mount = mounts().first(where: { $0.hasPrefix(target + "/") }) {
            return .holdsMount(mount)
        }
        if !allowGit && st.st_mode & S_IFMT == S_IFDIR {
            let repos = Findings.repos(in: Scanner.scan(target).root)
            if !repos.isEmpty {
                let state = Git.state(of: repos)
                if !state.isClean { return .gitWork(state) }
            }
        }
        return nil
    }

    /// The path with every directory above it resolved, but not the path
    /// itself: a symlink stays the link.
    public static func resolved(_ path: String) -> String {
        let full = Scanner.normalize(path)
        if full == "/" { return full }
        let parent = (full as NSString).deletingLastPathComponent
        let name = (full as NSString).lastPathComponent
        let base = real(parent)
        return base == "/" ? "/" + name : base + "/" + name
    }

    public static func real(_ path: String) -> String {
        guard let buffer = realpath(path, nil) else { return Scanner.normalize(path) }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    static func mounts() -> [String] {
        var list: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&list, MNT_NOWAIT))
        guard let list else { return [] }
        return (0..<count).map { i in
            withUnsafePointer(to: list[i].f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
        }
    }
}

/// Free space on the volume holding a path.
public struct Space: Codable, Sendable {
    public let total: UInt64
    /// What `df` reports: free now.
    public let free: UInt64
    /// What Finder reports: free plus what macOS would purge on its own.
    public let withPurgeable: UInt64

    public static func of(_ path: String) -> Space {
        var fs = statfs()
        statfs(path, &fs)
        let block = UInt64(fs.f_bsize)
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = UInt64(fs.f_bavail) * block
        let important = values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        return Space(total: UInt64(fs.f_blocks) * block, free: free, withPurgeable: max(free, important ?? free))
    }
}

public enum Trash {
    /// Moves a path to the Trash, as Finder does. Returns where it went.
    public static func move(_ path: String) throws -> String {
        var landed: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &landed)
        return landed?.path ?? ""
    }

    /// Undoes `move`: puts the item back where it was, refusing to
    /// overwrite anything that has appeared there since.
    public static func putBack(from landed: String, to original: String) throws {
        try FileManager.default.moveItem(atPath: landed, toPath: original)
    }
}

public enum Cleaner {
    /// Runs a rule's clean command. `env` finds the tool on PATH; the
    /// arguments never meet a shell. Returns the exit status, or nil when
    /// the tool could not be started.
    public static func run(_ command: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
