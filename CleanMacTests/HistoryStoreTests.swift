//
//  HistoryStoreTests.swift
//  CleanMacTests
//
//  Spec §13 (the HistoryStore API: save/all/restore/totalReclaimed) and §14
//  ("all FileSystem-touching code goes through a protocol so tests never hit
//  the real disk").
//
//  These tests exist because §14 was quietly violated here: the store took a
//  `FileSystem` but then wrote manifests with `Data.write`, read them with
//  `FileManager.contents`, and created/removed directories with `FileManager`.
//  A HistoryStore built on `MockFileSystem` therefore still created and read
//  real files in the developer's own
//  ~/Library/Application Support/CleanMac/History — the mock was bypassed for
//  exactly the operations that matter. The four content/directory operations
//  are now protocol requirements, and every test below runs against the mock.
//

import XCTest
@testable import CleanMac

final class HistoryStoreTests: XCTestCase {

    private var fs: MockFileSystem!
    private var store: HistoryStore!
    /// Deliberately under the mock home (`/mockhome`), a path that cannot exist
    /// on a real volume — so anything landing here provably went through the
    /// protocol rather than FileManager.
    private var directory: String!

    override func setUp() {
        super.setUp()
        fs = MockFileSystem()
        directory = (fs.homeDirectory as NSString)
            .appendingPathComponent("Library/Application Support/CleanMac/History")
        store = HistoryStore(fileSystem: fs, directory: directory, maxEntries: 3)
    }

    override func tearDown() {
        fs = nil
        store = nil
        directory = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeManifest(
        startedAt: Date,
        source: String = "system-junk",
        entries: [(path: String, size: Int64)] = [("/mockhome/Library/Caches/junk", 100)]
    ) -> CleanManifest {
        CleanManifest(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(1),
            source: source,
            label: nil,
            entries: entries.map { entry in
                CleanManifest.Entry(
                    originalPath: entry.path,
                    trashPath: (fs.userTrashDirectory as NSString)
                        .appendingPathComponent((entry.path as NSString).lastPathComponent),
                    size: entry.size,
                    ruleID: "test-rule",
                    ruleName: "Test Rule",
                    category: "caches"
                )
            },
            failures: []
        )
    }

    // MARK: - §14: nothing reaches the real disk

    func testSaveWritesThroughTheFileSystemProtocol() async throws {
        let manifest = makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let path = try await store.save(manifest)

        XCTAssertTrue(path.hasPrefix("/mockhome/"),
                      "Manifest was written to \(path), which is not inside the mock. "
                      + "save() must go through the FileSystem protocol, not FileManager.")
        XCTAssertTrue(fs.exists(path), "The mock never saw the write.")
        XCTAssertNotNil(fs.readData(at: path), "The mock holds a node but no bytes for it.")
    }

    func testSaveCreatesTheHistoryDirectoryInTheMock() async throws {
        XCTAssertFalse(fs.exists(directory), "Precondition: the directory should not exist yet.")
        _ = try await store.save(makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertTrue(fs.exists(directory),
                      "ensureDirectory() must create the folder through the protocol.")
    }

    func testAllReadsManifestsBackFromTheMockAfterCacheInvalidation() async throws {
        // The store caches in memory, so a plain save/all pair would pass even
        // if reading were broken. Invalidating forces the read-back path.
        let first = makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_001_000))
        _ = try await store.save(first)
        _ = try await store.save(second)

        await store.invalidateCache()
        let loaded = await store.all()

        XCTAssertEqual(Set(loaded.map(\.id)), Set([first.id, second.id]),
                       "Round-trip through JSON lost or altered a manifest.")
    }

    // MARK: - §13: the required API

