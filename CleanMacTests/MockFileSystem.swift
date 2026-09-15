//
//  MockFileSystem.swift
//  CleanMacTests
//
//  In-memory `FileSystem` double. Every node lives in a dictionary keyed by
//  standardised absolute path, so tests can build a fake disk, assert on
//  trash/restore calls, and inject failures — all without touching the real
//  file system.
//

import Foundation
@testable import CleanMac

final class MockFileSystem: FileSystem, @unchecked Sendable {

    struct Node {
        var isDirectory: Bool
        var isSymbolicLink: Bool
        /// Bundle-style directory (`.app`, `.framework`, ...). Opaque to
        /// `enumerate`, exactly as `LiveFileSystem` treats real packages.
        /// Defaults to false so the implicit-parent fixtures stay ordinary.
        var isPackage: Bool = false
        var size: Int64
        var modificationDate: Date?
        var contentAccessDate: Date?
        var creationDate: Date?
        /// File bytes, for the `readData`/`writeData` pair. Declared last with
        /// a default so every existing memberwise `Node(...)` literal — several
        /// of which omit `isPackage` too — keeps compiling unchanged.
        var contents: Data? = nil
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]

    /// Recorded calls, useful for assertions.
    private(set) var trashCalls: [String] = []
    private(set) var restoreCalls: [(from: String, to: String)] = []

    /// How many times each traversal entry point was invoked. These exist so a
    /// test can prove the engine walked a tree *once*: `ScannerEngine` used to
    /// run the whole scan twice per call (a discarded streaming pass plus the
    /// real one), which no output-based assertion could detect because the two
    /// passes produced identical results.
    ///
    /// Reported separately rather than summed because `enumerate` recurses via
    /// `contentsOfDirectory`, so its internal calls land in that counter too.
    /// A test that wants an exact `contentsOfDirectory` figure should use
    /// non-recursive globs and assert `enumerateCallCount == 0` first.
    private(set) var contentsOfDirectoryCallCount = 0
    private(set) var enumerateCallCount = 0

    func resetTraversalCounts() {
        lock.lock()
        contentsOfDirectoryCallCount = 0
        enumerateCallCount = 0
        lock.unlock()
    }

    /// Paths that should fail when trashed, and the error to throw.
    var trashFailures: [String: FileSystemError] = [:]
    var restoreFailures: [String: FileSystemError] = [:]

    let homeDirectory: String
    let userTrashDirectory: String
    var cannedVolumeInfo: VolumeInfo

    init(home: String = "/mockhome") {
        self.homeDirectory = home
        self.userTrashDirectory = (home as NSString).appendingPathComponent(".Trash")
        self.cannedVolumeInfo = VolumeInfo(
            mountPoint: "/",
            name: "Macintosh HD",
            totalCapacity: 1_000_000_000_000,
            availableCapacity: 250_000_000_000,
            isRemovable: false,
            isInternal: true
        )
        try? createDirectory(at: home)
        try? createDirectory(at: userTrashDirectory)
    }

    // MARK: - Fixture builders

    @discardableResult
    func addFile(
        _ path: String,
        size: Int64 = 1024,
        modified: Date? = nil,
        accessed: Date? = nil,
        created: Date? = nil
    ) -> String {
        let std = normalize(path)
        ensureParents(of: std)
        lock.lock(); defer { lock.unlock() }
        nodes[std] = Node(
            isDirectory: false,
            isSymbolicLink: false,
            isPackage: false,
            size: size,
            modificationDate: modified,
            contentAccessDate: accessed,
            creationDate: created
        )
        return std
    }

    @discardableResult
    func addDirectory(_ path: String, modified: Date? = nil, isPackage: Bool = false) -> String {
        let std = normalize(path)
        ensureParents(of: std)
        lock.lock(); defer { lock.unlock() }
        nodes[std] = Node(
            isDirectory: true,
            isSymbolicLink: false,
            isPackage: isPackage,
            size: 0,
            modificationDate: modified,
            contentAccessDate: nil,
            creationDate: nil
        )
        return std
    }

    /// A bundle-style directory: reported by `enumerate` but never descended
    /// into, matching how macOS treats `.app`/`.framework` on disk.
    @discardableResult
    func addPackage(_ path: String, modified: Date? = nil) -> String {
        addDirectory(path, modified: modified, isPackage: true)
    }

    @discardableResult
    func addSymlink(_ path: String, size: Int64 = 64) -> String {
        let std = normalize(path)
        ensureParents(of: std)
        lock.lock(); defer { lock.unlock() }
        nodes[std] = Node(
            isDirectory: false,
            isSymbolicLink: true,
            isPackage: false,
            size: size,
            modificationDate: nil,
            contentAccessDate: nil,
            creationDate: nil
        )
        return std
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        nodes.removeAll()
        trashCalls.removeAll()
        restoreCalls.removeAll()
    }

