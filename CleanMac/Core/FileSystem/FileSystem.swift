//
//  FileSystem.swift
//  CleanMac
//
//  A thin abstraction over FileManager so the scanner, cleaner, and leftover
//  finder can be tested against an in-memory mock. Only the operations the
//  app actually performs are modelled — this is not a general-purpose VFS.
//

import Foundation

/// Metadata about a single file system entry.
public struct FileMetadata: Equatable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var isRegularFile: Bool
    public var isSymbolicLink: Bool
    /// True for bundle-style directories macOS treats as single documents
    /// (`.app`, `.framework`, `.plugin`, ...). Such a directory is reported
    /// but never descended into, so a junk rule sees one item rather than
    /// thousands of files inside somebody's application bundle.
    public var isPackage: Bool
    public var allocatedSize: Int64        // bytes actually allocated on disk
    public var contentSize: Int64          // logical size for regular files
    public var modificationDate: Date?
    public var contentAccessDate: Date?
    public var creationDate: Date?

    public init(
        path: String,
        isDirectory: Bool,
        isRegularFile: Bool,
        isSymbolicLink: Bool,
        isPackage: Bool = false,
        allocatedSize: Int64,
        contentSize: Int64,
        modificationDate: Date? = nil,
        contentAccessDate: Date? = nil,
        creationDate: Date? = nil
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.isSymbolicLink = isSymbolicLink
        self.isPackage = isPackage
        self.allocatedSize = allocatedSize
        self.contentSize = contentSize
        self.modificationDate = modificationDate
        self.contentAccessDate = contentAccessDate
        self.creationDate = creationDate
    }
}

/// Errors raised by FileSystem operations.
public enum FileSystemError: Error, Equatable, Sendable {
    case notFound(String)
    case permissionDenied(String)
    case isDirectory(String)
    case notDirectory(String)
    case ioFailure(String, String)   // path, underlying description
}

/// Abstraction over the disk. `LiveFileSystem` talks to FileManager;
/// `MockFileSystem` (in tests) talks to an in-memory dictionary.
public protocol FileSystem: Sendable {
    func exists(_ path: String) -> Bool
    func metadata(at path: String) throws -> FileMetadata
    func contentsOfDirectory(_ path: String) throws -> [String]

    /// Recursively enumerate every descendant of `root` (excluding `root`
    /// itself). The closure receives each entry's absolute path and metadata.
    /// Return `.skipDescendants` from the closure to skip the entry's children
    /// (only meaningful for directories).
    ///
    /// Two pruning rules are applied unconditionally, before the closure's
    /// answer is even considered:
    ///
    /// - Packages (`.app`, `.framework`, ...) are opaque. They are reported
    ///   once, with `isPackage == true`, and never walked into.
    /// - Symbolic links are reported but never resolved, so the walk cannot
    ///   escape `root` through a link pointing elsewhere on the volume.
    ///   `followSymlinks` is therefore accepted for API symmetry and has no
    ///   effect on traversal.
    func enumerate(
        root: String,
        includeHidden: Bool,
        followSymlinks: Bool,
        _ visit: (String, FileMetadata) throws -> EnumerationAction
    ) throws

    /// Move a file or directory to the user's Trash. Returns the new URL of
    /// the item inside `~/.Trash`.
    func trash(_ path: String) throws -> String

    /// Move a file back from the Trash to its original location. Best-effort.
    func restore(fromTrash trashPath: String, to originalPath: String) throws

    /// Create a directory and any missing parents. Idempotent: succeeds when
    /// the directory already exists.
    func createDirectory(at path: String) throws

    /// Raw bytes at `path`, or nil when it is missing or unreadable. Modelled
    /// as optional rather than throwing because every caller treats "cannot
    /// read" exactly like "not there".
    func readData(at path: String) -> Data?

    /// Replace the contents of `path` with `data`, creating the file if needed.
    func writeData(_ data: Data, to path: String) throws

    /// Remove the file or directory at `path`, including its contents.
    func removeItem(at path: String) throws

    /// Volume information for the given path.
    func volumeInfo(forPath path: String) throws -> VolumeInfo