    func testAllReturnsNewestFirst() async throws {
        let older = makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_009_999))
        _ = try await store.save(older)
        _ = try await store.save(newer)

        await store.invalidateCache()
        let loaded = await store.all()

        XCTAssertEqual(loaded.first?.id, newer.id, "all() must be sorted newest first.")
        XCTAssertEqual(loaded.last?.id, older.id)
    }

    func testTotalReclaimedSubtractsRestores() async throws {
        // A restore puts bytes back on the disk, so adding its size would count
        // the same files twice — once trashed, once returned.
        let clean = makeManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [(path: "/mockhome/Library/Caches/a", size: 1_000)]
        )
        let undo = makeManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_001_000),
            source: CleanManifest.restoreSource,
            entries: [(path: "/mockhome/Library/Caches/a", size: 400)]
        )
        _ = try await store.save(clean)
        _ = try await store.save(undo)

        await store.invalidateCache()
        let total = await store.totalReclaimed()
        XCTAssertEqual(total, 600, "Restore bytes must be subtracted, not added.")
    }

    func testTotalReclaimedNeverGoesNegative() async throws {
        // Restoring more than was ever cleaned (e.g. after pruning old entries)
        // must report 0 rather than a negative "reclaimed" figure in the UI.
        let undo = makeManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_001_000),
            source: CleanManifest.restoreSource,
            entries: [(path: "/mockhome/Library/Caches/a", size: 5_000)]
        )
        _ = try await store.save(undo)

        await store.invalidateCache()
        let total = await store.totalReclaimed()
        XCTAssertEqual(total, 0)
    }

    func testDeleteRemovesTheRecordAndItsFile() async throws {
        let manifest = makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let path = try await store.save(manifest)
        XCTAssertTrue(fs.exists(path))

        try await store.delete(id: manifest.id)

        let loaded = await store.all()
        XCTAssertTrue(loaded.isEmpty, "The record survived delete().")
        XCTAssertFalse(fs.exists(path), "delete() left the JSON file on the mock disk.")
    }

    func testDeleteUnknownIDIsANoOp() async throws {
        let manifest = makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await store.save(manifest)

        try await store.delete(id: UUID())

        let loaded = await store.all()
        XCTAssertEqual(loaded.count, 1, "An unknown id must not delete anything.")
    }

    func testDeleteAllEmptiesHistory() async throws {
        _ = try await store.save(makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        _ = try await store.save(makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_001_000)))

        try await store.deleteAll()

        let loaded = await store.all()
        XCTAssertTrue(loaded.isEmpty)
        let remaining = (try? fs.contentsOfDirectory(directory)) ?? []
        XCTAssertTrue(remaining.filter { $0.hasSuffix(".json") }.isEmpty,
                      "deleteAll() left manifest files behind.")
    }

    func testPruneKeepsOnlyTheNewestMaxEntries() async throws {
        // maxEntries is 3 for this suite. Saving 5 must evict the two oldest,
        // and eviction has to remove the files, not just the in-memory cache —
        // otherwise the next launch would reload them.
        for offset in 0..<5 {
            _ = try await store.save(
                makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 1000))
            )
        }

        let loaded = await store.all()
        XCTAssertEqual(loaded.count, 3, "History grew past maxEntries.")

        await store.invalidateCache()
        let fromDisk = await store.all()
        XCTAssertEqual(fromDisk.count, 3,
                       "Pruning removed the cache entries but left the files on disk.")
        let stamps = fromDisk.map { Int($0.startedAt.timeIntervalSince1970) }
        XCTAssertFalse(stamps.contains(1_700_000_000), "The oldest entry should have been evicted.")
        XCTAssertTrue(stamps.contains(1_700_004_000), "The newest entry must survive.")
    }

    // MARK: - §13: restore

    func testRestoreMovesItemsBackAndRecordsAnUndo() async throws {
        let original = "/mockhome/Library/Caches/precious.dat"
        // `makeManifest` derives the trash path as <trash>/<last component>,
        // which is exactly where a real clean would have put this file.
        let trashPath = (fs.userTrashDirectory as NSString)
            .appendingPathComponent("precious.dat")
        fs.addFile(trashPath, size: 2_048)

        let stored = makeManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [(path: original, size: 2_048)]
        )
        XCTAssertEqual(stored.entries.first?.trashPath, trashPath,
                       "Fixture drift: the manifest must point at the file in the mock trash.")
        _ = try await store.save(stored)

        let outcome = await store.restore(stored)

        XCTAssertTrue(fs.exists(original), "The file was not moved back to its original path.")
        XCTAssertFalse(fs.exists(trashPath), "The file is still sitting in the Trash.")
        XCTAssertEqual(outcome.entries.count, 1)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(outcome.isRestore, "The undo must be recorded with the restore source.")

        // The undo is itself written to history, so the audit trail shows both
        // directions of the operation.
        let loaded = await store.all()
        XCTAssertTrue(loaded.contains { $0.isRestore }, "No undo entry was recorded in history.")
    }

    func testRestoreOfAMissingTrashItemReportsFailureInsteadOfThrowing() async throws {
        // The Trash may already have been emptied. One missing file must not
        // abort the whole undo or crash the app — it belongs in `failures`.
        let manifest = makeManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [(path: "/mockhome/Library/Caches/gone.dat", size: 512)]
        )

        let outcome = await store.restore(manifest)

        XCTAssertTrue(outcome.entries.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.failures.first?.path, "/mockhome/Library/Caches/gone.dat")
    }

    func testRestoreWithNothingToDoWritesNoHistoryEntry() async throws {
        // An empty manifest must not pad the history with a meaningless undo.
        let empty = CleanManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_001),
            source: "system-junk",
            label: nil,
            entries: [],
            failures: []
        )

        let outcome = await store.restore(empty)

        XCTAssertTrue(outcome.entries.isEmpty)
        XCTAssertTrue(outcome.failures.isEmpty)
        let loaded = await store.all()
        XCTAssertTrue(loaded.isEmpty, "An empty undo was recorded in history.")
    }

    // MARK: - Aggregates

    func testCleanCountExcludesRestoresAndEmptyEntries() async throws {
        _ = try await store.save(makeManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [(path: "/mockhome/Library/Caches/a", size: 10)]
        ))
        _ = try await store.save(makeManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_001_000),
            source: CleanManifest.restoreSource,
            entries: [(path: "/mockhome/Library/Caches/a", size: 10)]
        ))
        _ = try await store.save(makeManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_002_000),
            entries: []
        ))

        await store.invalidateCache()
        let count = await store.cleanCount()
        XCTAssertEqual(count, 1, "Only a real clean with entries should be counted.")
    }

    func testLastCleanDateIgnoresRestores() async throws {
        _ = try await store.save(makeManifest(startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        _ = try await store.save(makeManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_050_000),
            source: CleanManifest.restoreSource
        ))

        await store.invalidateCache()
        let last = await store.lastCleanDate()
        XCTAssertEqual(last?.timeIntervalSince1970, 1_700_000_000,
                       "An undo must not move the reported last-clean date.")
    }

    func testAllOnAnEmptyStoreReturnsEmptyWithoutThrowing() async {
        // The directory does not exist yet; all() must degrade to [] rather
        // than surface a notDirectory error to the UI.
        let loaded = await store.all()
        let reclaimed = await store.totalReclaimed()
        let lastClean = await store.lastCleanDate()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(reclaimed, 0)
        XCTAssertNil(lastClean)
    }
}
