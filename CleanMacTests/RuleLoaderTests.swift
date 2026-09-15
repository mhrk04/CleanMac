//
//  RuleLoaderTests.swift
//  CleanMacTests
//
//  YAML → RulePack decoding, user-rule merging, pack-level excludes, and
//  the typed Large & Old Files defaults view.
//

import XCTest
@testable import CleanMac

final class RuleLoaderTests: XCTestCase {

    private let loader = RuleLoader(
        bundle: TestResources.bundle,
        fileSystem: MockFileSystem(),
        userRulesDirectory: "/nonexistent-user-rules"
    )

    // MARK: - Decoding

    func testDecodesMinimalPack() throws {
        let yaml = """
        pack: unit-test
        version: 3
        rules:
          - id: test.caches
            name: Test Caches
            category: caches
            safety: safe
            paths:
              - "~/Library/Caches/*"
            excludes:
              - "~/Library/Caches/com.apple.*"
            description: A rule for tests.
        """

        let pack = try loader.decode(text: yaml, packNameHint: "unit-test")

        XCTAssertEqual(pack.name, "unit-test")
        XCTAssertEqual(pack.version, 3)
        XCTAssertEqual(pack.rules.count, 1)

        let rule = try XCTUnwrap(pack.rules.first)
        XCTAssertEqual(rule.id, "test.caches")
        XCTAssertEqual(rule.name, "Test Caches")
        XCTAssertEqual(rule.category, .caches)
        XCTAssertEqual(rule.safety, .safe)
        XCTAssertEqual(rule.paths, ["~/Library/Caches/*"])
        XCTAssertTrue(rule.excludes.contains("~/Library/Caches/com.apple.*"))
        XCTAssertEqual(rule.description, "A rule for tests.")
        XCTAssertNil(rule.strategy)
    }

    func testMissingIDThrows() {
        let yaml = """
        pack: broken
        version: 1
        rules:
          - name: No ID here
            paths:
              - "/tmp/*"
        """
        XCTAssertThrowsError(try loader.decode(text: yaml, packNameHint: "broken")) { error in
            guard let loadError = error as? RuleLoadError else {
                return XCTFail("Expected RuleLoadError, got \(error)")
            }
            if case .malformed = loadError { return }
            XCTFail("Expected .malformed, got \(loadError)")
        }
    }

    func testInvalidSafetyThrows() {
        let yaml = """
        pack: broken
        version: 1
        rules:
          - id: bad.safety
            safety: probably-fine
            paths:
              - "/tmp/*"
        """
        XCTAssertThrowsError(try loader.decode(text: yaml, packNameHint: "broken"))
    }

    func testUnknownStrategyThrows() {
        let yaml = """
        pack: broken
        version: 1
        rules:
          - id: bad.strategy
            strategy: quantumSweep
            paths:
              - "/tmp/*"
        """
        XCTAssertThrowsError(try loader.decode(text: yaml, packNameHint: "broken"))
    }

    func testKnownStrategiesDecode() throws {
        for strategy in ["languageFilter", "trashBins", "brokenLoginItems", "tmutilSnapshots"] {
            let yaml = """
            pack: strategies
            version: 1
            rules:
              - id: rule.\(strategy)
                strategy: \(strategy)
                paths:
                  - "/tmp/*"
            """
            let pack = try loader.decode(text: yaml, packNameHint: "strategies")
            let rule = try XCTUnwrap(pack.rules.first)
            XCTAssertNotNil(rule.strategy, "strategy '\(strategy)' should decode")
            XCTAssertTrue(rule.isSpecialized)
        }
    }

    func testPackNameHintUsedWhenPackKeyAbsent() throws {
        let pack = try loader.decode(text: "version: 7\nrules: []", packNameHint: "hinted-name")
        XCTAssertEqual(pack.name, "hinted-name")
        XCTAssertEqual(pack.version, 7)
        XCTAssertTrue(pack.rules.isEmpty)
    }

    func testNonMappingRootThrows() {
        XCTAssertThrowsError(try loader.decode(text: "- a\n- b\n", packNameHint: "list"))
    }

    // MARK: - Pack-level excludes

    func testPackExcludesAreMergedIntoEveryRule() throws {
        let yaml = """
        pack: excludes
        version: 1
        excludes:
          - "**/com.apple.*"
        rules:
          - id: rule.one
            paths: ["/tmp/a"]
          - id: rule.two
            paths: ["/tmp/b"]
            excludes: ["**/keepme"]
        """
        let pack = try loader.decode(text: yaml, packNameHint: "excludes")

        let one = try XCTUnwrap(pack.rules.first { $0.id == "rule.one" })
        XCTAssertTrue(one.excludes.contains("**/com.apple.*"))

        let two = try XCTUnwrap(pack.rules.first { $0.id == "rule.two" })
        XCTAssertTrue(two.excludes.contains("**/com.apple.*"))
        XCTAssertTrue(two.excludes.contains("**/keepme"))
    }

