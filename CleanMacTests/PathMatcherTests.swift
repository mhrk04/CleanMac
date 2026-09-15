//
//  PathMatcherTests.swift
//  CleanMacTests
//
//  Glob → regex conversion, `~`/`$HOME`/`{variable}` expansion, path
//  standardisation, and the pre-compiled CompiledGlob fast path.
//

import XCTest
@testable import CleanMac

final class PathMatcherTests: XCTestCase {

    private let matcher = PathMatcher()
    private let home = "/Users/tester"

    private var context: PathMatcher.Context {
        PathMatcher.Context(home: home, variables: [:])
    }

    // MARK: - Expansion

    func testExpandsTilde() {
        XCTAssertEqual(matcher.expand("~", context: context), home)
        XCTAssertEqual(matcher.expand("~/Library/Caches", context: context), "\(home)/Library/Caches")
    }

    func testExpandsHomeVariable() {
        XCTAssertEqual(matcher.expand("$HOME/Library", context: context), "\(home)/Library")
        XCTAssertEqual(matcher.expand("$HOME", context: context), home)
    }

    func testLeavesAbsolutePathAlone() {
        XCTAssertEqual(matcher.expand("/Library/Caches", context: context), "/Library/Caches")
    }

    func testSubstitutesTemplateVariables() {
        let ctx = PathMatcher.Context(home: home, variables: [
            "bundleId": "com.example.app",
            "appName": "Example"
        ])
        XCTAssertEqual(
            matcher.expand("~/Library/Caches/{bundleId}", context: ctx),
            "\(home)/Library/Caches/com.example.app"
        )
        XCTAssertEqual(
            matcher.expand("~/Library/Application Support/{appName}/Caches", context: ctx),
            "\(home)/Library/Application Support/Example/Caches"
        )
    }

    func testUnknownVariableBecomesEmptyString() {
        // Deliberate: lets orphan-leftover scans degrade instead of crashing.
        XCTAssertEqual(matcher.expand("~/Library/Caches/{bundleId}", context: context),
                       "\(home)/Library/Caches/")
    }

    func testMultipleVariablesInOnePattern() {
        let ctx = PathMatcher.Context(home: home, variables: ["a": "one", "b": "two"])
        XCTAssertEqual(matcher.expand("{a}/{b}/{a}", context: ctx), "one/two/one")
    }

    func testUnbalancedBraceIsPreserved() {
        XCTAssertEqual(matcher.expand("/tmp/{oops", context: context), "/tmp/{oops")
    }

    // MARK: - Glob matching

    func testSingleStarDoesNotCrossSlashes() {
        XCTAssertTrue(matcher.matches(path: "/tmp/a/b", pattern: "/tmp/*/b"))
        XCTAssertFalse(matcher.matches(path: "/tmp/a/c/b", pattern: "/tmp/*/b"))
    }

    func testDoubleStarCrossesSlashes() {
        XCTAssertTrue(matcher.matches(path: "/tmp/a/b/c/d.log", pattern: "/tmp/**/*.log"))
        XCTAssertTrue(matcher.matches(path: "/tmp/d.log", pattern: "/tmp/**/*.log"))
        XCTAssertFalse(matcher.matches(path: "/tmp/a/b/c.txt", pattern: "/tmp/**/*.log"))
    }

    func testDoubleStarTrailingMatchesDirectoryItselfAndDescendants() {
        XCTAssertTrue(matcher.matches(path: "/tmp/cache", pattern: "/tmp/cache/**"))
        XCTAssertTrue(matcher.matches(path: "/tmp/cache/deep/nested", pattern: "/tmp/cache/**"))
        XCTAssertFalse(matcher.matches(path: "/tmp/other", pattern: "/tmp/cache/**"))
    }

    func testQuestionMarkMatchesSingleCharacter() {
        XCTAssertTrue(matcher.matches(path: "/tmp/cat", pattern: "/tmp/ca?"))
        XCTAssertFalse(matcher.matches(path: "/tmp/cart", pattern: "/tmp/ca?"))
        XCTAssertFalse(matcher.matches(path: "/tmp/ca/", pattern: "/tmp/ca?"))
    }

