//
//  CleanerService.swift
//  CleanMac
//
//  Runs a clean operation: takes a list of ScanItems, moves each to the
//  Trash, and produces a CleanManifest describing successes and failures.
//

import Foundation

public actor CleanerService {

    private let fs: FileSystem
    private let trashMover: TrashMover
    private let denylist: PathDenylist
    private let history: HistoryStore
    private let ownBundlePath: String?

    public init(
        fileSystem: FileSystem,
        history: HistoryStore,
        denylist: PathDenylist = PathDenylist(),
        ownBundlePath: String? = Bundle.main.bundlePath
    ) {
        self.fs = fileSystem
        self.trashMover = TrashMover(fileSystem: fileSystem)
        self.denylist = denylist
        self.history = history
        self.ownBundlePath = ownBundlePath
    }

    /// Clean a list of items.
    ///
    /// - Parameters:
    ///   - items: The scan items to move to Trash. Read-only items are skipped.
    ///   - source: Module name for the manifest, e.g. `"system-junk"`.
    ///   - label: Optional human label for the History entry.
    ///   - runningAppBundlePaths: Snapshot taken on the main actor before
    ///     the clean starts.
    ///   - progress: Writable half of an `AsyncStream<CleanProgress>` the caller
    ///     created (spec §5: "emits progress on an AsyncStream for the UI").
    ///     Finished exactly once, when the clean ends.
    ///   - onProgress: Callback alternative. Both sinks receive identical events.
    /// - Returns: A manifest describing the outcome. Always saved to History
    ///   unless the caller passes `persistManifest: false`.
    ///
    /// Deliberately non-throwing: §5 requires a failed trash operation to be
    /// collected into `manifest.failures` and reported at the end rather than
    /// aborting the run, so there is no error left to throw.
    @discardableResult
    public func clean(
        items: [ScanItem],
        source: String,
        label: String? = nil,
        runningAppBundlePaths: Set<String> = [],
        persistManifest: Bool = true,
        progress: AsyncStream<CleanProgress>.Continuation? = nil,
        onProgress: (@Sendable (CleanProgress) -> Void)? = nil
    ) async -> CleanManifest {
        let started = Date()
        var entries: [CleanManifest.Entry] = []
        var failures: [CleanManifest.Failure] = []
        var bytesFreed: Int64 = 0

        // One fan-out point for both sinks, so no emit site below can publish to
        // the callback and forget the stream.
        let emit: (@Sendable (CleanProgress) -> Void)? = { event in
            progress?.yield(event)
            onProgress?(event)
        }

        let total = items.count
        emit?(CleanProgress(
            itemsTotal: total,
            itemsProcessed: 0,
            bytesFreed: 0,
            currentPath: items.first?.path,
            isFinished: false,
            failureCount: 0
        ))

        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }

            // Refuse read-only items.
            if item.isReadOnly {
                failures.append(CleanManifest.Failure(
                    path: item.path,
                    reason: "Marked read-only by the safety layer"
                ))
                emit?(CleanProgress(
                    itemsTotal: total,
                    itemsProcessed: index + 1,
                    bytesFreed: bytesFreed,
                    currentPath: item.path,
                    isFinished: false,
                    failureCount: failures.count
                ))
                continue
            }

            // Re-check the denylist at clean time. The world may have changed
            // between scan and clean (an app that was closed is now running).
            let meta = try? fs.metadata(at: item.path)
            let rule = Rule(
                id: item.ruleID,
                name: item.ruleName,
                category: item.category,
                safety: item.safety,
                paths: [],
                excludes: []
            )
            let decision = denylist.decide(
                path: item.path,
                metadata: meta,
                rule: rule,
                runningAppBundlePaths: runningAppBundlePaths,
                ownBundlePath: ownBundlePath
            )
            if case .denied(let reason) = decision {
                failures.append(CleanManifest.Failure(
                    path: item.path,
                    reason: reason.rawValue
                ))
                emit?(CleanProgress(
                    itemsTotal: total,
                    itemsProcessed: index + 1,
                    bytesFreed: bytesFreed,
                    currentPath: item.path,
                    isFinished: false,
                    failureCount: failures.count
                ))
                continue
            }

            // Move to Trash.
            do {
                let trashPath = try trashMover.trash(path: item.path)
                entries.append(CleanManifest.Entry(
                    originalPath: item.path,
                    trashPath: trashPath,
                    size: item.size,
                    ruleID: item.ruleID,
                    ruleName: item.ruleName,
                    category: item.category.rawValue
                ))
                bytesFreed += item.size
            } catch let error as TrashMover.TrashError {
                failures.append(CleanManifest.Failure(
                    path: item.path,
                    reason: Self.describe(error)
                ))
            } catch {
                failures.append(CleanManifest.Failure(
                    path: item.path,
                    reason: error.localizedDescription
                ))
            }

            emit?(CleanProgress(
                itemsTotal: total,
                itemsProcessed: index + 1,
                bytesFreed: bytesFreed,
                currentPath: item.path,
                isFinished: false,
                failureCount: failures.count
            ))
        }

        let manifest = CleanManifest(
            startedAt: started,
            finishedAt: Date(),
            source: source,
            label: label,
            entries: entries,
            failures: failures
        )

        if persistManifest, !entries.isEmpty || !failures.isEmpty {
            _ = try? await history.save(manifest)
        }

        emit?(CleanProgress(
            itemsTotal: total,
            itemsProcessed: entries.count + failures.count,
            bytesFreed: bytesFreed,
            currentPath: nil,
            isFinished: true,
            failureCount: failures.count
        ))
        // Terminating the stream is what releases a caller blocked in
        // `for await event in stream`; without it that loop never ends.
        progress?.finish()

        return manifest
    }

    /// Restore every entry of a previous manifest, best-effort.
    /// Returns a new manifest describing what was restored and what failed.
    ///
    /// `progress`/`onProgress` mirror `clean`: an undo can take a while and the
    /// UI renders the same live counter for it.
    @discardableResult
    public func restore(
        manifest: CleanManifest,
        progress: AsyncStream<CleanProgress>.Continuation? = nil,
        onProgress: (@Sendable (CleanProgress) -> Void)? = nil
    ) async -> CleanManifest {
        let started = Date()
        var entries: [CleanManifest.Entry] = []
        var failures: [CleanManifest.Failure] = []
        var bytesRestored: Int64 = 0

        let emit: (@Sendable (CleanProgress) -> Void)? = { event in
            progress?.yield(event)
            onProgress?(event)
        }

        let total = manifest.entries.count
        emit?(CleanProgress(
            itemsTotal: total,
            itemsProcessed: 0,
            bytesFreed: 0,
            currentPath: manifest.entries.first?.originalPath,
            isFinished: false,
            failureCount: 0
        ))

        for (index, entry) in manifest.entries.enumerated() {
            if Task.isCancelled { break }
            do {
                try trashMover.restore(trashPath: entry.trashPath, to: entry.originalPath)
                entries.append(entry)
                bytesRestored += entry.size
            } catch let error as TrashMover.TrashError {
                failures.append(CleanManifest.Failure(
                    path: entry.originalPath,
                    reason: Self.describe(error)
                ))
            } catch {
                failures.append(CleanManifest.Failure(
                    path: entry.originalPath,
                    reason: error.localizedDescription
                ))
            }
            emit?(CleanProgress(
                itemsTotal: total,
                itemsProcessed: index + 1,
                bytesFreed: bytesRestored,
                currentPath: entry.originalPath,
                isFinished: false,
                failureCount: failures.count
            ))
        }

        let restoreManifest = CleanManifest(
            startedAt: started,
            finishedAt: Date(),
            source: CleanManifest.restoreSource,
            label: CleanManifest.restoreLabel(for: manifest),
            entries: entries,
            failures: failures
        )

        // Persist the restore as its own history entry so the audit trail
        // shows both directions.
        _ = try? await history.save(restoreManifest)

        emit?(CleanProgress(
            itemsTotal: total,
            itemsProcessed: entries.count + failures.count,
            bytesFreed: bytesRestored,
            currentPath: nil,
            isFinished: true,
            failureCount: failures.count
        ))
        progress?.finish()

        return restoreManifest
    }

    // MARK: - Helpers

    private static func describe(_ error: TrashMover.TrashError) -> String {
        error.message
    }
}
