//
//  FileWalkerTests.swift
//  CleanMacTests
//
//  Spec §3: the traversal contract every scanner depends on. These tests pin
//  the behaviours that are expensive to get wrong and invisible when they are:
//  packages stay opaque, hidden files stay hidden, age/size/extension filters
//  apply to the right kinds of entry, and a cancelled walk reports nothing.
//

import XCTest
@testable import CleanMac

/// A one-shot barrier. Used to make the cancellation test deterministic: the
/// detached task cannot begin enumerating until the test has already cancelled
/// it. `DispatchSemaphore` is wrapped because a `Task.detached` closure is
/// `@Sendable` and the wrapper makes that conformance explicit.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func signal() { semaphore.signal() }
}

final class FileWalkerTests: XCTestCase {

    private var fs: MockFileSystem!
    private var walker: FileWalker!

    private let appsRoot = "/mockhome/Apps"
    private let libraryRoot = "/mockhome/Library"

    override func setUp() {
        super.setUp()
        fs = MockFileSystem(home: "/mockhome")
        walker = FileWalker(fileSystem: fs)

        // A bundle. On disk macOS marks this as a package; a junk rule must
        // see one item, not the thousands of files inside it.
        fs.addPackage("\(appsRoot)/TestApp.app")
        fs.addFile("\(appsRoot)/TestApp.app/Contents/Info.plist", size: 512)
        fs.addFile("\(appsRoot)/TestApp.app/de.lproj/Localizable.strings", size: 4096)
        fs.addFile("\(appsRoot)/PlainFolder/inner.txt", size: 32)

        fs.addFile("\(libraryRoot)/Caches/Keep/cache.bin", size: 2 * 1024 * 1024)
        fs.addFile("\(libraryRoot)/Caches/Keep/small.bin", size: 10)
        fs.addFile("\(libraryRoot)/Caches/Skip/junk.bin", size: 1024)
        fs.addFile("\(libraryRoot)/Caches/.hidden.dat", size: 1024)

        fs.addFile("\(libraryRoot)/Docs/Report.PDF", size: 1024)
        fs.addFile("\(libraryRoot)/Docs/notes.txt", size: 1024)

        let now = Date()
        fs.addFile("\(libraryRoot)/Old/ancient.dat", size: 1024,
                   accessed: now.addingTimeInterval(-40 * 86_400))
        fs.addFile("\(libraryRoot)/Old/fresh.dat", size: 1024, accessed: now)
        // No dates at all: an age filter must skip rather than guess.
        fs.addFile("\(libraryRoot)/Old/undated.dat", size: 1024)
        // Modification date only, to prove the access-date fallback.
        fs.addFile("\(libraryRoot)/Old/modifiedLongAgo.dat", size: 1024,
                   modified: now.addingTimeInterval(-40 * 86_400))

        fs.addDirectory("\(libraryRoot)/Assets.xcassets")
        fs.addFile("\(libraryRoot)/Assets.xcassets/img.png", size: 1024)

        fs.addSymlink("\(libraryRoot)/Docs/alias.txt")
    }

