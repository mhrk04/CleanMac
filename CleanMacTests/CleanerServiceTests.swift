//
//  CleanerServiceTests.swift
//  CleanMacTests
//
//  Covers the destructive half of the app: every item handed to the cleaner
//  must either land in the Trash with a matching manifest entry, or be
//  refused with an explainable failure. Nothing may be deleted outright, and
//  every successful clean must round-trip back through `restore`.
//

import XCTest
@testable import CleanMac

final class CleanerServiceTests: XCTestCase {

    private var fs: MockFileSystem!
    private var history: HistoryStore!
    private var cleaner: CleanerService!

    override func setUpWithError() throws {
        try super.setUpWithError()

        fs = MockFileSystem()   // home == /mockhome, so no denylist overlap

        // History lives on the mock too. It used to be given a real temp folder
        // on the grounds that `HistoryStore.save` needed `FileManager` for atomic
        // writes; since save/read/create/remove are `FileSystem` protocol
        // requirements, that excuse is gone and this suite no longer touches the
        // real disk at all (spec §14).
        history = HistoryStore(fileSystem: fs, directory: "/mockhome/History")
        cleaner = CleanerService(
            fileSystem: fs,
            history: history,
            denylist: PathDenylist(),
            ownBundlePath: nil
        )
    }

    override func tearDownWithError() throws {
        cleaner = nil
        history = nil
        fs = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Thread-safe sink for the `@Sendable` progress closure.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CleanProgress] = []

        func record(_ progress: CleanProgress) {
            lock.lock(); defer { lock.unlock() }
            values.append(progress)
        }

        var snapshot: [CleanProgress] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    private func seedCacheFiles(_ sizes: [Int64]) -> [ScanItem] {
        sizes.enumerated().map { index, size in
            let path = fs.addFile(
                "~/Library/Caches/com.example.app/file\(index).bin",
                size: size
            )
            return fs.makeItem(at: path, ruleID: "app-caches", ruleName: "App Caches")
        }
    }

    // MARK: - Happy path

    func testEveryItemIsMovedToTrashAndRecorded() async throws {
        let items = seedCacheFiles([1_000, 2_500, 4_096])

        let manifest = await cleaner.clean(items: items, source: "system-junk", label: "Test clean")

        XCTAssertEqual(manifest.entries.count, 3)
        XCTAssertTrue(manifest.failures.isEmpty)
        XCTAssertEqual(manifest.bytesReclaimed, 7_596)
        XCTAssertEqual(manifest.itemCount, 3)
        XCTAssertEqual(manifest.source, "system-junk")
        XCTAssertEqual(manifest.label, "Test clean")
        XCTAssertEqual(manifest.displayLabel, "Test clean")
        XCTAssertLessThanOrEqual(manifest.startedAt, manifest.finishedAt)

        // Nothing left at the original locations.
        for item in items {
            XCTAssertFalse(fs.exists(item.path), "still on disk: \(item.path)")
        }
        // Everything now lives under the user's Trash.
        for entry in manifest.entries {
            XCTAssertTrue(
                entry.trashPath.hasPrefix(fs.userTrashDirectory + "/"),
                "entry did not land in the Trash: \(entry.trashPath)"
            )
            XCTAssertTrue(fs.exists(entry.trashPath), "trash node missing: \(entry.trashPath)")
        }
        XCTAssertEqual(fs.trashCalls.count, 3)
    }

    func testManifestEntriesCarryRuleMetadata() async throws {
        let path = fs.addFile("~/Library/Caches/com.example.app/meta.bin", size: 77)
        let item = fs.makeItem(
            at: path,
            ruleID: "app-caches",
            ruleName: "Application Caches",
            category: .caches
        )

        let manifest = await cleaner.clean(items: [item], source: "system-junk")
        let entry = try XCTUnwrap(manifest.entries.first)

        XCTAssertEqual(entry.originalPath, path)
        XCTAssertEqual(entry.size, 77)
        XCTAssertEqual(entry.ruleID, "app-caches")
        XCTAssertEqual(entry.ruleName, "Application Caches")
        XCTAssertEqual(entry.category, RuleCategory.caches.rawValue)
        XCTAssertEqual(entry.id, path)
    }

