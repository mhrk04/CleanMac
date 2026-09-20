//
//  BundledResourcesTests.swift
//  CleanMacTests
//
//  Bug 1 — "Rules could not be loaded".
//
//  Unlike TestResources (which loads YAML from the SOURCE tree), these tests
//  resolve resources from the built APP bundle exactly the way the running app
//  does. The test target's TEST_HOST is CleanMac.app, so a type from the app
//  module (`SettingsStore`) yields the app bundle via `Bundle(for:)`. If the
//  YAML packs and string catalog are not copied into
//  `CleanMac.app/Contents/Resources/`, these tests fail — surfacing the
//  packaging defect that the source-tree tests cannot see.
//

import XCTest
@testable import CleanMac

final class BundledResourcesTests: XCTestCase {

    /// The built app bundle. `SettingsStore` is a `public final class` in the
    /// app module, so `Bundle(for:)` on it is the reliable app-bundle handle
    /// (matching how the shipped app resolves `Bundle.main`).
    private var appBundle: Bundle {
        Bundle(for: SettingsStore.self)
    }

    /// Mirror `RuleLoader.loadBundled(named:)` resolution: `Rules/<name>.yaml`
    /// first, flat `<name>.yaml` second.
    private func resolvedURL(for name: String) -> URL? {
        appBundle.url(forResource: name, withExtension: "yaml", subdirectory: "Rules")
            ?? appBundle.url(forResource: name, withExtension: "yaml")
    }

    func testBundledRulePacksArePresentInAppBundle() {
        for name in RulePackName.allBundled {
            XCTAssertNotNil(
                resolvedURL(for: name),
                "Bundled rule pack '\(name).yaml' is not present in the app bundle at Contents/Resources/ (neither Rules/ subdirectory nor flat)."
            )
        }
    }

    func testBundledRulePacksLoadFromAppBundle() {
        let loader = RuleLoader(
            bundle: appBundle,
            fileSystem: LiveFileSystem(),
            userRulesDirectory: "/nonexistent"
        )
        for name in RulePackName.allBundled {
            do {
                let pack = try loader.loadBundled(named: name)
                XCTAssertTrue(
                    !pack.rules.isEmpty || (pack.defaults?.isEmpty == false),
                    "Loaded pack '\(name)' from the app bundle but it has no rules and no defaults."
                )
            } catch {
                XCTFail("loadBundled(named: \"\(name)\") threw from the app bundle: \(error)")
            }
        }
    }

    func testStringCatalogIsPresentInAppBundle() {
        // Xcode COMPILES Localizable.xcstrings into a per-locale
        // `<lang>.lproj/Localizable.strings` table; the raw `.xcstrings` is a
        // source artifact and is not (and should not be) shipped verbatim.
        // `L10n` reads strings at runtime via `String(localized:bundle:)` on
        // `Bundle.main`, so the runtime-correct assertion is that the compiled
        // catalog ships in resolvable form — a `Localizable.strings` table the
        // app bundle can locate. On the unfixed build the catalog was absent
        // entirely (Resources/ held only Assets.car), so this failed too.
        let compiled = appBundle.url(
            forResource: "Localizable",
            withExtension: "strings"
        ) ?? appBundle.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: "en"
        )
        // Fall back to the raw catalog in case a toolchain ships it un-compiled.
        let raw = appBundle.url(forResource: "Localizable", withExtension: "xcstrings")
        XCTAssertTrue(
            compiled != nil || raw != nil,
            "No Localizable string catalog (compiled Localizable.strings or raw Localizable.xcstrings) is present in the app bundle."
        )
    }
}
