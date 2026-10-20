import Darwin
import Foundation

/// A directory, or a file big enough to be named on its own.
///
/// Small files are folded into their directory's own totals instead of
/// becoming nodes: a home directory holds millions of them, and nothing
/// the tool reports needs them one by one.
public final class Node: @unchecked Sendable {
    public let name: String
    public let isDir: Bool
    public private(set) weak var parent: Node?
    public internal(set) var children: [Node] = []
    /// Allocated bytes: what deleting it gives back. A total once aggregated.
    public internal(set) var bytes: UInt64 = 0
    public internal(set) var files: UInt64 = 0
    /// The newest modification time anywhere beneath, in Unix seconds.
    public internal(set) var newest: Int64 = 0
    /// It holds a `.git` directory: a checkout.
    public internal(set) var isRepo = false
    /// Its `.git` is a file: a linked worktree.
    public internal(set) var isWorktree = false
    public internal(set) var unreadable = false
    /// What it is, for colour. Set for every node when the scan finishes.
    public internal(set) var category = Category.other

    var ownBytes: UInt64 = 0
    /// Bytes in small files held directly, which have no node of their own.
    public var looseBytes: UInt64 { ownBytes }
    var ownFiles: UInt64 = 0
    var ownNewest: Int64 = 0

    init(name: String, isDir: Bool, parent: Node?) {
        self.name = name
        self.isDir = isDir
        self.parent = parent
    }

    /// The path a person would type. `--disk` scans the Data volume but
    /// reports the home folder's usual path, the same directory through a firmlink.
    public var path: String {
        guard let parent else { return name }
        let base = parent.path
        return base == "/" ? "/" + name : base + "/" + name
    }

    public func child(named wanted: String) -> Node? {
        children.first { $0.name == wanted }
    }
}

public struct ScanResult: @unchecked Sendable {
    public let root: Node
    public let unreadable: Int
    public let seconds: Double
}

public enum Scanner {
    /// Files at least this big keep their own node, so a lone 10 GB disk
    /// image can be named; smaller ones are only counted.
    public static let keepFileBytes: UInt64 = 64 << 20

    /// On macOS, `/` is a read-only system volume and everything that can be
    /// reclaimed lives on the Data volume, which `/Users`, `/Applications`
    /// and `/opt` are firmlinks into.
    public static let dataVolume = "/System/Volumes/Data"

    /// Measures `path` on its own volume, in parallel, and returns the tree
    /// with totals, largest first.
    /// `progress`, when given, counts entries read, for a live display.
    public static func scan(_ path: String, progress: Locked<Int>? = nil) -> ScanResult {
        let started = Date()
        // Resolved, so paths compare equal to the home folder the rules
        // are keyed on even when the scan was started through a symlink.
        let logical = Guard.real(normalize(path))
        let physical = logical == "/" ? dataVolume : logical
        let root = Node(name: logical, isDir: true, parent: nil)
        var st = stat()
        guard lstat(physical, &st) == 0 else {
            root.unreadable = true
            return ScanResult(root: root, unreadable: 1, seconds: 0)
        }
        root.ownNewest = Int64(st.st_mtimespec.tv_sec)
        let walk = Walk(device: st.st_dev, root: root, path: physical, progress: progress)
        // Directory reads block on I/O, so more workers than cores keeps the
        // disk's queue full.
        // `concurrentPerform` would cap this at the core count.
        let workers = ProcessInfo.processInfo.activeProcessorCount * 2
        let group = DispatchGroup()
        for _ in 0..<workers {
            group.enter()
            let thread = Thread { walk.work(); group.leave() }
            // Someone is waiting on this; without it, threads started from
            // the app's background task ran about a third slower.
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
        aggregate(root)
        Classify.classify(root)
        return ScanResult(
            root: root,
            unreadable: walk.unreadable,
            seconds: Date().timeIntervalSince(started)
        )
    }

    public static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let text = url.path
        return text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    /// Totals are derived here, never tracked during the walk: the walk
    /// only records what each directory holds directly.
    static func aggregate(_ node: Node) {
        var bytes = node.ownBytes
        var files = node.ownFiles
        var newest = node.ownNewest
        for child in node.children {
            if child.isDir { aggregate(child) }
            bytes += child.bytes
            files += child.files
            newest = max(newest, child.newest)
        }
        node.bytes = bytes
        node.files = files
        node.newest = newest
        node.children.sort { $0.bytes > $1.bytes }
    }
}

/// `SF_DATALESS`: an iCloud or File Provider item evicted to the server.
/// Opening it would download it, so the walk never does.
private let dataless: UInt32 = 0x4000_0000

private struct Inode: Hashable {
    let device: dev_t
    let inode: ino_t
}

/// The shared state of one scan: a stack of directories still to read.
private final class Walk: @unchecked Sendable {
    let device: dev_t
    private let lock = NSCondition()
    private var stack: [(Node, String)]
    private var busy = 0
    private var seen = Set<Inode>()
    private(set) var unreadable = 0
    let progress: Locked<Int>?