    func testCleaningADirectoryMovesItsWholeSubtree() async throws {
        let dir = fs.addDirectory("~/Library/Caches/com.example.bundle")
        let nested = fs.addFile("\(dir)/nested/deep/data.bin", size: 300)
        // Directories report a computed size, so pass it explicitly.
        let item = fs.makeItem(at: dir, ruleID: "app-caches", sizeOverride: 5_000)

        let manifest = await cleaner.clean(items: [item], source: "system-junk")

        XCTAssertEqual(manifest.entries.count, 1)
        XCTAssertEqual(manifest.bytesReclaimed, 5_000)
        XCTAssertFalse(fs.exists(dir))
        XCTAssertFalse(fs.exists(nested))

        // Restoring brings the subtree back with it.
        let restored = await cleaner.restore(manifest: manifest)
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertTrue(fs.exists(dir))
        XCTAssertTrue(fs.exists(nested))
        XCTAssertEqual(try? fs.metadata(at: nested).allocatedSize, 300)
    }

    func testTrashingTheSameNameTwiceDoesNotCollide() async throws {
        let first = fs.addFile("~/Library/Caches/dup.bin", size: 10)
        let second = fs.addFile("~/Downloads/dup.bin", size: 20)

        let manifest = await cleaner.clean(
            items: [fs.makeItem(at: first), fs.makeItem(at: second)],
            source: "system-junk"
        )

        XCTAssertEqual(manifest.entries.count, 2)
        let trashPaths = manifest.entries.map(\.trashPath)
        XCTAssertEqual(Set(trashPaths).count, 2, "trash paths collided: \(trashPaths)")
        for path in trashPaths { XCTAssertTrue(fs.exists(path)) }
    }

    func testEmptyCleanIsANoOp() async throws {
        let recorder = ProgressRecorder()
        let manifest = await cleaner.clean(items: [], source: "system-junk") { recorder.record($0) }

        XCTAssertTrue(manifest.entries.isEmpty)
        XCTAssertTrue(manifest.failures.isEmpty)
        XCTAssertEqual(manifest.bytesReclaimed, 0)
        XCTAssertTrue(fs.trashCalls.isEmpty)

        // Only the opening and closing progress beats.
        XCTAssertEqual(recorder.snapshot.count, 2)
        XCTAssertEqual(recorder.snapshot.last?.isFinished, true)
        XCTAssertEqual(recorder.snapshot.last?.itemsTotal, 0)
        XCTAssertEqual(recorder.snapshot.last?.fractionComplete, 1)
    }

    // MARK: - Safety refusals

    func testReadOnlyItemsAreRefused() async throws {
        let path = fs.addFile("~/Library/Caches/com.example.app/locked.bin", size: 1_000)
        let item = fs.makeItem(at: path, isReadOnly: true)

        let manifest = await cleaner.clean(items: [item], source: "system-junk")

        XCTAssertTrue(manifest.entries.isEmpty)
        XCTAssertEqual(manifest.bytesReclaimed, 0)
        let failure = try XCTUnwrap(manifest.failures.first)
        XCTAssertEqual(failure.path, path)
        XCTAssertEqual(failure.reason, "Marked read-only by the safety layer")
        XCTAssertTrue(fs.exists(path), "read-only item was touched")
        XCTAssertTrue(fs.trashCalls.isEmpty)
    }

    func testSystemProtectedPathsAreRefusedAtCleanTime() async throws {
        let path = fs.addFile("/System/Library/Caches/com.example.junk", size: 8_192)
        let item = fs.makeItem(at: path, ruleID: "test-rule")

        let manifest = await cleaner.clean(items: [item], source: "system-junk")

        XCTAssertTrue(manifest.entries.isEmpty)
        XCTAssertEqual(
            manifest.failures.first?.reason,
            PathDenylist.DenyReason.systemProtected.rawValue
        )
        XCTAssertTrue(fs.exists(path))
        XCTAssertTrue(fs.trashCalls.isEmpty)
    }