    override func tearDown() {
        fs = nil
        walker = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Walk `roots` and return the paths reported, paired with their metadata.
    private func walk(
        roots: [String],
        options: FileWalker.Options = .default
    ) async throws -> [(path: String, meta: FileMetadata)] {
        let box = ScanCollector<(String, FileMetadata)>()
        try await walker.walk(roots: roots, options: options) { path, meta in
            box.append((path, meta))
            return .continueEnumeration
        }
        return box.drain()
    }

    private func names(_ entries: [(path: String, meta: FileMetadata)]) -> Set<String> {
        Set(entries.map { ($0.path as NSString).lastPathComponent })
    }

    // MARK: - Packages (spec §3: `.skipsPackageDescendants`)

    func testPackageIsReportedOnceAndNeverDescendedInto() async throws {
        let entries = try await walk(roots: [appsRoot])
        let paths = Set(entries.map(\.path))

        XCTAssertTrue(paths.contains("\(appsRoot)/TestApp.app"),
                      "The bundle itself must still be reported, or junk rules could never offer it.")
        XCTAssertFalse(paths.contains("\(appsRoot)/TestApp.app/Contents/Info.plist"),
                       "Descended into a package: .skipsPackageDescendants is not being honoured.")
        XCTAssertFalse(paths.contains("\(appsRoot)/TestApp.app/de.lproj/Localizable.strings"),
                       "Descended into a package's nested resources.")

        // Sibling non-package directories are still walked normally.
        XCTAssertTrue(paths.contains("\(appsRoot)/PlainFolder/inner.txt"))
    }

    func testPackageMetadataIsFlagged() async throws {
        let entries = try await walk(roots: [appsRoot])
        let bundle = try XCTUnwrap(entries.first { $0.path.hasSuffix("TestApp.app") })
        XCTAssertTrue(bundle.meta.isPackage)
        XCTAssertTrue(bundle.meta.isDirectory, "A package is still a directory, just an opaque one.")
    }

    func testOrdinaryDirectoriesAreNotFlaggedAsPackages() async throws {
        let entries = try await walk(roots: [appsRoot])
        let plain = try XCTUnwrap(entries.first { $0.path.hasSuffix("PlainFolder") })
        XCTAssertFalse(plain.meta.isPackage)
    }

    // MARK: - Hidden files

    func testHiddenFilesAreSkippedByDefault() async throws {
        let entries = try await walk(roots: ["\(libraryRoot)/Caches"])
        XCTAssertFalse(names(entries).contains(".hidden.dat"))
    }

    func testIncludeHiddenReportsDotFiles() async throws {
        let options = FileWalker.Options(includeHidden: true)
        let entries = try await walk(roots: ["\(libraryRoot)/Caches"], options: options)
        XCTAssertTrue(names(entries).contains(".hidden.dat"))
    }

    // MARK: - Skip patterns

    func testSkipPatternPrunesTheWholeSubtree() async throws {
        let options = FileWalker.Options(skipPathPatterns: ["\(libraryRoot)/Caches/Skip"])
        let entries = try await walk(roots: ["\(libraryRoot)/Caches"], options: options)
        let paths = Set(entries.map(\.path))

        XCTAssertFalse(paths.contains("\(libraryRoot)/Caches/Skip"))
        XCTAssertFalse(paths.contains("\(libraryRoot)/Caches/Skip/junk.bin"),
                       "A pruned directory must not leak its children.")
        XCTAssertTrue(paths.contains("\(libraryRoot)/Caches/Keep/cache.bin"),
                      "Pruning must be surgical: unrelated siblings survive.")
    }

    // MARK: - Bundle extensions

    func testBundleExtensionIsTreatedAsASingleUnit() async throws {
        // `.xcassets` is not a macOS package, so the FileSystem layer will not
        // prune it; this is the walker's own second layer doing the job.
        let options = FileWalker.Options(bundleExtensions: [".xcassets"])
        let entries = try await walk(roots: [libraryRoot], options: options)
        let paths = Set(entries.map(\.path))

        XCTAssertTrue(paths.contains("\(libraryRoot)/Assets.xcassets"))
        XCTAssertFalse(paths.contains("\(libraryRoot)/Assets.xcassets/img.png"))
    }

    // MARK: - Size / age / extension filters

    func testMinSizeAppliesToRegularFilesOnly() async throws {
        let options = FileWalker.Options(minSizeBytes: 1024 * 1024)
        let entries = try await walk(roots: ["\(libraryRoot)/Caches"], options: options)
        let files = entries.filter { $0.meta.isRegularFile }.map(\.path)

        XCTAssertEqual(Set(files), ["\(libraryRoot)/Caches/Keep/cache.bin"])
        // Directories pass the size filter through so their children can be
        // judged individually; only the root of the subtree is excluded.
        XCTAssertTrue(entries.contains { $0.path == "\(libraryRoot)/Caches/Keep" })
    }

    func testOlderThanDaysPrefersContentAccessDate() async throws {
        let options = FileWalker.Options(olderThanDays: 10)
        let entries = try await walk(roots: ["\(libraryRoot)/Old"], options: options)

        XCTAssertTrue(names(entries).contains("ancient.dat"))
        XCTAssertFalse(names(entries).contains("fresh.dat"))
    }

    func testOlderThanDaysFallsBackToModificationDate() async throws {
        // `modifiedLongAgo.dat` has no access date, so the modification date
        // is the only evidence available and must be used.
        let options = FileWalker.Options(olderThanDays: 10)
        let entries = try await walk(roots: ["\(libraryRoot)/Old"], options: options)
        XCTAssertTrue(names(entries).contains("modifiedLongAgo.dat"))
    }

    func testUndatedEntriesAreSkippedWhenAnAgeFilterIsActive() async throws {
        // Guessing "old" for an entry with no timestamps would offer a file
        // for deletion on no evidence at all. Skipping is the safe answer.
        let options = FileWalker.Options(olderThanDays: 10)
        let entries = try await walk(roots: ["\(libraryRoot)/Old"], options: options)
        XCTAssertFalse(names(entries).contains("undated.dat"))
    }

    func testAgeFilterDoesNotApplyToDirectories() async throws {
        // A folder has no meaningful "last opened" date. Filtering directories
        // on age would prune whole subtrees, taking the genuinely old files
        // inside them with it — so the exemption is what makes the filter
        // useful rather than destructive.
        let options = FileWalker.Options(olderThanDays: 10)
        let entries = try await walk(roots: [libraryRoot], options: options)

        XCTAssertTrue(entries.contains { $0.meta.isDirectory && $0.path == "\(libraryRoot)/Old" },
                      "Directories must survive an age filter so their children can be judged.")
        XCTAssertTrue(names(entries).contains("ancient.dat"))
        XCTAssertFalse(names(entries).contains("fresh.dat"))
    }

    func testAllowedExtensionsAreCaseInsensitive() async throws {
        let options = FileWalker.Options(allowedExtensions: ["pdf"])
        let entries = try await walk(roots: ["\(libraryRoot)/Docs"], options: options)
        let files = Set(entries.filter { $0.meta.isRegularFile }.map(\.path))

        XCTAssertEqual(files, ["\(libraryRoot)/Docs/Report.PDF"])
    }

    // MARK: - Symlinks

    func testSymbolicLinkIsReportedAsALeaf() async throws {
        let entries = try await walk(roots: ["\(libraryRoot)/Docs"])
        let alias = try XCTUnwrap(entries.first { $0.path.hasSuffix("alias.txt") })

        XCTAssertTrue(alias.meta.isSymbolicLink)
        XCTAssertFalse(alias.meta.isDirectory,
                       "A symlink is never treated as a directory to descend into.")
    }

    // MARK: - Caps, missing roots, collection

    func testMaxResultsCapsEmission() async throws {
        let options = FileWalker.Options(maxResults: 2)
        let entries = try await walk(roots: ["\(libraryRoot)/Caches/Keep"], options: options)
        XCTAssertEqual(entries.count, 2)
    }

    func testMissingRootIsSkippedWithoutThrowing() async throws {
        // A junk rule routinely targets directories that do not exist on this
        // machine (no Xcode, no Docker, ...). That is not an error.
        let entries = try await walk(roots: ["/mockhome/DoesNotExist", appsRoot])
        XCTAssertFalse(entries.isEmpty, "The valid root must still be walked.")
    }

    func testCollectReturnsTheSameEntriesAsTheStreamingWalk() async throws {
        let streamed = try await walk(roots: [libraryRoot])
        let collected = try await walker.collect(roots: [libraryRoot], options: .default)
        XCTAssertEqual(Set(streamed.map(\.path)), Set(collected.map(\.0)))
    }

    // MARK: - Cancellation (spec §3: cooperative `Task.checkCancellation()`)

    func testCancelledWalkReportsNothing() async throws {
        let visited = ScanCollector<String>()
        let gate = Gate()
        let walker = self.walker!
        let root = appsRoot

        // The gate makes this deterministic. Without it the detached task can
        // finish the walk on another core before `cancel()` lands, and the
        // assertion would pass or fail on scheduling alone.
        let task = Task.detached {
            gate.wait()
            try await walker.walk(roots: [root], options: .default) { path, _ in
                visited.append(path)
                return .continueEnumeration
            }
        }
        task.cancel()
        gate.signal()

        try await task.value
        XCTAssertEqual(visited.count, 0, "A cancelled walk must not report entries.")
    }
}