    func testCharacterClassAndNegation() {
        XCTAssertTrue(matcher.matches(path: "/tmp/a1", pattern: "/tmp/a[0-9]"))
        XCTAssertFalse(matcher.matches(path: "/tmp/ax", pattern: "/tmp/a[0-9]"))
        XCTAssertTrue(matcher.matches(path: "/tmp/ax", pattern: "/tmp/a[!0-9]"))
    }

    func testRegexMetacharactersAreEscaped() {
        // A literal dot in the pattern must not match any character.
        XCTAssertTrue(matcher.matches(path: "/tmp/com.apple.cache", pattern: "/tmp/com.apple.*"))
        XCTAssertFalse(matcher.matches(path: "/tmp/comXappleYcache", pattern: "/tmp/com.apple.*"))
    }

    func testBracesAreEscapedAfterVariableSubstitution() {
        // `{`/`}` are regex quantifier braces, so a value that arrives through
        // substitution must be escaped instead of being compiled as a
        // repetition. `a{2}` is the discriminating case: unescaped it would
        // match "/tmp/aa".
        let ctx = PathMatcher.Context(home: home, variables: ["name": "a{2}"])
        XCTAssertTrue(matcher.matches(path: "/tmp/a{2}", pattern: "/tmp/{name}", context: ctx))
        XCTAssertFalse(matcher.matches(path: "/tmp/aa", pattern: "/tmp/{name}", context: ctx),
                       "braces were compiled as a regex quantifier instead of a literal")

        // And the escaping is visible in the compiled source.
        XCTAssertEqual(matcher.globToRegex("/tmp/a{2}"), "^/tmp/a\\{2\\}$")
    }

    func testMatchesAny() {
        let patterns = ["/tmp/one/*", "/tmp/two/**"]
        XCTAssertTrue(matcher.matchesAny(path: "/tmp/one/a", patterns: patterns))
        XCTAssertTrue(matcher.matchesAny(path: "/tmp/two/deep/a", patterns: patterns))
        XCTAssertFalse(matcher.matchesAny(path: "/tmp/three/a", patterns: patterns))
        XCTAssertFalse(matcher.matchesAny(path: "/tmp/one/a", patterns: []))
    }

    func testMatchingExpandsTildeInPattern() {
        let ctx = PathMatcher.Context(home: home, variables: [:])
        XCTAssertTrue(matcher.matches(path: "\(home)/Library/Caches/foo",
                                      pattern: "~/Library/Caches/*",
                                      context: ctx))
        XCTAssertFalse(matcher.matches(path: "/other/Library/Caches/foo",
                                       pattern: "~/Library/Caches/*",
                                       context: ctx))
    }

    func testMatchingWithTemplateVariable() {
        let ctx = PathMatcher.Context(home: home, variables: ["bundleId": "com.example.app"])
        XCTAssertTrue(matcher.matches(path: "\(home)/Library/Caches/com.example.app",
                                      pattern: "~/Library/Caches/{bundleId}",
                                      context: ctx))
        XCTAssertFalse(matcher.matches(path: "\(home)/Library/Caches/com.other.app",
                                       pattern: "~/Library/Caches/{bundleId}",
                                       context: ctx))
    }

    func testAnchoringPreventsPartialMatches() {
        XCTAssertFalse(matcher.matches(path: "/tmp/a/bc", pattern: "/tmp/a/b"))
        XCTAssertFalse(matcher.matches(path: "/x/tmp/a/b", pattern: "/tmp/a/b"))
    }

    // MARK: - Standardisation

    func testStandardizeStripsTrailingSlash() {
        XCTAssertEqual(matcher.standardize("/tmp/a/b/"), "/tmp/a/b")
        XCTAssertEqual(matcher.standardize("/"), "/")
    }

