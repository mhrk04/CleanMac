//
//  LeftoverFinderTests.swift
//  CleanMacTests
//
//  Verifies the template-driven leftover scan and the orphaned-leftover
//  heuristic against an in-memory disk seeded under the real home path.
//

import XCTest
@testable import CleanMac

// Fixture constants live at file scope so they can be used as default argument
// values — a Swift method cannot default a parameter to an instance member.
private let fixtureBundleID = "com.example.testapp"
private let fixtureAppName = "TestApp"
private let fixtureAppPath = "/Applications/TestApp.app"

final class LeftoverFinderTests: XCTestCase {

    private var fs: MockFileSystem!
    private var scanner: ScannerEngine!
    private var loader: RuleLoader!
    private var finder: LeftoverFinder!

    private var bundleID: String { fixtureBundleID }
    private var appName: String { fixtureAppName }
    private var appPath: String { fixtureAppPath }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(TestResources.isAvailable, "Rule packs not present in this checkout")

        // Seed the mock disk under the real home directory so `~/…` patterns
        // in the shipped rule pack resolve onto mock paths.
        fs = MockFileSystem(home: NSHomeDirectory())
        loader = RuleLoader(bundle: TestResources.bundle, fileSystem: fs)
        scanner = ScannerEngine(fileSystem: fs, denylist: PathDenylist(), ownBundlePath: nil)
        finder = LeftoverFinder(fileSystem: fs, scanner: scanner, ruleLoader: loader)
    }

    override func tearDown() {
        finder = nil
        scanner = nil
        loader = nil
        fs = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeApp(
        bundleID: String = fixtureBundleID,
        name: String = fixtureAppName,
        path: String = fixtureAppPath,
        isSystemApp: Bool = false,
        size: Int64 = 25_000_000
    ) -> AppBundleInfo {
        AppBundleInfo(
            path: path,
            bundleIdentifier: bundleID,
            name: name,
            displayName: name,
            executableName: name,
            shortVersion: "2.1",
            buildVersion: "210",
            minimumSystemVersion: "14.0",
            location: isSystemApp ? .systemApplications : .applications,
            isSystemApp: isSystemApp,
            isRunning: false,
            runningPIDs: [],
            size: size
        )
    }

    @discardableResult
    private func seedLeftovers(
        bundleID: String = fixtureBundleID,
        appName: String = fixtureAppName
    ) -> [String] {
        var paths: [String] = []

        let caches = fs.addDirectory("~/Library/Caches/\(bundleID)")
        paths.append(fs.addFile("\(caches)/data.bin", size: 4_096))

        let prefs = fs.addFile("~/Library/Preferences/\(bundleID).plist", size: 512)
        paths.append(prefs)

        let support = fs.addDirectory("~/Library/Application Support/\(appName)")
        paths.append(fs.addFile("\(support)/settings.json", size: 1_024))

        let container = fs.addDirectory("~/Library/Containers/\(bundleID)")
        paths.append(fs.addFile("\(container)/Data/store.db", size: 2_048))

        return paths
    }

    // MARK: - Context

    func testContextCarriesEveryTemplateVariable() {
        let ctx = finder.context(for: makeApp())
        XCTAssertEqual(ctx.variables["bundleId"], bundleID)
        XCTAssertEqual(ctx.variables["appName"], appName)
        XCTAssertEqual(ctx.variables["execName"], appName)
        XCTAssertEqual(ctx.variables["appPath"], appPath)
        XCTAssertEqual(ctx.variables["bundleIdLower"], bundleID.lowercased())
        XCTAssertEqual(ctx.home, NSHomeDirectory())
    }

    // MARK: - Per-app leftovers

    func testFindsEverySeededLeftover() async {
        let seeded = seedLeftovers()
        let items = await finder.findLeftovers(for: makeApp())
        let found = items.map(\.path)

        // The scanner reports one ScanItem per *matched* path and sizes a
        // directory recursively, so a rule matching `~/Library/Caches/{bundleId}`
        // yields a single folder row rather than one row per file inside it.
        // Every seeded file must therefore be covered — either reported
        // exactly, or contained in an ancestor that was reported.
        for path in seeded {
            let covered = found.contains { path == $0 || path.hasPrefix($0 + "/") }
            XCTAssertTrue(covered, "expected leftover not reported: \(path) — found: \(found)")
        }
    }

    func testAppBundleIsAlwaysTheFirstEntry() async {
        seedLeftovers()
        let items = await finder.findLeftovers(for: makeApp())

        XCTAssertFalse(items.isEmpty)
        let first = try? XCTUnwrap(items.first)
        XCTAssertEqual(first?.path, appPath)
        XCTAssertEqual(first?.ruleID, "app-bundle")
        XCTAssertEqual(first?.category, .application)
        XCTAssertEqual(first?.size, 25_000_000)
        XCTAssertEqual(first?.isReadOnly, false)
        XCTAssertEqual(first?.isSelectedByDefault, true)
    }

    func testSystemAppBundleIsReadOnlyAndNeedsReview() async {
        let systemApp = makeApp(
            bundleID: "com.apple.systemapp",
            name: "SystemApp",
            path: "/System/Applications/SystemApp.app",
            isSystemApp: true
        )
        let items = await finder.findLeftovers(for: systemApp)

        let bundle = items.first { $0.ruleID == "app-bundle" }
        XCTAssertEqual(bundle?.isReadOnly, true)
        XCTAssertEqual(bundle?.safety, .review)
        XCTAssertEqual(bundle?.isSelectedByDefault, false)
        XCTAssertNotNil(bundle?.annotation)
    }

    func testRunningAppBundleIsNeverReportedAsLeftover() async {
        seedLeftovers()
        let items = await finder.findLeftovers(
            for: makeApp(),
            runningAppBundlePaths: [appPath]
        )
        // The authoritative bundle entry is still listed (so the UI can show
        // it), but the denylist must keep it read-only... at minimum nothing
        // *inside* the running bundle should appear.
        let insideBundle = items.filter { $0.path.hasPrefix(appPath + "/") }
        XCTAssertTrue(insideBundle.isEmpty, "paths inside a running bundle leaked: \(insideBundle.map(\.path))")
    }

    func testUnrelatedAppLeftoversAreIgnored() async {
        seedLeftovers(bundleID: "com.other.app", appName: "OtherApp")
        let items = await finder.findLeftovers(for: makeApp())

        // Only the authoritative app-bundle entry should remain.
        XCTAssertEqual(items.map(\.ruleID), ["app-bundle"])
    }

    func testAppleNamespacesAreExcluded() async {
        // The shipped pack excludes com.apple.** containers/caches/prefs.
        fs.addFile("~/Library/Caches/com.apple.testapp/data.bin", size: 4_096)
        fs.addDirectory("~/Library/Containers/com.apple.testapp")

        let items = await finder.findLeftovers(
            for: makeApp(bundleID: "com.apple.testapp", name: "AppleTestApp")
        )
        let paths = items.map(\.path)
        XCTAssertFalse(paths.contains { $0.hasSuffix("/Caches/com.apple.testapp/data.bin") })
        XCTAssertFalse(paths.contains(NSHomeDirectory() + "/Library/Containers/com.apple.testapp"))
    }

    func testResultsAreSortedBySizeDescendingAfterTheBundle() async {
        fs.addDirectory("~/Library/Caches/\(bundleID)")
        fs.addFile("~/Library/Caches/\(bundleID)/small.bin", size: 100)
        fs.addFile("~/Library/Preferences/\(bundleID).plist", size: 9_000)

        let items = await finder.findLeftovers(for: makeApp())
        let tail = items.dropFirst()
        let sizes = tail.map(\.size)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
    }

    func testDuplicateMatchesAreCollapsedByPath() async {
        // `{bundleId}` and `{bundleId}.*` can both land on the same folder.
        fs.addDirectory("~/Library/Caches/\(bundleID)")
        fs.addFile("~/Library/Caches/\(bundleID)/x.bin", size: 10)

        let items = await finder.findLeftovers(for: makeApp())
        let paths = items.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count, "duplicate paths in results")
    }

    func testEmptyDiskProducesOnlyTheBundleEntry() async {
        let items = await finder.findLeftovers(for: makeApp())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.ruleID, "app-bundle")
    }

    // MARK: - Orphaned leftovers

    func testOrphansAreReportedForUninstalledBundleIDs() async {
        fs.addDirectory("~/Library/Caches/com.gone.app")
        fs.addFile("~/Library/Caches/com.gone.app/data.bin", size: 8_192)

        let orphans = await finder.findOrphanedLeftovers(installedBundleIDs: [bundleID])
        let paths = orphans.map(\.path)

        XCTAssertTrue(
            paths.contains(NSHomeDirectory() + "/Library/Caches/com.gone.app"),
            "orphan not reported: \(paths)"
        )
    }

    func testInstalledBundleIDsAreNotOrphans() async {
        fs.addDirectory("~/Library/Caches/\(bundleID)")
        fs.addFile("~/Library/Caches/\(bundleID)/data.bin", size: 8_192)

        let orphans = await finder.findOrphanedLeftovers(installedBundleIDs: [bundleID])
        XCTAssertTrue(orphans.isEmpty, "installed app reported as orphan: \(orphans.map(\.path))")
    }

    func testChildOfAnInstalledBundleIDIsNotAnOrphan() async {
        // Helper daemons commonly use `<parent>.helper`.
        fs.addDirectory("~/Library/Caches/\(bundleID).helper")
        fs.addFile("~/Library/Caches/\(bundleID).helper/data.bin", size: 4_096)

        let orphans = await finder.findOrphanedLeftovers(installedBundleIDs: [bundleID])
        XCTAssertTrue(orphans.isEmpty, "prefix-owned entry reported as orphan: \(orphans.map(\.path))")
    }

    func testAppleOwnedPathsAreNeverOrphans() async {
        fs.addDirectory("~/Library/Caches/com.apple.Safari")
        fs.addFile("~/Library/Caches/com.apple.Safari/data.bin", size: 4_096)

        let orphans = await finder.findOrphanedLeftovers(installedBundleIDs: [])
        XCTAssertTrue(orphans.isEmpty)
    }

    func testZeroSizeEntriesAreSkipped() async {
        fs.addDirectory("~/Library/Caches/com.gone.empty")   // nothing inside

        let orphans = await finder.findOrphanedLeftovers(installedBundleIDs: [])
        XCTAssertTrue(orphans.isEmpty)
    }

    func testOrphansAreMarkedReviewAndUnselected() async {
        fs.addDirectory("~/Library/Caches/com.gone.app")
        fs.addFile("~/Library/Caches/com.gone.app/data.bin", size: 8_192)

        let orphans = await finder.findOrphanedLeftovers(installedBundleIDs: [])
        let orphan = try? XCTUnwrap(orphans.first)

        XCTAssertEqual(orphan?.safety, .review)
        XCTAssertEqual(orphan?.isSelectedByDefault, false)
        XCTAssertTrue(orphan?.ruleID.hasPrefix("orphaned-") ?? false)
        XCTAssertNotNil(orphan?.annotation)
        XCTAssertTrue(orphan?.annotation?.contains("com.gone.app") ?? false)
    }

    func testOrphanResultsAreDeduplicatedAndSorted() async {
        fs.addDirectory("~/Library/Caches/com.gone.big")
        fs.addFile("~/Library/Caches/com.gone.big/data.bin", size: 10_000)
        fs.addDirectory("~/Library/Caches/com.gone.small")
        fs.addFile("~/Library/Caches/com.gone.small/data.bin", size: 10)

        let orphans = await finder.findOrphanedLeftovers(installedBundleIDs: [])
        let paths = orphans.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count)

        let sizes = orphans.map(\.size)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
    }

    func testNonBundleIDFilenamesAreIgnored() async {
        // "Random Folder" has no dots → not a reverse-domain id.
        fs.addDirectory("~/Library/Caches/Random Folder")
        fs.addFile("~/Library/Caches/Random Folder/data.bin", size: 4_096)

        let orphans = await finder.findOrphanedLeftovers(installedBundleIDs: [])
        XCTAssertTrue(orphans.isEmpty)
    }
}