    func testRunningAppBundleIsRefused() async throws {
        let bundle = fs.addDirectory("/mockhome/Applications/Running.app")
        let payload = fs.addFile("\(bundle)/Contents/MacOS/Running", size: 100)
        let item = fs.makeItem(at: bundle, sizeOverride: 50_000)

        let manifest = await cleaner.clean(
            items: [item],
            source: "uninstaller",
            runningAppBundlePaths: [bundle]
        )

        XCTAssertEqual(
            manifest.failures.first?.reason,
            PathDenylist.DenyReason.runningApplication.rawValue
        )
        XCTAssertTrue(fs.exists(bundle))
        XCTAssertTrue(fs.exists(payload))
    }

    func testOwnBundleIsRefused() async throws {
        let ownBundle = "/mockhome/Applications/CleanMac.app"
        let inside = fs.addFile("\(ownBundle)/Contents/Resources/Rules/system-junk.yaml", size: 4_096)
        let localCleaner = CleanerService(
            fileSystem: fs,
            history: history,
            denylist: PathDenylist(),
            ownBundlePath: ownBundle
        )

        let manifest = await localCleaner.clean(
            items: [fs.makeItem(at: inside)],
            source: "system-junk"
        )

        XCTAssertEqual(
            manifest.failures.first?.reason,
            PathDenylist.DenyReason.ownBundle.rawValue
        )
        XCTAssertTrue(fs.exists(inside))
    }

    func testProtectedUserDirectoryIsRefused() async throws {
        let denylist = PathDenylist()
        let documents = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
        let path = fs.addFile("\(documents)/thesis.pdf", size: 999)

        // Sanity-check the denylist directly so a failure here points at the
        // right layer.
        let rule = Rule(
            id: "test-rule", name: "Test", category: .other,
            safety: .safe, paths: [], excludes: []
        )
        let decision = denylist.decide(
            path: path,
            metadata: try? fs.metadata(at: path),
            rule: rule,
            runningAppBundlePaths: [],
            ownBundlePath: nil
        )
        let expected: PathDenylist.Decision = .denied(reason: .protectedUserDirectory)
        XCTAssertEqual(decision, expected)

        let manifest = await cleaner.clean(items: [fs.makeItem(at: path)], source: "large-and-old")
        XCTAssertEqual(
            manifest.failures.first?.reason,
            PathDenylist.DenyReason.protectedUserDirectory.rawValue
        )
        XCTAssertTrue(fs.exists(path))
    }

    func testMixedBatchSeparatesSuccessesFromRefusals() async throws {
        let good = fs.addFile("~/Library/Caches/com.example.app/good.bin", size: 1_000)
        let locked = fs.addFile("~/Library/Caches/com.example.app/locked.bin", size: 2_000)
        let denied = fs.addFile("/usr/local/share/keep.bin", size: 4_000)

        let manifest = await cleaner.clean(
            items: [
                fs.makeItem(at: good),
                fs.makeItem(at: locked, isReadOnly: true),
                fs.makeItem(at: denied)
            ],
            source: "system-junk"
        )

        XCTAssertEqual(manifest.entries.map(\.originalPath), [good])
        XCTAssertEqual(manifest.bytesReclaimed, 1_000)
        XCTAssertEqual(Set(manifest.failures.map(\.path)), [locked, denied])
        XCTAssertEqual(manifest.failures.count, 2)
    }

    // MARK: - IO failures

    func testMissingFileIsReportedAsNotFound() async throws {
        let ghost = "/mockhome/Library/Caches/com.example.app/ghost.bin"
        let item = fs.makeItem(at: ghost, sizeOverride: 123)

        let manifest = await cleaner.clean(items: [item], source: "system-junk")

        XCTAssertTrue(manifest.entries.isEmpty)
        XCTAssertEqual(manifest.failures.first?.reason, "File not found: \(ghost)")
    }