    /// All mounted volume paths (e.g. "/", "/Volumes/External").
    func mountedVolumes() -> [String]

    /// Absolute path to the current user's home directory.
    var homeDirectory: String { get }

    /// Absolute path to the current user's Trash directory (`~/.Trash`).
    var userTrashDirectory: String { get }
}

public enum EnumerationAction: Sendable {
    case continueEnumeration
    case skipDescendants
}

public struct VolumeInfo: Equatable, Sendable {
    public var mountPoint: String
    public var name: String
    public var totalCapacity: Int64
    public var availableCapacity: Int64
    public var isRemovable: Bool
    public var isInternal: Bool

    public init(
        mountPoint: String,
        name: String,
        totalCapacity: Int64,
        availableCapacity: Int64,
        isRemovable: Bool,
        isInternal: Bool
    ) {
        self.mountPoint = mountPoint
        self.name = name
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.isRemovable = isRemovable
        self.isInternal = isInternal
    }
}

// MARK: - Live implementation

/// `FileManager` is documented as thread-safe but is not annotated `Sendable`,
/// so the conformance is asserted explicitly to keep the strict-concurrency
/// build clean.
public struct LiveFileSystem: FileSystem, @unchecked Sendable {

    private let fm: FileManager

    public init(fileManager: FileManager = .default) {
        self.fm = fileManager
    }

    public var homeDirectory: String {
        NSHomeDirectory()
    }

    public var userTrashDirectory: String {
        // FileManager.url(for: .trashDirectory, ...) can fail in edge cases;
        // fall back to the conventional path.
        if let url = try? fm.url(for: .trashDirectory, in: .userDomainMask,
                                 appropriateFor: URL(fileURLWithPath: NSHomeDirectory()),
                                 create: false) {
            return url.path
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
    }

    public func exists(_ path: String) -> Bool {
        fm.fileExists(atPath: path)
    }

    public func metadata(at path: String) throws -> FileMetadata {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .creationDateKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            // Fall back to attributesOfItem — resourceValues can throw for
            // items in some protected locations even when the file exists.
            let attrs = try fm.attributesOfItem(atPath: path)
            let type = attrs[.type] as? FileAttributeType
            return FileMetadata(
                path: path,
                isDirectory: type == .typeDirectory,
                isRegularFile: type == .typeRegular,
                isSymbolicLink: type == .typeSymbolicLink,
                allocatedSize: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                contentSize: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                modificationDate: attrs[.modificationDate] as? Date,
                contentAccessDate: nil,
                creationDate: attrs[.creationDate] as? Date
            )
        }
        return FileMetadata(
            path: path,
            isDirectory: values.isDirectory ?? false,
            isRegularFile: values.isRegularFile ?? false,
            isSymbolicLink: values.isSymbolicLink ?? false,
            isPackage: values.isPackage ?? false,
            allocatedSize: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
            contentSize: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate,
            contentAccessDate: values.contentAccessDate,
            creationDate: values.creationDate
        )
    }