    func testApplyPackExcludesIsIdempotent() throws {
        var pack = RulePack(
            name: "p",
            version: 1,
            rules: [Rule(id: "r", name: "R", category: .other, safety: .safe, paths: ["/tmp/x"])],
            excludes: ["**/nope"]
        )
        pack = RuleLoader.applyPackExcludes(pack)
        let once = pack.rules[0].excludes
        pack = RuleLoader.applyPackExcludes(pack)
        XCTAssertEqual(once, pack.rules[0].excludes)
        XCTAssertEqual(once.filter { $0 == "**/nope" }.count, 1)
    }

    // MARK: - Merging

    func testUserRulesOverrideBundledByID() {
        let bundled = RulePack(name: "pack", version: 2, rules: [
            Rule(id: "a", name: "A bundled", category: .caches, safety: .safe, paths: ["/a"]),
            Rule(id: "b", name: "B bundled", category: .logs, safety: .review, paths: ["/b"])
        ], excludes: ["**/x"])

        let user = RulePack(name: "pack", version: 5, rules: [
            Rule(id: "b", name: "B user", category: .logs, safety: .safe, paths: ["/b-user"]),
            Rule(id: "c", name: "C user", category: .other, safety: .safe, paths: ["/c"])
        ], excludes: ["**/y"])

        let merged = RuleLoader.merge(bundled: bundled, user: user)

        XCTAssertEqual(merged.version, 5, "max(bundled, user)")
        XCTAssertEqual(merged.rules.map(\.id), ["a", "b", "c"], "bundled order preserved, new rules appended")
        XCTAssertEqual(merged.rules[1].name, "B user", "user wins entirely")
        XCTAssertEqual(merged.rules[1].paths, ["/b-user"])
        XCTAssertEqual(merged.excludes, ["**/x", "**/y"])
    }

    func testMergeKeepsBundledNameAndUserDefaults() {
        let bundled = RulePack(name: "original", version: 1, rules: [], defaults: ["k": "bundled"])
        let user = RulePack(name: "ignored", version: 1, rules: [], defaults: ["k": "user"])
        let merged = RuleLoader.merge(bundled: bundled, user: user)
        XCTAssertEqual(merged.name, "original")
        XCTAssertEqual(merged.defaults?["k"], "user")
    }

    func testLoadUserReturnsNilWhenAbsent() throws {
        let pack = try loader.loadUser(named: "does-not-exist")
        XCTAssertNil(pack)
    }

    func testLoadMergedFallsBackToBundledWithoutUserOverrides() throws {
        try XCTSkipUnless(TestResources.isAvailable, "Rule packs not present in this checkout")
        let pack = try loader.loadMerged(named: RulePackName.systemJunk)
        XCTAssertEqual(pack.name, RulePackName.systemJunk)
        XCTAssertFalse(pack.rules.isEmpty)
    }

    // MARK: - Shipped rule packs

    func testSystemJunkPackIsWellFormed() throws {
        try XCTSkipUnless(TestResources.isAvailable, "Rule packs not present in this checkout")
        let pack = try loader.loadBundled(named: RulePackName.systemJunk)

        XCTAssertFalse(pack.rules.isEmpty)
        for rule in pack.rules {
            XCTAssertFalse(rule.id.isEmpty, "Every rule needs an id")
            // A rule is actionable if it has globs to match *or* a `strategy`
            // that dispatches to a specialised handler. Volume trashes, Time
            // Machine snapshots and broken login items are discovered at
            // runtime (mounted volumes, `tmutil`, the login-item database), so
            // they legitimately ship with no paths at all.
            XCTAssertFalse(rule.paths.isEmpty && !rule.isSpecialized,
                           "Rule \(rule.id) has neither paths nor a strategy")
            // Nothing in the shipped pack should point straight at the home
            // directory or a SIP location.
            for path in rule.paths {
                XCTAssertFalse(path == "~", "Rule \(rule.id) targets the home root")
                XCTAssertFalse(path.hasPrefix("/System/"), "Rule \(rule.id) targets /System")
            }
        }
    }

    func testUninstallerLeftoversPackUsesBundleIDTemplate() throws {
        try XCTSkipUnless(TestResources.isAvailable, "Rule packs not present in this checkout")
        let pack = try loader.loadBundled(named: RulePackName.uninstallerLeftovers)
        XCTAssertFalse(pack.rules.isEmpty)

        let templated = pack.rules.filter { rule in
            rule.paths.contains { $0.contains("{bundleId}") || $0.contains("{appName}") }
        }
        XCTAssertFalse(templated.isEmpty, "Leftover rules should be template-driven")
    }

