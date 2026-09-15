//
//  PathDenylistTests.swift
//  CleanMacTests
//
//  The last line of defence before anything is deleted. Verifies that SIP
//  locations, the home root, volume mount points, running app bundles, and
//  actively-written caches are all refused.
//

import XCTest
@testable import CleanMac

final class PathDenylistTests: XCTestCase {

    private let denylist = PathDenylist()
    private let home = NSHomeDirectory()

    private func rule(
        id: String = "generic.rule",
        safety: SafetyLevel = .safe,
        modifiedWithinHours: Int? = nil
    ) -> Rule {
        Rule(
            id: id,
            name: id,
            category: .caches,
            safety: safety,
            paths: ["/tmp/*"],
            modifiedWithinHours: modifiedWithinHours
        )
    }

    private func decide(
        _ path: String,
        rule: Rule? = nil,
        metadata: FileMetadata? = nil,
        runningApps: Set<String> = [],
        ownBundle: String? = nil
    ) -> PathDenylist.Decision {
        denylist.decide(
            path: path,
            metadata: metadata,
            rule: rule ?? self.rule(),
            runningAppBundlePaths: runningApps,
            ownBundlePath: ownBundle
        )
    }

    // MARK: - Allowed

    func testOrdinaryUserCacheIsAllowed() {
        XCTAssertEqual(decide("\(home)/Library/Caches/com.example.app"), .allowed)
    }

    func testTemporaryDirectoryChildIsAllowed() {
        XCTAssertEqual(decide("/private/var/folders/ab/T/com.example.app/cache.bin"), .allowed)
    }

    // MARK: - SIP / system locations

    func testSystemDirectoryIsDenied() {
        let decision = decide("/System/Library/Frameworks/AppKit.framework")
        XCTAssertEqual(decision, .denied(reason: .systemProtected))
    }

    func testUsrBinSbinAreDenied() {
        for path in ["/usr/bin/ls", "/bin/sh", "/sbin/mount"] {
            XCTAssertEqual(decide(path), .denied(reason: .systemProtected), "path: \(path)")
        }
    }

    func testEtcIsDenied() {
        XCTAssertEqual(decide("/etc/hosts"), .denied(reason: .systemProtected))
    }

    func testLibraryAppleIsDenied() {
        XCTAssertEqual(decide("/Library/Apple/System/Library/Receipts"),
                       .denied(reason: .systemProtected))
    }

    func testVarDbIsDenied() {
        XCTAssertEqual(decide("/private/var/db/receipts"), .denied(reason: .systemProtected))
    }

    func testPrivateAliasIsDeniedIdenticallyToItsCanonicalSpelling() {
        // `/private/var/db/receipts` and `/var/db/receipts` are the same place.
        // The verdict must not depend on which spelling an enumerator produced,
        // nor on whether the path currently exists on disk — `NSString`'s
        // `standardizingPath` strips `/private` only for paths that do.
        let pairs: [(aliased: String, canonical: String)] = [
            ("/private/var/db/receipts", "/var/db/receipts"),
            ("/private/var/db/SystemPolicy", "/var/db/SystemPolicy"),
            ("/private/var/folders/zz/tmp/x", "/var/folders/zz/tmp/x"),
            ("/private/etc/hosts", "/etc/hosts")
        ]
        for pair in pairs {
            XCTAssertEqual(decide(pair.aliased), decide(pair.canonical), "spelling: \(pair.aliased)")
            XCTAssertEqual(decide(pair.aliased), .denied(reason: .systemProtected),
                           "spelling: \(pair.aliased)")
        }
    }

    func testApplicationsUtilitiesIsDenied() {
        XCTAssertEqual(decide("/Applications/Utilities/Terminal.app"),
                       .denied(reason: .systemProtected))
    }

    // MARK: - Exact-match roots

    func testHomeRootIsDenied() {
        XCTAssertEqual(decide(home), .denied(reason: .homeRoot))
    }

    func testLibraryRootsAreDenied() {
        XCTAssertEqual(decide("\(home)/Library"), .denied(reason: .systemProtected))
        XCTAssertEqual(decide("/Library"), .denied(reason: .systemProtected))
    }

    func testApplicationsRootIsDeniedButChildrenAreNot() {
        XCTAssertEqual(decide("/Applications"), .denied(reason: .systemProtected))
        XCTAssertEqual(decide("/Applications/Safari.app/Contents/Info.plist"), .allowed)
    }

    func testVarAndTmpRootsAreDenied() {
        for path in ["/var", "/private/var", "/private", "/tmp"] {
            XCTAssertEqual(decide(path), .denied(reason: .systemProtected), "path: \(path)")
        }
    }

    // MARK: - Volume mount points

    func testVolumeMountPointIsDenied() {
        XCTAssertEqual(decide("/Volumes/Backup"), .denied(reason: .volumeMountPoint))
        XCTAssertEqual(decide("/Volumes/Macintosh HD"), .denied(reason: .volumeMountPoint))
        // The container itself is refused too — but exactly, never as a prefix.
        XCTAssertEqual(decide("/Volumes"), .denied(reason: .systemProtected))
    }

