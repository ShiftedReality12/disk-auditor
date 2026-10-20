import Foundation

/// What is inside one folder, and what depends on it: the evidence a
/// person, or the model, needs to decide whether it can go. Built locally;
/// nothing leaves the Mac unless the person asks the model about it.
public struct Inside: Codable, Sendable {
    public struct File: Codable, Sendable, Hashable {
        /// Relative to the folder.
        public let path: String
        public let bytes: UInt64
        public let ageDays: Int
    }

    public struct FileType: Codable, Sendable, Hashable {
        public let ext: String
        public let files: Int
        public let bytes: UInt64
    }

    public struct Excerpt: Codable, Sendable, Hashable {
        public let path: String
        /// text, sqlite, zip, pdf, image, executable, or binary.
        public let kind: String
        public let text: String?
    }

    public let path: String
    public let bytes: UInt64
    public let files: Int
    /// The walk stopped early; the numbers describe what was read.
    public let truncated: Bool
    public let types: [FileType]
    public let largest: [File]
    public let newest: [File]
    public let excerpts: [Excerpt]
    public let reliance: [Reliance]
}

/// One reason something may depend on a folder.
public struct Reliance: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case process, launchd, config, symlink, app, git }
    public let kind: Kind
    public let detail: String
    /// Removing the folder would break or lose something right now.
    public let blocking: Bool
}

public enum Inspector {
    static let maxEntries = 300_000
    static let deadline: TimeInterval = 4