    func testPermissionDeniedSurfacesAReadableReason() async throws {
        let path = fs.addFile("~/Library/Caches/com.example.app/perm.bin", size: 500)
        fs.trashFailures[path] = .permissionDenied(path)

        let manifest = await cleaner.clean(items: [fs.makeItem(at: path)], source: "system-junk")

        XCTAssertTrue(manifest.entries.isEmpty)
        XCTAssertEqual(manifest.failures.first?.reason, "Permission denied: \(path)")
        XCTAssertTrue(fs.exists(path), "the node should not have moved")
    }

    func testReadOnlyVolumeIsDetectedFromTheUnderlyingMessage() async throws {
        let path = fs.addFile("~/Library/Caches/com.example.app/ro.bin", size: 500)
        fs.trashFailures[path] = .ioFailure(path, "read-only file system")

        let manifest = await cleaner.clean(items: [fs.makeItem(at: path)], source: "system-junk")

        XCTAssertEqual(manifest.failures.first?.reason, "Read-only volume: \(path)")
        // A read-only volume is fatal, so no retry should have been attempted.
        XCTAssertEqual(fs.trashCalls.count, 1)
    }

    func testTransientIOFailureIsRetriedThenReported() async throws {
        let path = fs.addFile("~/Library/Caches/com.example.app/busy.bin", size: 500)
        fs.trashFailures[path] = .ioFailure(path, "resource busy")

        let manifest = await cleaner.clean(items: [fs.makeItem(at: path)], source: "system-junk")

        XCTAssertTrue(manifest.entries.isEmpty)
        XCTAssertEqual(fs.trashCalls.count, 2, "expected exactly one retry")
        let reason = try XCTUnwrap(manifest.failures.first?.reason)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(fs.exists(path))
    }

    func testCleaningTheSameItemsTwiceReportsNotFoundTheSecondTime() async throws {
        let items = seedCacheFiles([100])

        let first = await cleaner.clean(items: items, source: "system-junk")
        XCTAssertEqual(first.entries.count, 1)

        let second = await cleaner.clean(items: items, source: "system-junk")
        XCTAssertTrue(second.entries.isEmpty)
        XCTAssertEqual(second.failures.first?.path, items[0].path)
        XCTAssertTrue(second.failures.first?.reason.hasPrefix("File not found:") ?? false)
    }

    // MARK: - Progress

    func testProgressReportsEveryItemAndFinishes() async throws {
        let items = seedCacheFiles([100, 200, 300, 400])
        let recorder = ProgressRecorder()

        let manifest = await cleaner.clean(items: items, source: "system-junk") { recorder.record($0) }
        let beats = recorder.snapshot

        // Opening beat + one per item + closing beat.
        XCTAssertEqual(beats.count, items.count + 2)
        XCTAssertEqual(beats.first?.itemsProcessed, 0)
        XCTAssertEqual(beats.first?.isFinished, false)
        XCTAssertEqual(beats.first?.itemsTotal, items.count)

        for beat in beats { XCTAssertEqual(beat.itemsTotal, items.count) }

        let processed = beats.dropFirst().dropLast().map(\.itemsProcessed)
        XCTAssertEqual(processed, Array(1...items.count))

        let last = try XCTUnwrap(beats.last)
        XCTAssertTrue(last.isFinished)
        XCTAssertEqual(last.itemsProcessed, manifest.entries.count)
        XCTAssertEqual(last.bytesFreed, manifest.bytesReclaimed)
        XCTAssertEqual(last.failureCount, 0)
        XCTAssertNil(last.currentPath)
        XCTAssertEqual(last.fractionComplete, 1)

        // Bytes freed must never go backwards.
        let freed = beats.map(\.bytesFreed)
        XCTAssertEqual(freed, freed.sorted())
        XCTAssertEqual(freed.last, 1_000)
    }

