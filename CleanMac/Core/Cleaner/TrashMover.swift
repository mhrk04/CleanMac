//
//  TrashMover.swift
//  CleanMac
//
//  Thin wrapper over FileSystem.trash that adds:
//    - Retry on transient failures
//    - Path normalisation before moving
//    - Structured error reporting for the manifest
//

import Foundation

public struct TrashMover: Sendable {

    public enum TrashError: Error, Equatable {
        case missing(String)
        case permissionDenied(String)
        case readOnly(String)
        case underlying(String, String)      // path, description

        /// Human-readable explanation, used for `CleanManifest.Failure.reason`.
        /// Shared by `CleanerService` and `HistoryStore.restore` so the same
        /// failure reads identically whichever path performed the move.
        ///
        /// The path is substituted, never interpolated into the key, so the
        /// `.underlying` description coming from Foundation stays untouched.
        public var message: String {
            switch self {
            case .missing(let p): return L10n.string("File not found: %@", p)
            case .permissionDenied(let p): return L10n.string("Permission denied: %@", p)
            case .readOnly(let p): return L10n.string("Read-only volume: %@", p)
            case .underlying(_, let m): return m
            }
        }
    }

    private let fs: FileSystem
    private let maxRetries: Int

    public init(fileSystem: FileSystem, maxRetries: Int = 1) {
        self.fs = fileSystem
        self.maxRetries = max(0, maxRetries)
    }

    /// Move `path` to the Trash. Returns the new location inside the Trash.
    /// Retries once on transient IO failure (files being written by another
    /// process can intermittently refuse a move).
    public func trash(path: String) throws -> String {
        let standard = (path as NSString).standardizingPath

        guard fs.exists(standard) else {
            throw TrashError.missing(standard)
        }

        var attempt = 0
        var lastError: Error? = nil
        while attempt <= maxRetries {
            do {
                return try fs.trash(standard)
            } catch let error as FileSystemError {
                switch error {
                case .notFound:
                    throw TrashError.missing(standard)
                case .permissionDenied:
                    throw TrashError.permissionDenied(standard)
                case .ioFailure(_, let msg):
                    lastError = error
                    if msg.contains("read-only") {
                        throw TrashError.readOnly(standard)
                    }
                default:
                    lastError = error
                }
            } catch {
                lastError = error
            }
            attempt += 1
            // Small backoff before retrying.
            Thread.sleep(forTimeInterval: 0.1 * Double(attempt))
        }

        if let last = lastError {
            throw TrashError.underlying(standard, last.localizedDescription)
        }
        throw TrashError.underlying(standard, "Unknown failure")
    }

    /// Move an item back from the Trash. Best-effort; if the target directory
    /// no longer exists we recreate it, and if the trash item is gone we
    /// throw `.missing` so the caller can flag the manifest entry.
    public func restore(trashPath: String, to originalPath: String) throws {
        guard fs.exists(trashPath) else {
            throw TrashError.missing(trashPath)
        }
        let parent = (originalPath as NSString).deletingLastPathComponent
        if !parent.isEmpty, !fs.exists(parent) {
            // Through the protocol, not `FileManager`: a restore exercised under
            // `MockFileSystem` must not create directories on the real disk.
            try? fs.createDirectory(at: parent)
        }
        // If something else has taken the original path since we trashed it,
        // append a numeric suffix rather than overwrite.
        var target = originalPath
        var counter = 2
        while fs.exists(target) {
            let ext = (originalPath as NSString).pathExtension
            let base = (originalPath as NSString).deletingPathExtension
            target = ext.isEmpty
                ? "\(base) \(counter)"
                : "\(base) \(counter).\(ext)"
            counter += 1
        }
        try fs.restore(fromTrash: trashPath, to: target)
    }
}