    /// Delete a node and its descendants without recording a trash call.
    /// Used to simulate an externally emptied Trash or a vanished parent.
    func removeNode(_ path: String) {
        let std = normalize(path)
        lock.lock(); defer { lock.unlock() }
        nodes.removeValue(forKey: std)
        removeDescendants(of: std)
    }

    func snapshotPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return nodes.keys.sorted()
    }

    // MARK: - FileSystem

    func exists(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return nodes[normalize(path)] != nil
    }

    func metadata(at path: String) throws -> FileMetadata {
        let std = normalize(path)
        lock.lock()
        guard let node = nodes[std] else {
            lock.unlock()
            throw FileSystemError.notFound(std)
        }
        lock.unlock()
        return FileMetadata(
            path: std,
            isDirectory: node.isDirectory,
            isRegularFile: !node.isDirectory && !node.isSymbolicLink,
            isSymbolicLink: node.isSymbolicLink,
            isPackage: node.isPackage,
            allocatedSize: node.size,
            contentSize: node.size,
            modificationDate: node.modificationDate,
            contentAccessDate: node.contentAccessDate,
            creationDate: node.creationDate
        )
    }

    func contentsOfDirectory(_ path: String) throws -> [String] {
        let std = normalize(path)
        lock.lock()
        contentsOfDirectoryCallCount += 1
        guard let node = nodes[std], node.isDirectory else {
            lock.unlock()
            throw FileSystemError.notDirectory(std)
        }
        let prefix = std == "/" ? "/" : std + "/"
        var names: [String] = []
        for key in nodes.keys {
            guard key.hasPrefix(prefix), key != std else { continue }
            let remainder = String(key.dropFirst(prefix.count))
            // Only direct children.
            if !remainder.isEmpty, !remainder.contains("/") {
                names.append(remainder)
            }
        }
        lock.unlock()
        return names.sorted()
    }

    func enumerate(
        root: String,
        includeHidden: Bool,
        followSymlinks: Bool,
        _ visit: (String, FileMetadata) throws -> EnumerationAction
    ) throws {
        let std = normalize(root)
        lock.lock()
        enumerateCallCount += 1
        lock.unlock()
        guard exists(std) else { return }

        // Breadth-first over a snapshot so mutations during enumeration (e.g.
        // trashing) can't invalidate the walk.
        var queue: [String] = [std]
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            let children = (try? contentsOfDirectory(dir)) ?? []
            for child in children {
                if !includeHidden, child.hasPrefix(".") { continue }
                let childPath = dir == "/" ? "/\(child)" : "\(dir)/\(child)"
                guard let meta = try? metadata(at: childPath) else { continue }

                let action = try visit(childPath, meta)
                // Packages are opaque, mirroring `LiveFileSystem`: reported
                // once, never queued for descent.
                if meta.isDirectory, !meta.isPackage, action == .continueEnumeration {
                    queue.append(childPath)
                }
            }
        }
    }

    func trash(_ path: String) throws -> String {
        let std = normalize(path)
        lock.lock()
        trashCalls.append(std)
        guard nodes[std] != nil else {
            lock.unlock()
            throw FileSystemError.notFound(std)
        }
        if let failure = trashFailures[std] {
            lock.unlock()
            throw failure
        }
        let name = (std as NSString).lastPathComponent
        let destination = uniqueTrashPath(for: name)
        relocate(subtreeRoot: std, to: destination)
        lock.unlock()
        return destination
    }

    func restore(fromTrash trashPath: String, to originalPath: String) throws {
        let from = normalize(trashPath)
        let to = normalize(originalPath)
        lock.lock()
        restoreCalls.append((from, to))
        guard nodes[from] != nil else {
            lock.unlock()
            throw FileSystemError.notFound(from)
        }
        if let failure = restoreFailures[from] {
            lock.unlock()
            throw failure
        }
        ensureParents(of: to)
        relocate(subtreeRoot: from, to: to)
        lock.unlock()
    }

    func volumeInfo(forPath path: String) throws -> VolumeInfo {
        cannedVolumeInfo
    }

    func mountedVolumes() -> [String] { ["/"] }

    // MARK: - Helpers (call with lock held where noted)

    /// Lossless path normalisation: expand `~`, resolve `.`/`..` lexically,
    /// collapse the `/private` alias, and drop any trailing slash.
    ///
    /// Deliberately does NOT use `NSString.standardizingPath`. That API
    /// silently truncates its result at PATH_MAX (1024 bytes), so a test double
    /// built on it stores two distinct deep nodes under one dictionary key and
    /// quietly loses data — which makes `testDeepNestingDoesNotBlowTheStack`
    /// (and anything else that builds a long path) fail for reasons that have
    /// nothing to do with the code under test. It also resolves symlinks only
    /// for paths that happen to exist on the *real* disk, so keys would depend
    /// on the host machine.
    private func normalize(_ path: String) -> String {
        var p = path
        if p == "~" || p.hasPrefix("~/") {
            p = homeDirectory + String(p.dropFirst(1))
        }

        let isAbsolute = p.hasPrefix("/")
        var components: [String] = []
        for component in p.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                // Lexical pop, matching what standardizingPath does for paths
                // it cannot resolve on disk.
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }

        var joined = (isAbsolute ? "/" : "") + components.joined(separator: "/")
        if isAbsolute, joined.isEmpty { joined = "/" }
        if joined.hasPrefix("/private/") {
            joined = String(joined.dropFirst("/private".count))
        }
        return joined
    }

    private func ensureParents(of std: String) {
        var components = std.split(separator: "/").dropLast()
        var current = ""
        while !components.isEmpty {
            current += "/" + components.removeFirst()
            if nodes[current] == nil {
                nodes[current] = Node(
                    isDirectory: true,
                    isSymbolicLink: false,
                    size: 0,
                    modificationDate: nil,
                    contentAccessDate: nil,
                    creationDate: nil
                )
            }
        }
    }

    private func removeDescendants(of std: String) {
        let prefix = std + "/"
        for key in Array(nodes.keys) where key.hasPrefix(prefix) {
            nodes.removeValue(forKey: key)
        }
    }

    /// Move a node *and everything below it* to a new root, mirroring how a
    /// real trash/restore relocates whole subtrees. Caller must hold the lock.
    private func relocate(subtreeRoot source: String, to destination: String) {
        guard let node = nodes[source] else { return }
        let keys = Array(nodes.keys)
        nodes.removeValue(forKey: source)
        nodes[destination] = node
        let prefix = source + "/"
        for key in keys where key.hasPrefix(prefix) {
            guard let child = nodes.removeValue(forKey: key) else { continue }
            nodes[destination + String(key.dropFirst(source.count))] = child
        }
    }

    private func uniqueTrashPath(for name: String) -> String {
        var candidate = (userTrashDirectory as NSString).appendingPathComponent(name)
        var counter = 2
        while nodes[candidate] != nil {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            let suffix = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = (userTrashDirectory as NSString).appendingPathComponent(suffix)
            counter += 1
        }
        return candidate
    }

    public func createDirectory(at path: String) throws {
        let std = normalize(path)
        lock.lock(); defer { lock.unlock() }
        ensureParents(of: std)
        // Idempotent, matching `LiveFileSystem`: recreating an existing
        // directory must not wipe it or fail.
        if var existing = nodes[std] {
            existing.isDirectory = true
            nodes[std] = existing
            return
        }
        nodes[std] = Node(
            isDirectory: true,
            isSymbolicLink: false,
            size: 0,
            modificationDate: Date(),
            contentAccessDate: nil,
            creationDate: nil
        )
    }

    public func readData(at path: String) -> Data? {
        let std = normalize(path)
        lock.lock(); defer { lock.unlock() }
        guard let node = nodes[std], !node.isDirectory else { return nil }
        return node.contents
    }

    public func writeData(_ data: Data, to path: String) throws {
        let std = normalize(path)
        // Same ordering as `addFile`: `ensureParents` mutates `nodes` without
        // taking the lock, so it runs before we acquire one.
        ensureParents(of: std)
        lock.lock(); defer { lock.unlock() }
        var node = nodes[std] ?? Node(
            isDirectory: false,
            isSymbolicLink: false,
            size: 0,
            modificationDate: nil,
            contentAccessDate: nil,
            creationDate: nil
        )
        node.isDirectory = false
        node.contents = data
        node.size = Int64(data.count)
        node.modificationDate = Date()
        nodes[std] = node
    }

    public func removeItem(at path: String) throws {
        let std = normalize(path)
        lock.lock(); defer { lock.unlock() }
        guard nodes[std] != nil else { throw FileSystemError.notFound(std) }
        nodes.removeValue(forKey: std)
        removeDescendants(of: std)
    }
}

// MARK: - Convenience

extension MockFileSystem {
    /// Build a ScanItem pointing at a real mock node.
    func makeItem(
        at path: String,
        ruleID: String = "test-rule",
        ruleName: String = "Test Rule",
        category: RuleCategory = .caches,
        safety: SafetyLevel = .safe,
        isReadOnly: Bool = false,
        sizeOverride: Int64? = nil
    ) -> ScanItem {
        let std = normalize(path)
        let meta = try? metadata(at: std)
        return ScanItem(
            path: std,
            ruleID: ruleID,
            ruleName: ruleName,
            category: category,
            safety: safety,
            size: sizeOverride ?? meta?.allocatedSize ?? 0,
            isDirectory: meta?.isDirectory ?? false,
            modificationDate: meta?.modificationDate,
            contentAccessDate: meta?.contentAccessDate,
            isReadOnly: isReadOnly
        )
    }
}