    /// Walks `path` (bounded in entries and time), samples readable files,
    /// and checks what relies on it.
    public static func look(_ path: String, home: String) -> Inside {
        let root = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        let started = Date()
        let now = Date()
        var byExt: [String: (Int, UInt64)] = [:]
        var all: [(String, UInt64, Date)] = []
        var total: UInt64 = 0
        var truncated = false
        if let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) {
            for case let url as URL in walk {
                if all.count >= maxEntries || Date().timeIntervalSince(started) > deadline { truncated = true; break }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let bytes = UInt64(v.totalFileAllocatedSize ?? 0)
                let rel = String(url.path.dropFirst(root.path.count + 1))
                let ext = url.pathExtension.isEmpty ? "(none)" : url.pathExtension.lowercased()
                byExt[ext, default: (0, 0)].0 += 1
                byExt[ext, default: (0, 0)].1 += bytes
                all.append((rel, bytes, v.contentModificationDate ?? .distantPast))
                total += bytes
            }
        }
        let age = { (d: Date) in max(0, Int(now.timeIntervalSince(d) / 86_400)) }
        let types = byExt.map { Inside.FileType(ext: $0.key, files: $0.value.0, bytes: $0.value.1) }
            .sorted { $0.bytes > $1.bytes }.prefix(8)
        let largest = all.sorted { $0.1 > $1.1 }.prefix(8).map { Inside.File(path: $0.0, bytes: $0.1, ageDays: age($0.2)) }
        let newest = all.sorted { $0.2 > $1.2 }.prefix(5).map { Inside.File(path: $0.0, bytes: $0.1, ageDays: age($0.2)) }
        return Inside(
            path: path, bytes: total, files: all.count, truncated: truncated,
            types: Array(types), largest: Array(largest), newest: Array(newest),
            excerpts: excerpts(root: path, files: all.map(\.0), largest: largest.map(\.path)),
            reliance: reliance(path, home: home)
        )
    }

    // MARK: excerpts

    static let textExtensions: Set<String> = [
        "md", "txt", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "log", "csv", "tsv",
        "py", "js", "ts", "tsx", "swift", "rs", "go", "rb", "sh", "zsh", "html", "xml", "sql", "plist",
    ]

    /// Files that may hold credentials are never read, whatever they contain.
    static func looksSecret(_ name: String) -> Bool {
        let lower = (name as NSString).lastPathComponent.lowercased()
        return lower.hasPrefix(".env") || lower.hasPrefix("id_") || lower.contains("secret")
            || lower.contains("credential") || lower.contains("token") || lower.contains("password")
            || lower.contains("keychain")
            || ["pem", "key", "p12", "pfx", "cer", "keystore", "kdbx"].contains((lower as NSString).pathExtension)
    }

    /// Replaces anything shaped like a key or token.
    static func redact(_ text: String) -> String {
        let patterns = [
            #"-----BEGIN [A-Z ]+-----[\s\S]*?(-----END [A-Z ]+-----|$)"#,
            #"\b(sk|pk|rk|ghp|gho|ghs|xox[abp]|AKIA|AIza)[A-Za-z0-9_\-]{12,}"#,
            #"(?i)(api[_-]?key|secret|token|password|passwd|authorization)(["']?\s*[:=]\s*)["']?[^\s"',]{6,}"#,
            #"\b[A-Za-z0-9+/_\-]{40,}={0,2}"#,
        ]
        var out = text
        for (i, pattern) in patterns.enumerated() {
            let template = i == 2 ? "$1$2[redacted]" : "[redacted]"
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    /// A few readable samples: manifests and READMEs first, then the
    /// newest text files; plus what the largest files are, by their bytes.
    static func excerpts(root: String, files: [String], largest: [String]) -> [Inside.Excerpt] {
        var chosen: [String] = []
        let named = files.filter {
            let n = ($0 as NSString).lastPathComponent.lowercased()
            return n.hasPrefix("readme") || ["package.json", "cargo.toml", "pyproject.toml", "info.plist", "manifest.json"].contains(n)
        }
        chosen += named.sorted { $0.count < $1.count }.prefix(3)
        chosen += files.filter { textExtensions.contains(($0 as NSString).pathExtension.lowercased()) && !chosen.contains($0) }.prefix(4)
        chosen = chosen.filter { !looksSecret($0) }
        var out = chosen.prefix(6).compactMap { sample(root, $0) }
        for big in largest.prefix(3) where !chosen.contains(big) && !looksSecret(big) {
            if let s = sample(root, big) { out.append(s) }
        }
        return out
    }

    static func sample(_ root: String, _ rel: String) -> Inside.Excerpt? {
        guard let handle = FileHandle(forReadingAtPath: root + "/" + rel) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1200)) ?? Data()
        let magic: [(String, [UInt8])] = [
            ("sqlite", Array("SQLite format 3".utf8)), ("zip", [0x50, 0x4B, 0x03, 0x04]), ("pdf", Array("%PDF".utf8)),
            ("image", [0x89, 0x50, 0x4E, 0x47]), ("image", [0xFF, 0xD8, 0xFF]),
            ("executable", [0xCF, 0xFA, 0xED, 0xFE]), ("executable", [0xCA, 0xFE, 0xBA, 0xBE]),
        ]
        for (kind, bytes) in magic where head.starts(with: bytes) { return .init(path: rel, kind: kind, text: nil) }
        if head.prefix(512).contains(0) { return .init(path: rel, kind: "binary", text: nil) }
        let text = String(decoding: head, as: UTF8.self)
        return .init(path: rel, kind: "text", text: redact(text))
    }

    // MARK: reliance

    static func reliance(_ path: String, home: String) -> [Reliance] {
        var out: [Reliance] = []
        out += processes(using: path)
        out += mentions(of: path, home: home)
        out += symlinks(into: path, home: home)
        if let owner = appOwner(of: path, home: home) { out.append(owner) }
        return out
    }

    /// Running programs with files open inside the folder. `lsof` over all
    /// processes once is faster than `+D`, which walks the whole folder.
    static func processes(using path: String) -> [Reliance] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-w", "-F", "pcn"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var command = ""
        var pid = ""
        var hits: [String: Int] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            switch line.first {
            case "p": pid = String(line.dropFirst())
            case "c": command = String(line.dropFirst())
            case "n":
                let name = line.dropFirst()
                if name == path || name.hasPrefix(path + "/") { hits["\(command) (pid \(pid))", default: 0] += 1 }
            default: break
            }
        }
        return hits.sorted { $0.value > $1.value }.map {
            Reliance(kind: .process, detail: "\($0.key) has \($0.value) file\($0.value == 1 ? "" : "s") open", blocking: true)
        }
    }

    /// Launch jobs and shell or tool config that name the folder.
    static func mentions(of path: String, home: String) -> [Reliance] {
        let tilde = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        let needles = [path, tilde, path.replacingOccurrences(of: home, with: "$HOME")]
        func mentions(_ text: String) -> Bool { needles.contains { text.contains($0) } }
        var out: [Reliance] = []
        for dir in [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".plist") {
                guard let data = FileManager.default.contents(atPath: dir + "/" + name),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
                if mentions("\(plist)") { out.append(Reliance(kind: .launchd, detail: "launch job \(name) uses it", blocking: true)) }
            }
        }
        let configs = [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile", ".gitconfig",
                       ".ssh/config", ".claude/settings.json", ".codex/config.toml", ".npmrc", ".config/git/config"]
        for config in configs {
            guard let text = try? String(contentsOfFile: home + "/" + config, encoding: .utf8), mentions(text) else { continue }
            out.append(Reliance(kind: .config, detail: "~/\(config) mentions it", blocking: false))
        }
        return out
    }

    /// Links in the usual places that point into the folder.
    static func symlinks(into path: String, home: String) -> [Reliance] {
        var out: [Reliance] = []
        for dir in [home, home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/Applications"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                let link = dir + "/" + name
                guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { continue }
                let full = dest.hasPrefix("/") ? dest : dir + "/" + dest
                let resolved = URL(fileURLWithPath: full).standardizedFileURL.path
                if resolved == path || resolved.hasPrefix(path + "/") {
                    out.append(Reliance(kind: .symlink, detail: "\(link.replacingOccurrences(of: home, with: "~")) links into it", blocking: true))
                }
            }
        }
        return out
    }

    /// For a folder an app keeps in ~/Library: which app, and whether it is
    /// still installed. Data from an uninstalled app is left-behind bloat.
    static func appOwner(of path: String, home: String) -> Reliance? {
        let areas = ["Application Support", "Caches", "Containers", "Group Containers", "Preferences",
                     "Logs", "HTTPStorages", "WebKit", "Saved Application State"]
        let library = home + "/Library/"
        guard path.hasPrefix(library) else { return nil }
        let parts = path.dropFirst(library.count).split(separator: "/").map(String.init)
        guard parts.count >= 2, areas.contains(parts[0]) else { return nil }
        let owner = parts[1].replacingOccurrences(of: ".savedState", with: "").replacingOccurrences(of: ".plist", with: "")
        let apps = installedApps(home: home)
        let key = owner.lowercased()
        // Folders are named after the app's id, often with a suffix for a
        // helper (`<id>.ShipIt`), or after the app's name.
        if let app = apps.first(where: { app in
            !app.id.isEmpty && (key == app.id || key.hasPrefix(app.id + ".")) || key == app.name
        }) {
            return Reliance(kind: .app, detail: "belongs to \(app.display), which is installed", blocking: false)
        }
        // A reverse-DNS name nobody installed claims is a strong leftover sign.
        if owner.split(separator: ".").count >= 3 {
            return Reliance(kind: .app, detail: "no installed app is \(owner): likely left behind by one you removed", blocking: false)
        }
        return nil
    }

    struct App { let id: String; let name: String; let display: String }

    static func installedApps(home: String) -> [App] {
        var out: [App] = []
        for dir in ["/Applications", home + "/Applications", "/System/Applications", "/Applications/Utilities"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                let info = NSDictionary(contentsOfFile: dir + "/" + name + "/Contents/Info.plist")
                let id = (info?["CFBundleIdentifier"] as? String ?? "").lowercased()
                let display = String(name.dropLast(4))
                out.append(App(id: id, name: display.lowercased(), display: display))
            }
        }
        return out
    }
}