    init(device: dev_t, root: Node, path: String, progress: Locked<Int>?) {
        self.device = device
        self.progress = progress
        stack = [(root, path)]
    }

    func work() {
        while true {
            lock.lock()
            while stack.isEmpty && busy > 0 { lock.wait() }
            guard let (node, path) = stack.popLast().map({ ($0.0, $0.1) }) else {
                // Nothing queued and nobody reading: nothing more can arrive.
                lock.broadcast()
                lock.unlock()
                return
            }
            busy += 1
            lock.unlock()
            let found = read(node, path)
            lock.lock()
            stack.append(contentsOf: found)
            busy -= 1
            lock.broadcast()
            lock.unlock()
        }
    }

    /// Records what `node` holds directly, and returns its subdirectories.
    ///
    /// `getattrlistbulk` returns name, type, size, date and inode for a
    /// whole batch of entries per system call, where `readdir` + `fstatat`
    /// costs one call per entry. The kernel emulates it on file systems
    /// without native support, so it is the only path.
    private func read(_ node: Node, _ path: String) -> [(Node, String)] {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            node.unreadable = true
            lock.lock()
            unreadable += 1
            lock.unlock()
            return []
        }
        defer { Darwin.close(fd) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        let size = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var subdirs: [(Node, String)] = []
        var count = 0
        while true {
            let n = getattrlistbulk(fd, &request, buffer, size, 0)
            if n <= 0 { break }
            var entry = buffer
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                visit(entry, node, path, &subdirs)
                entry += length
            }
            count += Int(n)
        }
        progress?.with { $0 += count }
        return subdirs
    }

    /// One entry of a `getattrlistbulk` batch. Attributes arrive in bit
    /// order, 4-byte aligned, and only those the returned set names.
    private func visit(_ entry: UnsafeMutableRawPointer, _ node: Node, _ path: String, _ subdirs: inout [(Node, String)]) {
        var at = entry + 4
        let returned = at.loadUnaligned(as: attribute_set_t.self)
        at += MemoryLayout<attribute_set_t>.size
        let has = { (bit: Int32) in returned.commonattr & attrgroup_t(bit) != 0 }
        var name = ""
        if has(ATTR_CMN_NAME) {
            let ref = at.loadUnaligned(as: attrreference_t.self)
            name = String(cString: (at + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
            at += MemoryLayout<attrreference_t>.size
        }
        var device: dev_t = 0
        if has(ATTR_CMN_DEVID) { device = at.loadUnaligned(as: dev_t.self); at += MemoryLayout<dev_t>.size }
        var type: UInt32 = 0
        if has(ATTR_CMN_OBJTYPE) { type = at.loadUnaligned(as: UInt32.self); at += 4 }
        var mtime: Int64 = 0
        if has(ATTR_CMN_MODTIME) { mtime = Int64(at.loadUnaligned(as: timespec.self).tv_sec); at += MemoryLayout<timespec>.size }
        var flags: UInt32 = 0
        if has(ATTR_CMN_FLAGS) { flags = at.loadUnaligned(as: UInt32.self); at += 4 }
        var inode: UInt64 = 0
        if has(ATTR_CMN_FILEID) { inode = at.loadUnaligned(as: UInt64.self); at += 8 }
        var links: UInt32 = 1
        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { links = at.loadUnaligned(as: UInt32.self); at += 4 }
        var allocated: UInt64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 { allocated = UInt64(max(0, at.loadUnaligned(as: off_t.self))) }

        if name.isEmpty || name == "." || name == ".." { return }
        if name == ".git" {
            if type == UInt32(VDIR.rawValue) { node.isRepo = true }
            if type == UInt32(VREG.rawValue) { node.isRepo = true; node.isWorktree = true }
        }
        if type == UInt32(VDIR.rawValue) {
            // Another volume mounted here is not this disk's space.
            if device != self.device { return }
            let child = Node(name: name, isDir: true, parent: node)
            child.ownNewest = mtime
            node.children.append(child)
            if flags & dataless == 0 { subdirs.append((child, path == "/" ? "/" + name : path + "/" + name)) }
            return
        }
        var bytes = allocated
        // Two names for one inode cost one file's space.
        if type == UInt32(VREG.rawValue) && links > 1 && !firstSight(device, inode) { bytes = 0 }
        if bytes >= Scanner.keepFileBytes {
            let file = Node(name: name, isDir: false, parent: node)
            file.bytes = bytes
            file.files = 1
            file.newest = mtime
            node.children.append(file)
        } else {
            node.ownBytes += bytes
            node.ownFiles += 1
            node.ownNewest = max(node.ownNewest, mtime)
        }
    }

    private func firstSight(_ device: dev_t, _ inode: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(Inode(device: device, inode: ino_t(inode))).inserted
    }
}