    func testStandardizeResolvesDotSegments() {
        XCTAssertEqual(matcher.standardize("/tmp/a/../b"), "/tmp/b")
        XCTAssertEqual(matcher.standardize("/tmp/./a"), "/tmp/a")
    }

    func testStandardizeExpandsTildeAgainstRealHome() {
        let std = matcher.standardize("~/Library")
        XCTAssertEqual(std, (NSHomeDirectory() as NSString).appendingPathComponent("Library"))
    }

    func testStandardizeCollapsesThePrivateAliasDeterministically() {
        // `NSString.standardizingPath` strips a leading `/private` only when the
        // path currently exists on disk. A safety decision built on that would
        // vary with host state, so `standardize` collapses it unconditionally.
        XCTAssertEqual(matcher.standardize("/private/var/db/receipts"), "/var/db/receipts")
        XCTAssertEqual(matcher.standardize("/private/var/folders/zz/x"), "/var/folders/zz/x")
        XCTAssertEqual(matcher.standardize("/var/db/receipts"), "/var/db/receipts")
        // Bare `/private` is a real directory, not an alias for the volume root.
        XCTAssertEqual(matcher.standardize("/private"), "/private")
    }

    func testMatchingCanonicalizesThePrivateAliasOnBothSides() {
        // The shipped quicklook-cache rule spells `/private/var/folders/**` while
        // an enumerator may report `/var/folders/**`. Both directions must match,
        // otherwise the rule silently finds nothing.
        let tail = "**/com.apple.QuickLook.thumbnailcache/**"
        let hit = "/ab/com.apple.QuickLook.thumbnailcache/x"
        XCTAssertTrue(matcher.matches(path: "/var/folders" + hit,
                                      pattern: "/private/var/folders/" + tail))
        XCTAssertTrue(matcher.matches(path: "/private/var/folders" + hit,
                                      pattern: "/var/folders/" + tail))

        // CompiledGlob must agree with one-shot matching.
        let compiled = matcher.compileAll(["/private/var/folders/" + tail])
        XCTAssertTrue(compiled.matches("/var/folders" + hit))
    }

    func testMatchingStandardizesBothSides() {
        XCTAssertTrue(matcher.matches(path: "/tmp/a/../b/c", pattern: "/tmp/b/*"))
    }

    // MARK: - CompiledGlob

    func testCompiledGlobMatchesLikeOneShotMatching() {
        let compiled = matcher.compileAll(["/tmp/cache/**/*.log", "~/Library/Caches/*"],
                                          context: context)
        XCTAssertEqual(compiled.count, 2)
        XCTAssertFalse(compiled.isEmpty)

        XCTAssertTrue(compiled.matches("/tmp/cache/a/b/x.log"))
        XCTAssertTrue(compiled.matches("\(home)/Library/Caches/foo"))
        XCTAssertFalse(compiled.matches("/tmp/cache/a/b/x.txt"))
    }

    func testEmptyCompiledGlobMatchesNothing() {
        let compiled = matcher.compileAll([], context: context)
        XCTAssertTrue(compiled.isEmpty)
        XCTAssertFalse(compiled.matches("/tmp/anything"))
    }

    func testCompiledGlobIsReusableAcrossManyPaths() {
        let compiled = matcher.compileAll(["/tmp/**/junk*"])
        for index in 0..<200 {
            XCTAssertTrue(compiled.matches("/tmp/a/b/junk\(index)"), "failed at \(index)")
        }
        XCTAssertFalse(compiled.matches("/tmp/a/b/keep0"))
    }

    // MARK: - Context helpers

    func testContextSettingReturnsNewContext() {
        let base = PathMatcher.Context(home: home, variables: ["a": "1"])
        let updated = base.setting("b", to: "2")
        XCTAssertEqual(updated.variables["a"], "1")
        XCTAssertEqual(updated.variables["b"], "2")
        XCTAssertNil(base.variables["b"], "Context must be value-typed")
    }

    func testEmptyContextUsesRealHome() {
        XCTAssertEqual(PathMatcher.Context.empty.home, NSHomeDirectory())
    }
}