    public func contentsOfDirectory(_ path: String) throws -> [String] {
        do {
            return try fm.contentsOfDirectory(atPath: path)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileReadNoSuchFileError: throw FileSystemError.notFound(path)
                case NSFileReadNoPermissionError: throw FileSystemError.permissionDenied(path)
                default: break
                }
            }
            throw FileSystemError.ioFailure(path, error.localizedDescription)
        }
    }

    public func enumerate(
        root: String,
        includeHidden: Bool,
        followSymlinks: Bool,
        _ visit: (String, FileMetadata) throws -> EnumerationAction
    ) throws {
        let url = URL(fileURLWithPath: root)
        // `.skipsPackageDescendants` only bites when FileManager performs the
        // recursion itself. This method drives its own stack one level at a
        // time so the visitor's `.skipDescendants` can be honoured — which
        // would otherwise walk straight into every `.app` bundle. Packages are
        // pruned explicitly below, using `.isPackageKey`.
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { opts.insert(.skipsHiddenFiles) }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .creationDateKey,
            .isHiddenKey
        ]

        // One level per enumerator, directories to descend into collected on a
        // stack. `followSymlinks` is deliberately not acted on: resolving a
        // link could carry the walk outside `root` and surface paths the
        // denylist never agreed to consider.
        var stack: [URL] = [url]
        while let dir = stack.popLast() {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: keys,
                options: opts.union([.skipsSubdirectoryDescendants]),
                errorHandler: { _, _ in true }     // silently skip unreadable entries
            ) else { continue }

            for case let entry as URL in enumerator {
                if !includeHidden,
                   let hidden = try? entry.resourceValues(forKeys: [.isHiddenKey]).isHidden,
                   hidden {
                    continue
                }
                let values = try? entry.resourceValues(forKeys: Set(keys))
                let meta = FileMetadata(
                    path: entry.path,
                    isDirectory: values?.isDirectory ?? false,
                    isRegularFile: values?.isRegularFile ?? false,
                    isSymbolicLink: values?.isSymbolicLink ?? false,
                    isPackage: values?.isPackage ?? false,
                    allocatedSize: Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0),
                    contentSize: Int64(values?.fileSize ?? 0),
                    modificationDate: values?.contentModificationDate,
                    contentAccessDate: values?.contentAccessDate,
                    creationDate: values?.creationDate
                )
                let action = try visit(entry.path, meta)
                // Packages are opaque: reported once, never walked into.
                if meta.isDirectory, !meta.isPackage, action == .continueEnumeration {
                    stack.append(entry)
                }
            }
        }
    }

    public func trash(_ path: String) throws -> String {
        var resulting: NSURL?
        do {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
                throw FileSystemError.notFound(path)
            }
            if error.domain == NSCocoaErrorDomain,
               [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) {
                throw FileSystemError.permissionDenied(path)
            }
            throw FileSystemError.ioFailure(path, error.localizedDescription)
        }
        return resulting?.path ?? path
    }

    public func restore(fromTrash trashPath: String, to originalPath: String) throws {
        let parent = (originalPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        do {
            try fm.moveItem(atPath: trashPath, toPath: originalPath)
        } catch let error as NSError {
            throw FileSystemError.ioFailure(trashPath, error.localizedDescription)
        }
    }

    public func createDirectory(at path: String) throws {
        do {
            try fm.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) {
                throw FileSystemError.permissionDenied(path)
            }
            throw FileSystemError.ioFailure(path, error.localizedDescription)
        }
    }

    public func readData(at path: String) -> Data? {
        fm.contents(atPath: path)
    }

    public func writeData(_ data: Data, to path: String) throws {
        do {
            // Atomic so a crash mid-write cannot leave a half-written manifest
            // that decodes to nothing and silently empties the history.
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) {
                throw FileSystemError.permissionDenied(path)
            }
            throw FileSystemError.ioFailure(path, error.localizedDescription)
        }
    }

    public func removeItem(at path: String) throws {
        do {
            try fm.removeItem(atPath: path)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
                throw FileSystemError.notFound(path)
            }
            throw FileSystemError.ioFailure(path, error.localizedDescription)
        }
    }

    public func volumeInfo(forPath path: String) throws -> VolumeInfo {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeNameKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            throw FileSystemError.notFound(path)
        }
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        return VolumeInfo(
            mountPoint: mountPoint(for: path),
            name: values.volumeName ?? "Unknown",
            totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
            availableCapacity: Int64(available),
            isRemovable: values.volumeIsRemovable ?? false,
            isInternal: values.volumeIsInternal ?? true
        )
    }

    /// Deepest mounted volume that contains `path`. `URLResourceValues` does
    /// not expose the volume URL portably, so resolve it by prefix match and
    /// fall back to the boot volume.
    private func mountPoint(for path: String) -> String {
        let std = (path as NSString).standardizingPath
        return mountedVolumes()
            .filter { volume in
                volume == "/" || std == volume || std.hasPrefix(volume + "/")
            }
            .max { $0.count < $1.count } ?? "/"
    }

    public func mountedVolumes() -> [String] {
        let urls = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.map { $0.path }
    }
}