    func testProgressCountsFailuresAlongsideSuccesses() async throws {
        let good = fs.addFile("~/Library/Caches/com.example.app/a.bin", size: 100)
        let bad = fs.addFile("~/Library/Caches/com.example.app/b.bin", size: 200)
        fs.trashFailures[bad] = .permissionDenied(bad)
        let recorder = ProgressRecorder()

        let manifest = await cleaner.clean(
            items: [fs.makeItem(at: good), fs.makeItem(at: bad)],
            source: "system-junk"
        ) { recorder.record($0) }

        XCTAssertEqual(manifest.entries.count, 1)
        XCTAssertEqual(manifest.failures.count, 1)
        XCTAssertEqual(recorder.snapshot.last?.failureCount, 1)
        XCTAssertEqual(recorder.snapshot.last?.itemsProcessed, 2)
        XCTAssertEqual(recorder.snapshot.last?.bytesFreed, 100)
    }

    // MARK: - History persistence

    func testManifestIsPersistedToHistory() async throws {
        let items = seedCacheFiles([1_024, 2_048])

        let manifest = await cleaner.clean(items: items, source: "smart-scan", label: "Smart Scan")

        let stored = await history.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, manifest.id)
        XCTAssertEqual(stored.first?.source, "smart-scan")
        XCTAssertEqual(stored.first?.displayLabel, "Smart Scan")
        XCTAssertEqual(stored.first?.entries.count, 2)

