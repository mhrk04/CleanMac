//
//  ScannerEngineTests.swift
//  CleanMacTests
//
//  Spec §3 (the scanner engine: parallel rule evaluation, live ScanProgress on
//  an AsyncStream, cooperative cancellation, denylist applied after matching)
//  and §4 (the safety layer must override whatever a rule asked for).
//
//  These tests exist because §3 was violated in a way no output-based assertion
//  could catch. The engine exposed two entry points: a streaming `scan` that
//  always returned `([], stream)` — never a single item — and a `scanAndAwait`
//  wrapper that called it, discarded the unread stream, and then walked the
//  whole disk a *second* time to produce the real answer. Every module used the
//  wrapper, so every scan paid for two full traversals and leaked the first
//  one's unbounded AsyncStream buffer. The second pass also emitted progress
//  without `ruleID` or `currentPath`, so §3's "currently scanning…" label could
//  never be rendered by the code path that actually ran.
//

import XCTest
@testable import CleanMac

final class ScannerEngineTests: XCTestCase {

    private var fs: MockFileSystem!
    private var engine: ScannerEngine!

    /// An mtime far enough in the past that the mandatory 24h Caches window
    /// (spec §4) does not swallow the fixture. Every cache-path test needs this.
    private let stale = Date(timeIntervalSince1970: 1_600_000_000)

    override func setUp() {
        super.setUp()
        fs = MockFileSystem()      // home == /mockhome, so no denylist overlap
        engine = ScannerEngine(fileSystem: fs, ownBundlePath: nil)
    }