    func testPathsInsideAMountedVolumeAreAllowed() {
        XCTAssertEqual(decide("/Volumes/Backup/caches/old.bin"), .allowed)
    }

    // MARK: - Protected user directories

    func testProtectedUserDirectoriesAreDenied() {
        for relative in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"] {
            let path = (home as NSString).appendingPathComponent(relative)
            XCTAssertEqual(decide(path), .denied(reason: .protectedUserDirectory), "path: \(path)")
            // And everything inside them too.
            let child = (path as NSString).appendingPathComponent("important.txt")
            XCTAssertEqual(decide(child), .denied(reason: .protectedUserDirectory), "path: \(child)")
        }
    }

    func testKeychainsAndMailAreDenied() {
        XCTAssertEqual(decide("\(home)/Library/Keychains/login.keychain-db"),
                       .denied(reason: .protectedUserDirectory))
        XCTAssertEqual(decide("\(home)/Library/Mail/V10/MailData"),
                       .denied(reason: .protectedUserDirectory))
        XCTAssertEqual(decide("\(home)/Library/Messages/chat.db"),
                       .denied(reason: .protectedUserDirectory))
    }

    func testICloudDriveIsDenied() {
        XCTAssertEqual(decide("\(home)/Library/Mobile Documents/com~apple~CloudDocs"),
                       .denied(reason: .protectedUserDirectory))
    }

    // MARK: - Running applications

    func testRunningAppBundleIsDenied() {
        let running: Set<String> = ["/Applications/Safari.app"]
        XCTAssertEqual(decide("/Applications/Safari.app", runningApps: running),
                       .denied(reason: .runningApplication))
        XCTAssertEqual(decide("/Applications/Safari.app/Contents/Resources/app.asar",
                              runningApps: running),
                       .denied(reason: .runningApplication))
    }

    func testNonRunningAppBundleIsAllowed() {
        XCTAssertEqual(decide("/Applications/NotRunning.app",
                              runningApps: ["/Applications/Safari.app"]), .allowed)
    }

    func testPathSharingAPrefixWithARunningBundleIsAllowed() {
        // "/Applications/Safari Beta.app" is NOT inside "/Applications/Safari.app".
        XCTAssertEqual(decide("/Applications/Safari Beta.app/x",
                              runningApps: ["/Applications/Safari.app"]), .allowed)
    }

    // MARK: - Own bundle

    func testOwnBundleIsDenied() {
        let own = "/Applications/CleanMac.app"
        XCTAssertEqual(decide(own, ownBundle: own), .denied(reason: .ownBundle))
        XCTAssertEqual(decide("\(own)/Contents/MacOS/CleanMac", ownBundle: own),
                       .denied(reason: .ownBundle))
    }

    /// A regular file whose mtime is `age` seconds in the past (negative for a
    /// future date). Every active-cache test needs exactly this and nothing else.
    private func file(_ path: String, ageSeconds: TimeInterval) -> FileMetadata {
        FileMetadata(
            path: path,
            isDirectory: false,
            isRegularFile: true,
            isSymbolicLink: false,
            allocatedSize: 10,
            contentSize: 10,
            modificationDate: Date().addingTimeInterval(-ageSeconds)
        )
    }

    // MARK: - Active caches

    func testRecentlyModifiedCacheIsDeniedWhenRuleSetsAWindow() {
        let fresh = file("\(home)/Library/Caches/com.example.app/data", ageSeconds: 60)
        let r = rule(modifiedWithinHours: 24)
        XCTAssertEqual(decide(fresh.path, rule: r, metadata: fresh),
                       .denied(reason: .activeCache))
    }

    func testStaleCacheIsAllowedWhenRuleSetsAWindow() {
        let stale = file("\(home)/Library/Caches/com.example.app/old", ageSeconds: 72 * 3600)
        let r = rule(modifiedWithinHours: 24)
        XCTAssertEqual(decide(stale.path, rule: r, metadata: stale), .allowed)
    }

    // Spec §4: the denylist "refuses to match any path that … was modified within
    // the last 24 hours and lives in a Caches folder", and it "runs after rule
    // matching, so even a bad user-supplied rule cannot touch these paths".
    //
    // This test used to assert the opposite — that no window on the rule meant no
    // active-cache check at all — which made the protection opt-in per rule. Six
    // of the shipped cache rules (core-simulator-caches, yarn-cache,
    // homebrew-cache, pip-cache, quicklook-cache, font-cache) set no window, so a
    // file being written right now was freely offered for cleaning.
    func testFreshCacheIsDeniedEvenWhenTheRuleSetsNoWindow() {
        let fresh = file("\(home)/Library/Caches/com.example.app/data", ageSeconds: 60)
        XCTAssertEqual(decide(fresh.path, rule: rule(), metadata: fresh),
                       .denied(reason: .activeCache),
                       "The 24h cache window must be mandatory, not opt-in per rule.")
    }

    func testStaleCacheIsAllowedWhenTheRuleSetsNoWindow() {
        // The mandatory window is a recency test, not a blanket ban on caches —
        // otherwise the System Junk module would never be able to clean any.
        let stale = file("\(home)/Library/Caches/com.example.app/old", ageSeconds: 72 * 3600)
        XCTAssertEqual(decide(stale.path, rule: rule(), metadata: stale), .allowed)
    }

    func testMandatoryCacheWindowIsNotNarrowedByASmallerRuleWindow() {
        // A rule asking for a 1h window must not be able to shrink the mandatory
        // 24h one: the wider window wins.
        let twelveHoursOld = file("\(home)/Library/Caches/com.example.app/x", ageSeconds: 12 * 3600)
        XCTAssertEqual(decide(twelveHoursOld.path,
                              rule: rule(modifiedWithinHours: 1),
                              metadata: twelveHoursOld),
                       .denied(reason: .activeCache))
    }

    func testFreshFileOutsideACachesFolderIsAllowed() {
        // Guard against the fix turning into "never clean anything recent": the
        // mandatory window is scoped to Caches folders only.
        let fresh = file("\(home)/Library/Logs/com.example.app.log", ageSeconds: 60)
        XCTAssertEqual(decide(fresh.path, rule: rule(), metadata: fresh), .allowed)
    }

    func testContainerCachesAreCoveredByTheMandatoryWindow() {
        // Sandboxed apps keep a second Caches tree under their container, which a
        // plain `~/Library/Caches` prefix check would miss entirely.
        let path = "\(home)/Library/Containers/com.example.app/Data/Library/Caches/tmp.dat"
        let fresh = file(path, ageSeconds: 60)
        XCTAssertEqual(decide(path, rule: rule(), metadata: fresh),
                       .denied(reason: .activeCache))
    }

    func testFileMerelyNamedCachesIsNotTreatedAsACacheFolder() {
        // Component-wise match, so a file that happens to contain the word does
        // not acquire the protection (and, more importantly, does not lose its
        // real recency semantics). Kept out of ~/Downloads, which is denied for a
        // completely different reason and would mask what this asserts.
        let path = "\(home)/Library/Logs/Caches-old.zip"
        let fresh = file(path, ageSeconds: 60)
        XCTAssertFalse(PathDenylist.isInsideCachesFolder(PathMatcher().standardize(path)))
        XCTAssertEqual(decide(path, rule: rule(), metadata: fresh), .allowed)
    }

    func testNoMetadataMeansNoActiveCacheDecision() {
        // An unreadable entry has no mtime to judge. It must not be denied as an
        // active cache — `isReadOnly` on the ScanItem is what handles it instead.
        let path = "\(home)/Library/Caches/com.example.app/locked"
        XCTAssertEqual(decide(path, rule: rule(), metadata: nil), .allowed)
    }

    // MARK: - Allowlist exemptions

    func testExemptedRulesCanReachOtherwiseDeniedPrefixes() {
        // The shipped system-junk pack relies on a small allowlist so that
        // e.g. /Library/Caches can be cleaned while /Library/Apple cannot.
        for prefix in PathDenylist.alwaysDeniedPrefixes {
            // Every prefix must still deny a generic rule.
            let probe = "\(prefix)/probe-target"
            let decision = decide(probe)
            if decision == .allowed {
                XCTFail("Generic rule was allowed under denied prefix \(prefix)")
            }
        }
    }

    // MARK: - Static tables

    func testDeniedTablesAreAbsoluteAndNonEmpty() {
        XCTAssertFalse(PathDenylist.alwaysDeniedPrefixes.isEmpty)
        XCTAssertFalse(PathDenylist.alwaysDeniedExact.isEmpty)
        XCTAssertFalse(PathDenylist.protectedUserDirectories.isEmpty)

        for path in PathDenylist.alwaysDeniedPrefixes {
            XCTAssertTrue(path.hasPrefix("/"), "prefix must be absolute: \(path)")
            XCTAssertFalse(path.hasSuffix("/"), "prefix must not carry a trailing slash: \(path)")
        }
        for path in PathDenylist.protectedUserDirectories {
            XCTAssertTrue(path.hasPrefix("/"), "protected dirs must already be expanded: \(path)")
            XCTAssertFalse(path.contains("~"), "tilde should have been expanded: \(path)")
        }
    }

    func testRootPrefixIsNeverAppliedLiterally() {
        // "/" is denied exactly, never as a prefix — applying it as a prefix
        // would refuse every path on the machine. Make sure that doesn't happen.
        XCTAssertEqual(decide("/"), .denied(reason: .systemProtected))
        XCTAssertEqual(decide("\(home)/Library/Caches/com.example.app"), .allowed)
    }
}
