//
//  HistoryStore.swift
//  CleanMac
//
//  Persists every CleanManifest as a JSON file in
//    ~/Library/Application Support/CleanMac/History/<timestamp>-<uuid>.json
//  so the user can review, undo, or export past cleans.
//

import Foundation
import Combine

public actor HistoryStore {

    public enum HistoryError: Error, Equatable {
        case cannotCreateDirectory(String)
        case encodingFailed(String)
        case writeFailed(String)
        case decodingFailed(String, String)   // path, message
    }

    private let fs: FileSystem
    private let directory: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Cap the number of stored manifests so history doesn't grow unbounded.
    private let maxEntries: Int

    private var cache: [CleanManifest]?

    public init(
        fileSystem: FileSystem = LiveFileSystem(),
        directory: String? = nil,
        maxEntries: Int = 200
    ) {
        self.fs = fileSystem
        self.directory = directory ?? HistoryStore.defaultDirectory()
        self.maxEntries = maxEntries

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public static func defaultDirectory() -> String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/CleanMac/History")
    }

    /// Absolute path where manifests are stored. Exposed for the Settings
    /// "Reveal History folder" button.
    public var storageDirectory: String { directory }

    // MARK: - Persistence

    /// Save a manifest. Returns the path written.
    @discardableResult
    public func save(_ manifest: CleanManifest) throws -> String {
        try ensureDirectory()

        // Populate the in-memory list before writing, and only when it is empty.
        //
        // Without this a store that only ever saves — the normal case, since
        // `CleanerService` writes after each clean and the UI may never have
        // loaded history — keeps `cache == nil`, so `cache?.append` silently
        // no-ops and `pruneIfNeeded` returns early at its `guard let cache`.
        // The `maxEntries` cap would then never be enforced and history would
        // grow without bound.
        //
        // The ordering matters: loading *after* the write would read the
        // just-written file back off disk and then append the same manifest a
        // second time, double-counting every entry.
        if cache == nil { _ = all() }

        let filename = Self.filename(for: manifest)
        let path = (directory as NSString).appendingPathComponent(filename)

        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw HistoryError.encodingFailed(error.localizedDescription)
        }
        // Written through the `FileSystem` protocol rather than `Data.write`,
        // so a store built on `MockFileSystem` exercises the real save path
        // without ever touching the developer's actual history folder.
        do {
            try fs.writeData(data, to: path)
        } catch {
            throw HistoryError.writeFailed(error.localizedDescription)
        }

        cache?.append(manifest)
        try pruneIfNeeded()
        return path
    }

    /// Load every manifest, newest first. Results are cached in memory; call
    /// `invalidateCache()` after external changes.
    public func all() -> [CleanManifest] {
        if let cache { return cache.sorted { $0.startedAt > $1.startedAt } }

        guard let entries = try? fs.contentsOfDirectory(directory) else {
            cache = []
            return []
        }
        var loaded: [CleanManifest] = []
        for entry in entries where entry.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(entry)
            guard let data = fs.readData(at: path) else { continue }
            if let manifest = try? decoder.decode(CleanManifest.self, from: data) {
                loaded.append(manifest)
            }
        }
        loaded.sort { $0.startedAt > $1.startedAt }
        cache = loaded
        return loaded
    }

    public func manifest(id: UUID) -> CleanManifest? {
        all().first { $0.id == id }
    }

    public func invalidateCache() {
        cache = nil
    }

    /// Delete a manifest record from history. Does NOT restore the files.
    public func delete(id: UUID) throws {
        guard let manifest = manifest(id: id) else { return }
        let path = (directory as NSString).appendingPathComponent(Self.filename(for: manifest))
        if fs.exists(path) {
            _ = try? fs.removeItem(at: path)
        }
        cache?.removeAll { $0.id == id }
    }

    /// Delete every manifest record.
    public func deleteAll() throws {
        guard let entries = try? fs.contentsOfDirectory(directory) else { return }
        for entry in entries where entry.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(entry)
            _ = try? fs.removeItem(at: path)
        }
        cache = []
    }

    // MARK: - Undo

    /// Undo a past clean: move every entry back from the Trash to its original
    /// path, then record the undo as its own history entry so the audit trail
    /// shows both directions.
    ///
    /// Best-effort by design — the Trash may already have been emptied, so one
    /// missing file must not abort the whole undo. Entries that could not be
    /// moved are reported in the returned manifest's `failures` rather than
    /// thrown.
    ///
    /// `CleanerService.restore(manifest:onProgress:)` performs the same moves
    /// with incremental progress reporting for the UI; this is the
    /// persistence-layer entry point, and it owns writing the result.
    @discardableResult
    public func restore(_ manifest: CleanManifest) -> CleanManifest {
        let started = Date()
        let mover = TrashMover(fileSystem: fs)
        var restored: [CleanManifest.Entry] = []
        var failures: [CleanManifest.Failure] = []

        for entry in manifest.entries {
            do {
                try mover.restore(trashPath: entry.trashPath, to: entry.originalPath)
                restored.append(entry)
            } catch let error as TrashMover.TrashError {
                failures.append(CleanManifest.Failure(path: entry.originalPath,
                                                      reason: error.message))
            } catch {
                failures.append(CleanManifest.Failure(path: entry.originalPath,
                                                      reason: error.localizedDescription))
            }
        }

        let outcome = CleanManifest(
            startedAt: started,
            finishedAt: Date(),
            source: CleanManifest.restoreSource,
            label: CleanManifest.restoreLabel(for: manifest),
            entries: restored,
            failures: failures
        )
        // Skip the write when there was nothing to undo, so history is not
        // padded with empty entries.
        if !restored.isEmpty || !failures.isEmpty {
            _ = try? save(outcome)
        }
        return outcome
    }

    // MARK: - Aggregates

    /// Net bytes the user actually got back: everything cleaned, minus anything
    /// later restored from the Trash. Adding a restore manifest's bytes on top
    /// would count the same files twice — once when they were trashed and again
    /// when they came back.
    public func totalReclaimed() -> Int64 {
        var total: Int64 = 0
        for manifest in all() {
            let bytes = manifest.bytesReclaimed
            total += manifest.isRestore ? -bytes : bytes
        }
        return max(0, total)
    }

    /// Number of successful clean operations. An undo is not a clean.
    public func cleanCount() -> Int {
        all().filter { !$0.isRestore && !$0.entries.isEmpty }.count
    }

    /// Latest clean date across all manifests. Undos are excluded so the menu
    /// bar's "last scan" is not moved by a restore.
    public func lastCleanDate() -> Date? {
        all().filter { !$0.isRestore }.map(\.startedAt).max()
    }

    // MARK: - Internals

    private func ensureDirectory() throws {
        if fs.exists(directory) { return }
        do {
            try fs.createDirectory(at: directory)
        } catch {
            throw HistoryError.cannotCreateDirectory(error.localizedDescription)
        }
    }

    private func pruneIfNeeded() throws {
        guard let cache, cache.count > maxEntries else { return }
        // Sort oldest first and delete the excess.
        let sorted = cache.sorted { $0.startedAt < $1.startedAt }
        let excess = sorted.prefix(cache.count - maxEntries)
        for manifest in excess {
            let path = (directory as NSString).appendingPathComponent(Self.filename(for: manifest))
            _ = try? fs.removeItem(at: path)
        }
        let removedIds = Set(excess.map(\.id))
        self.cache = cache.filter { !removedIds.contains($0.id) }
    }

    /// Filename scheme keeps entries naturally sorted by timestamp.
    static func filename(for manifest: CleanManifest) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: manifest.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        return "\(stamp)_\(manifest.id.uuidString).json"
    }
}