    override func tearDown() {
        engine = nil
        fs = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeRule(
        id: String = "test-rule",
        paths: [String],
        excludes: [String] = [],
        safety: SafetyLevel = .safe
    ) -> Rule {
        Rule(
            id: id,
            name: "Test Rule \(id)",
            category: .caches,
            safety: safety,
            paths: paths,
            excludes: excludes
        )
    }

    private func cacheFixture(_ names: [String], modified: Date) {
        for name in names {
            fs.addFile("/mockhome/Library/Caches/com.example/\(name)",
                       size: 100,
                       modified: modified)
        }
    }

    // MARK: - §3: scan returns the items it matched

    func testScanReturnsTheMatchedItems() async {
        cacheFixture(["a.dat", "b.dat"], modified: stale)
        let rule = makeRule(paths: ["/mockhome/Library/Caches/com.example/*"])

        let items = await engine.scan(rules: [rule], runningAppBundlePaths: [])

        // The streaming `scan` this replaced returned an empty array
        // unconditionally, with a comment explaining that callers should use a
        // different method to get results.
        XCTAssertEqual(Set(items.map(\.path)), Set([
            "/mockhome/Library/Caches/com.example/a.dat",
            "/mockhome/Library/Caches/com.example/b.dat"
        ]), "scan() must return the matched items, not an empty placeholder.")
        XCTAssertEqual(items.first?.ruleID, rule.id)
        XCTAssertEqual(items.first?.size, 100)
    }

    func testScanEvaluatesEveryRuleAndUnionsTheResults() async {
        cacheFixture(["a.dat"], modified: stale)
        fs.addFile("/mockhome/Library/Logs/com.example/old.log", size: 50, modified: stale)

        let rules = [
            makeRule(id: "caches", paths: ["/mockhome/Library/Caches/com.example/*"]),
            makeRule(id: "logs", paths: ["/mockhome/Library/Logs/com.example/*"])
        ]

        let items = await engine.scan(rules: rules, runningAppBundlePaths: [])

        XCTAssertEqual(Set(items.map(\.ruleID)), Set(["caches", "logs"]))
        XCTAssertEqual(items.count, 2)
    }

    func testExcludesRemoveMatchesBeforeTheyAreReported() async {
        cacheFixture(["keep.dat", "drop.dat"], modified: stale)
        let rule = makeRule(
            paths: ["/mockhome/Library/Caches/com.example/*"],
            excludes: ["/mockhome/Library/Caches/com.example/drop.dat"]
        )

        let items = await engine.scan(rules: [rule], runningAppBundlePaths: [])

        XCTAssertEqual(items.map(\.path), ["/mockhome/Library/Caches/com.example/keep.dat"])
    }

    // MARK: - §3: progress on an AsyncStream

    func testScanPublishesProgressOnTheAsyncStreamAndFinishesIt() async {
        cacheFixture(["a.dat", "b.dat"], modified: stale)
        let rules = (0..<3).map {
            makeRule(id: "rule-\($0)", paths: ["/mockhome/Library/Caches/com.example/*"])
        }

        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
        // Captured as a local rather than reached through `self.engine`: an
        // `async let` child task would otherwise send the non-Sendable test case
        // across isolation domains.
        let engine = self.engine!
        async let items = engine.scan(
            rules: rules,
            runningAppBundlePaths: [],
            progress: continuation
        )

        var events: [ScanProgress] = []
        // This loop only terminates if the engine finishes the continuation.
        // Leaving it unfinished would hang the test rather than fail it, which
        // is itself the assertion.
        for await event in stream {
            events.append(event)
        }
        let found = await items

        XCTAssertEqual(events.count, rules.count + 1,
                       "Expected one event per completed rule plus a final one.")
        XCTAssertEqual(events.last?.isFinished, true)
        XCTAssertEqual(events.last?.fractionComplete, 1)
        XCTAssertEqual(events.last?.itemsFound, found.count)
        XCTAssertFalse(found.isEmpty)
    }

    func testProgressEventsCarryRuleIdentityAndCurrentPath() async {
        // §3: "Emits ScanProgress(ruleId:, itemsFound:, bytesFound:,
        // currentPath:) on an AsyncStream so the UI can render live."
        //
        // The pass that actually used to run filled in only itemsFound,
        // bytesFound and fractionComplete — so the UI's "currently scanning…"
        // label had nothing to show.
        cacheFixture(["a.dat"], modified: stale)
        let rule = makeRule(id: "user-caches", paths: ["/mockhome/Library/Caches/com.example/*"])

        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
        let engine = self.engine!
        async let items = engine.scan(rules: [rule], runningAppBundlePaths: [], progress: continuation)
        var events: [ScanProgress] = []
        for await event in stream { events.append(event) }
        _ = await items

        let perRule = events.filter { !$0.isFinished }
        XCTAssertEqual(perRule.count, 1)
        XCTAssertEqual(perRule.first?.ruleID, "user-caches")
        XCTAssertEqual(perRule.first?.ruleName, rule.name)
        XCTAssertEqual(perRule.first?.currentPath, "/mockhome/Library/Caches/com.example/a.dat")
        XCTAssertEqual(perRule.first?.itemsFound, 1)
        XCTAssertEqual(perRule.first?.bytesFound, 100)
    }

    func testOnProgressCallbackReceivesTheSameEventsAsTheStream() async {
        // Both sinks are documented as receiving identical events; a caller may
        // use either, so neither may be the one that silently gets nothing.
        cacheFixture(["a.dat"], modified: stale)
        let rule = makeRule(paths: ["/mockhome/Library/Caches/com.example/*"])
        let recorder = ProgressRecorder()

        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
        let engine = self.engine!
        async let items = engine.scan(
            rules: [rule],
            runningAppBundlePaths: [],
            progress: continuation,
            onProgress: { recorder.record($0) }
        )
        var streamed: [ScanProgress] = []
        for await event in stream { streamed.append(event) }
        _ = await items

        XCTAssertEqual(recorder.snapshot().count, streamed.count)
        XCTAssertEqual(recorder.snapshot().last?.isFinished, true)
    }

    // MARK: - §3: the tree is walked once

    func testScanWalksEachPatternExactlyOnce() async {
        // The regression that motivated this suite. Non-recursive globs are
        // resolved with a single directory listing each, so N patterns must
        // produce exactly N listings. The old implementation produced 2N: one
        // pass whose results were thrown away, then the real one.
        cacheFixture(["a.dat"], modified: stale)
        let rules = (0..<3).map {
            makeRule(id: "rule-\($0)", paths: ["/mockhome/Library/Caches/com.example/*"])
        }

        fs.resetTraversalCounts()
        let items = await engine.scan(rules: rules, runningAppBundlePaths: [])

        XCTAssertEqual(fs.enumerateCallCount, 0,
                       "Precondition: a terminal `*` must not trigger a deep enumeration.")
        XCTAssertEqual(fs.contentsOfDirectoryCallCount, rules.count,
                       "Each pattern should be listed once. Twice that means the scan ran two passes.")
        XCTAssertEqual(items.count, rules.count,
                       "Every rule matches the same file, so one item per rule is expected.")
    }

    // MARK: - §4: the denylist overrides the rule

    func testDenylistRefusesARulePointedAtASystemPath() async {
        // §4: the denylist "runs after rule matching, so even a bad user-supplied
        // rule cannot touch these paths". The fixture has to exist in the mock,
        // otherwise the test passes for the wrong reason — an empty directory
        // looks exactly like a successful refusal.
        fs.addFile("/usr/lib/libevil.dylib", size: 4_096, modified: stale)
        XCTAssertTrue(fs.exists("/usr/lib/libevil.dylib"),
                      "Precondition: the file must be present so only the denylist can stop it.")

        let rule = makeRule(id: "user-supplied-mistake", paths: ["/usr/lib/*"])
        let items = await engine.scan(rules: [rule], runningAppBundlePaths: [])

        XCTAssertTrue(items.isEmpty, "A rule targeting /usr was allowed to produce results.")
    }

    func testDenylistRefusesPathsInsideARunningAppBundle() async {
        let bundle = "/mockhome/Applications/Running.app"
        fs.addFile(bundle + "/Contents/Resources/junk.dat", size: 100, modified: stale)
        XCTAssertTrue(fs.exists(bundle + "/Contents/Resources/junk.dat"))

        let rule = makeRule(id: "app-junk", paths: ["/mockhome/Applications/Running.app/**"])
        let items = await engine.scan(
            rules: [rule],
            runningAppBundlePaths: [bundle]
        )

        XCTAssertTrue(items.isEmpty,
                      "Files inside a running app's bundle must never be offered for cleaning.")
    }

    func testFreshlyWrittenCacheIsNeverOfferedForCleaning() async {
        // End-to-end proof of §4's mandatory window. The rule asks for both
        // files and both exist; only the stale one may be reported. Before the
        // fix this depended on the rule remembering to set `modifiedWithinHours`,
        // and six of the shipped cache rules did not.
        fs.addFile("/mockhome/Library/Caches/com.example/live.dat", size: 100, modified: Date())
        fs.addFile("/mockhome/Library/Caches/com.example/stale.dat", size: 100, modified: stale)

        let rule = makeRule(paths: ["/mockhome/Library/Caches/com.example/*"])
        let items = await engine.scan(rules: [rule], runningAppBundlePaths: [])

        XCTAssertEqual(items.map(\.path), ["/mockhome/Library/Caches/com.example/stale.dat"],
                       "A cache file written moments ago must be refused regardless of the rule.")
    }

    func testRuleWindowStillAppliesOutsideCachesFolders() async {
        // The mandatory window is scoped to Caches; a rule-declared window keeps
        // working everywhere else, which is how §2's `modifiedWithin` exclude is
        // expressed on the Rule.
        fs.addFile("/mockhome/Library/Logs/com.example/fresh.log", size: 10, modified: Date())
        fs.addFile("/mockhome/Library/Logs/com.example/old.log", size: 10, modified: stale)

        let rule = Rule(
            id: "user-logs",
            name: "User Logs",
            category: .logs,
            safety: .safe,
            paths: ["/mockhome/Library/Logs/com.example/*"],
            modifiedWithinHours: 24
        )
        let items = await engine.scan(rules: [rule], runningAppBundlePaths: [])

        XCTAssertEqual(items.map(\.path), ["/mockhome/Library/Logs/com.example/old.log"])
    }

    // MARK: - Thread-safe sink

    /// Progress closures are `@Sendable` and arrive off the main actor, so the
    /// recorder needs its own lock rather than a captured `var`.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ScanProgress] = []

        func record(_ value: ScanProgress) {
            lock.lock(); defer { lock.unlock() }
            values.append(value)
        }

        func snapshot() -> [ScanProgress] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }
}