        let reclaimed = await history.totalReclaimed()
        let cleans = await history.cleanCount()
        let lastClean = await history.lastCleanDate()
        let fetched = await history.manifest(id: manifest.id)
        XCTAssertEqual(reclaimed, 3_072)
        XCTAssertEqual(cleans, 1)
        XCTAssertNotNil(lastClean)
        XCTAssertNotNil(fetched)
    }

    func testDefaultLabelFallsBackToTheModuleName() async throws {
        _ = await cleaner.clean(items: seedCacheFiles([10]), source: "large-and-old")
        let stored = await history.all()
        XCTAssertEqual(stored.first?.label, nil)
        XCTAssertEqual(stored.first?.displayLabel, "Large & Old Files clean")
    }

    func testPersistManifestFalseLeavesHistoryUntouched() async throws {
        let manifest = await cleaner.clean(
            items: seedCacheFiles([500]),
            source: "system-junk",
            persistManifest: false
        )

        XCTAssertEqual(manifest.entries.count, 1, "the clean itself must still happen")
        let stored = await history.all()
        XCTAssertTrue(stored.isEmpty, "manifest leaked into history")
        let reclaimed = await history.totalReclaimed()
        XCTAssertEqual(reclaimed, 0)
    }

    func testRefusedItemsAreStillPersistedSoTheUserSeesWhy() async throws {
        let path = fs.addFile("~/Library/Caches/com.example.app/locked.bin", size: 1_000)
        _ = await cleaner.clean(
            items: [fs.makeItem(at: path, isReadOnly: true)],
            source: "system-junk"
        )

        let stored = await history.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stored.first?.entries.isEmpty ?? false)
        XCTAssertEqual(stored.first?.failures.count, 1)
        // A clean with nothing reclaimed must not inflate the counters.
        let cleans = await history.cleanCount()
        let reclaimed = await history.totalReclaimed()
        XCTAssertEqual(cleans, 0)
        XCTAssertEqual(reclaimed, 0)
    }

    func testHistoryAccumulatesAcrossCleans() async throws {
        _ = await cleaner.clean(items: seedCacheFiles([100]), source: "system-junk")
        _ = await cleaner.clean(
            items: [fs.makeItem(at: fs.addFile("~/Downloads/movie.mov", size: 900))],
            source: "large-and-old"
        )

        let stored = await history.all()
        XCTAssertEqual(stored.count, 2)
        let reclaimed = await history.totalReclaimed()
        let cleans = await history.cleanCount()
        XCTAssertEqual(reclaimed, 1_000)
        XCTAssertEqual(cleans, 2)
    }

    // MARK: - HistoryStore undo

    /// A *fresh* history store over the same mock directory, i.e. what the app
    /// would see if the user quit and relaunched before choosing Undo: no
    /// in-memory cache, everything read back off the mock disk.
    private func makeMockHistory() -> HistoryStore {
        HistoryStore(fileSystem: fs, directory: "/mockhome/History")
    }

    func testHistoryStoreRestoreMovesEntriesBack() async throws {
        let items = seedCacheFiles([400, 600])
        let originals = items.map(\.path)
        let manifest = await cleaner.clean(items: items, source: "system-junk", label: "Undo me")
        for path in originals { XCTAssertFalse(fs.exists(path), "still present: \(path)") }

        let outcome = await makeMockHistory().restore(manifest)

        XCTAssertEqual(outcome.entries.count, 2)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(outcome.isRestore)
        XCTAssertEqual(outcome.source, CleanManifest.restoreSource)
        for path in originals { XCTAssertTrue(fs.exists(path), "not restored: \(path)") }
    }

    func testHistoryStoreRestoreReportsFailuresWithoutThrowing() async throws {
        let items = seedCacheFiles([250])
        let original = try XCTUnwrap(items.first?.path)
        let manifest = await cleaner.clean(items: items, source: "system-junk")
        let trashPath = try XCTUnwrap(manifest.entries.first?.trashPath)

        // Simulate an emptied Trash: the entry is gone before the undo runs.
        // One missing file must not abort the whole restore.
        fs.removeNode(trashPath)

        let outcome = await makeMockHistory().restore(manifest)
        XCTAssertTrue(outcome.entries.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.failures.first?.path, original)
        XCTAssertFalse(fs.exists(original), "a failed undo must not resurrect the file")
    }

    func testUndoIsNotCountedAsReclaimedSpace() async throws {
        let manifest = await cleaner.clean(items: seedCacheFiles([1_000]), source: "system-junk")
        let before = await history.totalReclaimed()
        XCTAssertEqual(before, 1_000)

        _ = await cleaner.restore(manifest: manifest)

        // Those bytes went back onto the disk, so the net reclaim is zero — and
        // the undo must not be counted as a second clean.
        let after = await history.totalReclaimed()
        let cleans = await history.cleanCount()
        XCTAssertEqual(after, 0)
        XCTAssertEqual(cleans, 1)
    }

    // MARK: - Restore round-trip

    func testRestorePutsEverythingBack() async throws {
        let items = seedCacheFiles([1_000, 2_500])
        let originals = items.map(\.path)
        let manifest = await cleaner.clean(items: items, source: "system-junk", label: "Round trip")

        let restored = await cleaner.restore(manifest: manifest)

        XCTAssertEqual(restored.entries.count, 2)
        XCTAssertTrue(restored.failures.isEmpty)
        XCTAssertEqual(restored.source, "restore")
        XCTAssertEqual(restored.bytesReclaimed, 3_500)
        XCTAssertTrue(restored.label?.contains("Round trip") ?? false)

        for (path, item) in zip(originals, items) {
            XCTAssertTrue(fs.exists(path), "not restored: \(path)")
            XCTAssertEqual(try? fs.metadata(at: path).allocatedSize, item.size)
        }
        // The trash copies are gone — this was a move, not a copy.
        for entry in manifest.entries { XCTAssertFalse(fs.exists(entry.trashPath)) }
        XCTAssertEqual(fs.restoreCalls.count, 2)

        // Both directions are on the audit trail.
        let stored = await history.all()
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.contains { $0.source == "system-junk" })
        XCTAssertTrue(stored.contains { $0.source == "restore" })
    }

    func testRestoreFailsWhenTheTrashWasEmptied() async throws {
        let items = seedCacheFiles([900])
        let manifest = await cleaner.clean(items: items, source: "system-junk")
        let trashPath = try XCTUnwrap(manifest.entries.first?.trashPath)

        fs.removeNode(trashPath)   // the user emptied the Trash

        let restored = await cleaner.restore(manifest: manifest)

        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertEqual(restored.failures.count, 1)
        XCTAssertEqual(restored.failures.first?.path, items[0].path)
        XCTAssertEqual(restored.failures.first?.reason, "File not found: \(trashPath)")
        XCTAssertFalse(fs.exists(items[0].path))
        XCTAssertTrue(fs.restoreCalls.isEmpty)
    }

    func testRestoreIsPartialWhenOnlySomeTrashEntriesSurvive() async throws {
        let items = seedCacheFiles([100, 200, 300])
        let manifest = await cleaner.clean(items: items, source: "system-junk")
        let victim = try XCTUnwrap(manifest.entries.dropFirst().first?.trashPath)
        fs.removeNode(victim)

        let restored = await cleaner.restore(manifest: manifest)

        XCTAssertEqual(restored.entries.count, 2)
        XCTAssertEqual(restored.failures.count, 1)
        XCTAssertEqual(restored.bytesReclaimed, 400)
        XCTAssertFalse(restored.entries.contains { $0.trashPath == victim })
    }

    func testRestoreDoesNotClobberAPathRecreatedInTheMeantime() async throws {
        let path = fs.addFile("~/Library/Caches/com.example.app/dup.bin", size: 400)
        let manifest = await cleaner.clean(items: [fs.makeItem(at: path)], source: "system-junk")

        // Something wrote a brand new file to the original location.
        fs.addFile(path, size: 10)

        let restored = await cleaner.restore(manifest: manifest)

        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertTrue(restored.failures.isEmpty)

        let suffixed = ((path as NSString).deletingPathExtension) + " 2.bin"
        XCTAssertTrue(fs.exists(suffixed), "restored copy should have been renamed")
        XCTAssertEqual(try? fs.metadata(at: suffixed).allocatedSize, 400)
        XCTAssertEqual(try? fs.metadata(at: path).allocatedSize, 10, "the new file was overwritten")
    }

    func testRestoreOfAnEmptyManifestIsANoOp() async throws {
        let empty = CleanManifest(
            startedAt: Date(),
            finishedAt: Date(),
            source: "system-junk",
            label: nil,
            entries: [],
            failures: []
        )

        let restored = await cleaner.restore(manifest: empty)

        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertTrue(restored.failures.isEmpty)
        XCTAssertEqual(restored.bytesReclaimed, 0)
        XCTAssertTrue(fs.restoreCalls.isEmpty)
        XCTAssertEqual(restored.label, "Restore of System Junk clean")
    }

    func testRestoreReportsProgressAndFinishes() async throws {
        let items = seedCacheFiles([10, 20, 30])
        let manifest = await cleaner.clean(items: items, source: "system-junk")
        let recorder = ProgressRecorder()

        _ = await cleaner.restore(manifest: manifest) { recorder.record($0) }
        let beats = recorder.snapshot

        XCTAssertEqual(beats.count, items.count + 2)
        XCTAssertEqual(beats.first?.itemsTotal, 3)
        XCTAssertEqual(beats.first?.itemsProcessed, 0)
        let lastBeat = try XCTUnwrap(beats.last)
        XCTAssertTrue(lastBeat.isFinished)
        XCTAssertEqual(beats.last?.itemsProcessed, 3)
        XCTAssertEqual(beats.last?.bytesFreed, 60)
        XCTAssertEqual(beats.map(\.bytesFreed), [0, 10, 30, 60, 60])
    }

    func testCleanThenRestoreThenCleanAgainIsStable() async throws {
        let items = seedCacheFiles([2_000])
        let original = try XCTUnwrap(items.first?.path)

        let first = await cleaner.clean(items: items, source: "system-junk")
        XCTAssertFalse(fs.exists(original))

        _ = await cleaner.restore(manifest: first)
        XCTAssertTrue(fs.exists(original))
        XCTAssertEqual(try? fs.metadata(at: original).allocatedSize, 2_000)

        let second = await cleaner.clean(items: items, source: "system-junk")
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.bytesReclaimed, 2_000)
        XCTAssertFalse(fs.exists(original))
    }
}