    // MARK: - keepLanguages

    func testDecodesKeepLanguagesFlowSequence() throws {
        let yaml = """
        pack: langs
        version: 1
        rules:
          - id: language-files
            name: Unused Language Files
            category: languages
            safety: review
            strategy: languageFilter
            paths: ["~/Library/**/*.lproj"]
            keepLanguages: [active]
        """
        let pack = try loader.decode(text: yaml, packNameHint: "langs")
        let rule = try XCTUnwrap(pack.rules.first)
        XCTAssertEqual(rule.strategy, .languageFilter)
        XCTAssertEqual(rule.keepLanguages, ["active"])
    }

    func testKeepLanguagesAcceptsLiteralCodesAlongsideActive() throws {
        let yaml = """
        pack: langs
        version: 1
        rules:
          - id: language-files
            strategy: languageFilter
            paths:
              - "~/Library/**/*.lproj"
            keepLanguages:
              - active
              - en
              - zh-Hans
        """
        let pack = try loader.decode(text: yaml, packNameHint: "langs")
        let rule = try XCTUnwrap(pack.rules.first)
        XCTAssertEqual(rule.keepLanguages, ["active", "en", "zh-Hans"])
        XCTAssertEqual(rule.effectiveKeepLanguages, ["active", "en", "zh-Hans"])
    }

    func testKeepLanguagesDefaultsToActiveWhenAbsent() throws {
        // The default has to be "keep the user's own languages", never "keep
        // nothing": a rule that forgets the key must not turn into a rule that
        // offers up every language the user actually reads.
        let yaml = """
        pack: langs
        version: 1
        rules:
          - id: language-files
            strategy: languageFilter
            paths: ["~/Library/**/*.lproj"]
        """
        let pack = try loader.decode(text: yaml, packNameHint: "langs")
        let rule = try XCTUnwrap(pack.rules.first)
        XCTAssertNil(rule.keepLanguages)
        XCTAssertEqual(rule.effectiveKeepLanguages, [Rule.activeLanguagesToken])
    }

    func testEmptyKeepLanguagesAlsoDefaultsToActive() throws {
        let yaml = """
        pack: langs
        version: 1
        rules:
          - id: language-files
            strategy: languageFilter
            paths: ["~/Library/**/*.lproj"]
            keepLanguages: []
        """
        let pack = try loader.decode(text: yaml, packNameHint: "langs")
        let rule = try XCTUnwrap(pack.rules.first)
        XCTAssertEqual(rule.keepLanguages, [])
        XCTAssertEqual(rule.effectiveKeepLanguages, [Rule.activeLanguagesToken])
    }

    func testShippedLanguageFilterRuleDeclaresKeepLanguages() throws {
        try XCTSkipUnless(TestResources.isAvailable, "Rule packs not present in this checkout")
        let pack = try loader.loadBundled(named: RulePackName.systemJunk)
        let rule = try XCTUnwrap(
            pack.rules.first { $0.strategy == .languageFilter },
            "system-junk.yaml ships no languageFilter rule"
        )
        // Spec §2: `keepLanguages: [active]`, resolved at scan time.
        XCTAssertEqual(rule.keepLanguages, ["active"])
        XCTAssertFalse(rule.paths.isEmpty)
        XCTAssertEqual(rule.safety, .review, "Language deletion must not be pre-checked")
    }

    // MARK: - Large files defaults

    func testLargeFilesDefaultsDecode() throws {
        try XCTSkipUnless(TestResources.isAvailable, "Rule packs not present in this checkout")
        let pack = try loader.loadBundled(named: RulePackName.largeFilesDefaults)
        let config = LargeFilesConfig.decode(from: pack)

        XCTAssertGreaterThan(config.sizeThresholdMB, 0)
        XCTAssertFalse(config.searchRoots.isEmpty)
        XCTAssertFalse(config.skipPaths.isEmpty)
        XCTAssertFalse(config.bundleExtensions.isEmpty, "Bundles should be treated as single units")
    }

    func testLargeFilesConfigEmptyHasSafeDefaults() {
        let config = LargeFilesConfig.empty
        XCTAssertEqual(config.presets.count, 0)
        XCTAssertFalse(config.searchRoots.contains("/"))
    }

    func testDecodeFromPackWithoutDefaultsYieldsEmpty() {
        let pack = RulePack(name: "no-defaults", version: 1, rules: [])
        let config = LargeFilesConfig.decode(from: pack)
        XCTAssertEqual(config, LargeFilesConfig.empty)
    }
}
