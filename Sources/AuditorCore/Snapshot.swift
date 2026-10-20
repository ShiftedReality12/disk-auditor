import Foundation

/// The last `worth` listing: its numbered findings, so `dsa trash 3` means
/// what was on screen, and directory sizes, so the next scan can say what grew.
public struct Snapshot: Codable, Sendable {
    public let when: Date
    public let root: String
    public let findings: [Finding]
    public let sizes: [String: UInt64]

    public init(when: Date, root: String, findings: [Finding], sizes: [String: UInt64]) {
        self.when = when
        self.root = root
        self.findings = findings
        self.sizes = sizes
    }

    public static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/dsa/last.json")
    }

    public static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.file, options: .atomic)
    }

    /// Directory sizes down to `depth` levels, plus every finding's own path.
    public static func sizes(of root: Node, findings: [Finding], depth: Int = 3) -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        func walk(_ node: Node, _ level: Int) {
            out[node.path] = node.bytes
            guard level < depth else { return }
            for child in node.children where child.isDir { walk(child, level + 1) }
        }
        walk(root, 0)
        for finding in findings { out[finding.path] = finding.bytes }
        return out
    }

    /// The directories that grew most since `self`, most specific first: a
    /// parent is left out when one child explains most of its growth.
    public func growth(to now: [String: UInt64], atLeast: Int64 = 512 << 20, limit: Int = 5) -> [(String, Int64)] {
        let grown = now.compactMap { path, bytes -> (String, Int64)? in
            guard let before = sizes[path] else { return nil }
            let delta = Int64(bytes) - Int64(before)
            return delta >= atLeast ? (path, delta) : nil
        }
        let deepestFirst = grown.sorted {
            let (a, b) = ($0.0.split(separator: "/").count, $1.0.split(separator: "/").count)
            return a != b ? a > b : $0.1 > $1.1
        }
        var chosen: [(String, Int64)] = []
        for (path, delta) in deepestFirst {
            let explained = chosen.contains { $0.0.hasPrefix(path + "/") && Double($0.1) >= 0.8 * Double(delta) }
            if !explained { chosen.append((path, delta)) }
        }
        return Array(chosen.sorted { $0.1 > $1.1 }.prefix(limit))
    }
}
