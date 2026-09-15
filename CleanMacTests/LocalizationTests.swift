//
//  LocalizationTests.swift
//  CleanMacTests
//
//  Two kinds of test live here.
//
//  The first group exercises `L10n` at runtime: the natural-key fallback that
//  makes an untranslated entry correct, `%@` substitution, positional
//  reordering, plural selection, and the deliberate absence of thousands
//  grouping.
//
//  The second group reads the source tree and the catalog off disk and asserts
//  the invariants that keep them from drifting apart. Those matter because the
//  failure mode is silent: a key missing from `Localizable.xcstrings` still
//  renders fine in English, so nothing looks wrong until a translator is added
//  and one string mysteriously refuses to change.
//

import XCTest
@testable import CleanMac

// MARK: - Source scanner

/// Reads every `L10n` call site out of the app's source tree.
///
/// This deliberately mirrors `.verify/genstrings.py`: that script *writes*
/// `Localizable.xcstrings`, these tests *police* it. Keeping a scanner here
/// means the invariants are enforced by `xcodebuild test` rather than only by a
/// script someone has to remember to run, and any divergence between the two
/// surfaces as a failing test instead of a quietly incomplete catalog.
///
/// It is a hand-written scanner rather than a regex because Swift string
/// literals nest: an interpolation hole can contain another literal, and a
/// literal can contain the characters that would otherwise terminate a comment
/// or split an argument list.
enum LocalizationScanner {

    /// One argument of one `L10n` call.
    struct Site {
        let file: String
        let line: Int
        /// `"string"`, `"plural"` or `"verbatim"`.
        let kind: String
        /// Which argument the key was read from. `plural` contributes two.
        let argument: Int
        /// `nil` when the argument is not a bare string literal.
        let key: String?
        /// The raw argument text, for failure messages.
        let snippet: String

        /// `verbatim` never produces a catalog entry, so it is not a site that
        /// can be "unresolved" by having a computed argument.
        var isKeyBearing: Bool { kind != "verbatim" }
    }

    static func sites() throws -> [Site] {
        var out: [Site] = []
        for path in try swiftFiles(under: TestResources.appSourceDirectory) {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let source = stripComments(Array(text))
            out.append(contentsOf: scan(source, file: path))
        }
        return out
    }

    /// Keys contributed by `string` and `plural` calls.
    static func keys() throws -> Set<String> {
        Set(try sites().filter(\.isKeyBearing).compactMap(\.key))
    }

    // MARK: Scanning

    private static let marker = Array("L10n")
    private static let kinds = ["string", "plural", "verbatim"]

    private static func scan(_ s: [Character], file: String) -> [Site] {
        var out: [Site] = []
        var index = 0
        // `index` only ever moves forward, so the line number can be tracked
        // incrementally instead of recounting newlines at every hit.
        var line = 1
        var lineCursor = 0

        func advanceLine(to position: Int) {
            while lineCursor < position && lineCursor < s.count {
                if s[lineCursor] == "\n" { line += 1 }
                lineCursor += 1
            }
        }

        while index < s.count {
            guard matches(s, index, marker),
                  !isIdentifierCharacter(at: index - 1, in: s) else {
                index += 1
                continue
            }
            var j = skipWhitespace(s, index + marker.count)
            guard j < s.count, s[j] == "." else { index += 1; continue }
            j = skipWhitespace(s, j + 1)
            guard let kind = kinds.first(where: { matches(s, j, Array($0)) }) else {
                index += 1
                continue
            }
            j = skipWhitespace(s, j + kind.count)
            guard j < s.count, s[j] == "(" else { index += 1; continue }

            advanceLine(to: index)
            let arguments = splitArguments(s, openParenAt: j)
            // `plural` looks up BOTH of its forms at runtime, so both are keys.
            let slots = (kind == "plural") ? 2 : 1
            for slot in 0..<slots {
                let raw = slot < arguments.count ? arguments[slot] : []
                out.append(Site(
                    file: file,
                    line: line,
                    kind: kind,
                    argument: slot,
                    key: literalKey(raw),
                    snippet: collapsed(String(raw))
                ))
            }
            index = j
        }
        return out
    }

    private static func swiftFiles(under root: String) throws -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var paths: [String] = []
        while let relative = walker.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            paths.append((root as NSString).appendingPathComponent(relative))
        }
        return paths.sorted()
    }

    // MARK: Lexing helpers

    /// Blanks out `//` and `/* */` comments while preserving every offset, so
    /// line numbers computed against the result stay truthful. A comment that
    /// merely mentions `L10n` must not be mistaken for a call site.
    private static func stripComments(_ s: [Character]) -> [Character] {
        var out = s
        var i = 0
        while i < s.count {
            if s[i] == "\"" {
                i = skipString(s, i)
            } else if s[i] == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { out[i] = " "; i += 1 }
            } else if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i < s.count {
                    if s[i] == "*", i + 1 < s.count, s[i + 1] == "/" { i += 2; break }
                    if s[i] != "\n" { out[i] = " " }
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return out
    }

    /// Index just past the string literal beginning at `start`.
    private static func skipString(_ s: [Character], _ start: Int) -> Int {
        guard start < s.count, s[start] == "\"" else { return start }
        var i = start + 1
        while i < s.count {
            if s[i] == "\\", i + 1 < s.count, s[i + 1] == "(" {
                i = skipInterpolation(s, openParenAt: i + 1)
                continue
            }
            if s[i] == "\\" { i += 2; continue }
            if s[i] == "\"" { return i + 1 }
            i += 1
        }
        return s.count
    }

    /// `openParenAt` is the index of the `(` that opens an interpolation hole.
    private static func skipInterpolation(_ s: [Character], openParenAt open: Int) -> Int {
        var depth = 0
        var i = open
        while i < s.count {
            if s[i] == "(" {
                depth += 1
            } else if s[i] == ")" {
                depth -= 1
                if depth == 0 { return i + 1 }
            } else if s[i] == "\"" {
                i = skipString(s, i)
                continue
            }
            i += 1
        }
        return s.count
    }

    /// Arguments of the call whose `(` sits at `open`. The outer parens are not
    /// part of any argument, and only commas at the call's own nesting level
    /// separate them.
    private static func splitArguments(_ s: [Character], openParenAt open: Int) -> [[Character]] {
        guard open < s.count, s[open] == "(" else { return [] }
        var i = open + 1
        var depth = 1
        var args: [[Character]] = []
        var current: [Character] = []
        while i < s.count {
            let c = s[i]
            if c == "\"" {
                let end = skipString(s, i)
                current.append(contentsOf: s[i..<end])
                i = end
                continue
            }
            if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 { args.append(current); return args }
            } else if c == ",", depth == 1 {
                args.append(current)
                current = []
                i += 1
                continue
            }
            current.append(c)
            i += 1
        }
        return args
    }

    /// The unescaped value of `argument` when it is a bare string literal.
    ///
    /// Returns `nil` for anything else, including an *interpolated* literal:
    /// `L10n.string("Hello \(name)")` has no fixed key, so it can never appear
    /// in a catalog and is reported as unresolved rather than silently
    /// contributing a nonsense entry.
    private static func literalKey(_ argument: [Character]) -> String? {
        var trimmed = argument
        while let first = trimmed.first, first.isWhitespace { trimmed.removeFirst() }
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        guard trimmed.first == "\"" else { return nil }
        guard skipString(trimmed, 0) == trimmed.count else { return nil }
        let raw = String(trimmed)
        guard !raw.contains("\\(") else { return nil }
        return unescape(raw)
    }

    private static func unescape(_ raw: String) -> String {
        let body = raw.dropFirst().dropLast()
        var out = ""
        var i = body.startIndex
        while i < body.endIndex {
            guard body[i] == "\\" else { out.append(body[i]); i = body.index(after: i); continue }
            let next = body.index(after: i)
            guard next < body.endIndex else { out.append(body[i]); break }
            switch body[next] {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case let c: out.append(c)
            }
            i = body.index(after: next)
        }
        return out
    }

    private static func skipWhitespace(_ s: [Character], _ i: Int) -> Int {
        var j = i
        while j < s.count, s[j].isWhitespace { j += 1 }
        return j
    }

    private static func matches(_ s: [Character], _ i: Int, _ token: [Character]) -> Bool {
        guard i >= 0, i + token.count <= s.count else { return false }
        for offset in 0..<token.count where s[i + offset] != token[offset] { return false }
        return true
    }

    private static func isIdentifierCharacter(at i: Int, in s: [Character]) -> Bool {
        guard i >= 0, i < s.count else { return false }
        return s[i].isLetter || s[i].isNumber || s[i] == "_"
    }

    private static func collapsed(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}

// MARK: - Catalog reader

/// The compiled-form-independent view of `Localizable.xcstrings` these tests
/// need: which keys exist, what English value each maps to, and its state.
struct StringCatalog {
    struct Entry {
        let value: String
        let state: String
    }

    let sourceLanguage: String
    let version: String
    let entries: [String: Entry]

    var keys: Set<String> { Set(entries.keys) }

    static func load() throws -> StringCatalog {
        let url = URL(fileURLWithPath: TestResources.catalogPath)
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "catalog root is not a JSON object"
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any], "catalog has no \"strings\"")

        var entries: [String: Entry] = [:]
        for (key, value) in strings {
            let entry = value as? [String: Any]
            let english = entry?["localizations"] as? [String: Any]
            let unit = ((english?["en"] as? [String: Any])?["stringUnit"]) as? [String: Any]
            entries[key] = Entry(
                value: unit?["value"] as? String ?? "",
                state: unit?["state"] as? String ?? ""
            )
        }
        return StringCatalog(
            sourceLanguage: root["sourceLanguage"] as? String ?? "",
            version: root["version"] as? String ?? "",
            entries: entries
        )
    }
}

// MARK: - Tests

final class LocalizationTests: XCTestCase {

    // MARK: Runtime behaviour

    func testMissingKeyFallsBackToTheKeyItself() {
        // The natural-key guarantee: with no table entry the key is returned
        // unchanged, so English is correct with no translation installed.
        let key = "A Key That Is Definitely Not In Any Catalog"
        XCTAssertEqual(L10n.string(key), key)
    }

    func testCataloguedKeyReturnsItsEnglishText() {
        // True whether or not the catalog is loaded, because every entry's
        // value equals its own key. That is the point of natural keys.
        XCTAssertEqual(L10n.string("System Junk"), "System Junk")
        XCTAssertEqual(L10n.string("Move to Trash"), "Move to Trash")
    }

    func testSubstitutesObjectPlaceholder() {
        XCTAssertEqual(L10n.string("%@ items found", "42"), "42 items found")
    }

    func testSubstitutesSeveralPlaceholdersInOrder() {
        XCTAssertEqual(
            L10n.string("%@ of %@ items", "7", "20"),
            "7 of 20 items"
        )
    }

    func testPositionalPlaceholdersCanReorderArguments() {
        // A translation is free to put the arguments in whatever order its
        // language needs; the call site does not change.
        XCTAssertEqual(
            L10n.string("%2$@ before %1$@", "first", "second"),
            "second before first"
        )
    }

    func testEscapedPercentSurvivesSubstitution() {
        XCTAssertEqual(L10n.string("Scanning — %@%%", "42"), "Scanning — 42%")
    }

    func testNumericArgumentsAreNotThousandsGrouped() {
        // Locks in `locale: nil`. With `Locale.current` Foundation decorates
        // numeric conversions with grouping separators and the progress counter
        // "0/1234567" turns into "0/1,234,567".
        XCTAssertEqual(
            L10n.string("%@/%@ items processed", "0", "1234567"),
            "0/1234567 items processed"
        )
    }

    func testPluralSelectsSingularForOne() {
        XCTAssertEqual(L10n.plural("%@ item", "%@ items", 1), "1 item")
    }

    func testPluralSelectsPluralFormForZeroAndMany() {
        XCTAssertEqual(L10n.plural("%@ item", "%@ items", 0), "0 items")
        XCTAssertEqual(L10n.plural("%@ item", "%@ items", 2), "2 items")
        XCTAssertEqual(L10n.plural("%@ item", "%@ items", 1_000), "1000 items")
    }

    func testVerbatimIsIdentity() {
        // Copy that must never be translated: paths, bundle ids, app names.
        XCTAssertEqual(L10n.verbatim("/Applications/Mail.app"), "/Applications/Mail.app")
        XCTAssertEqual(L10n.verbatim("Mail"), "Mail")
    }

    func testLooksUpFromTheMainBundle() {
        XCTAssertEqual(L10n.bundle, Bundle.main)
    }

    // MARK: Key hygiene

    func testNoKeyUsesANumericConversionSpecifier() throws {
        // `%@` is the only permitted placeholder. `String(format:)` reads it as
        // an Objective-C object pointer, so pairing it with a Swift `Int` or
        // `Double` dereferences garbage and dies with SIGSEGV -- no compile
        // error, no warning, just a crash the first time that branch runs.
        // `L10n.string`'s `String...` signature makes that unrepresentable at
        // the call site; this makes it unrepresentable in the key space too.
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")

        let offenders = try LocalizationScanner.keys()
            .filter { !invalidPercentSpecifiers(in: $0).isEmpty }
            .sorted()
        XCTAssertTrue(
            offenders.isEmpty,
            "keys must use only %@, positional %N$@ or %%; offenders: \(offenders)"
        )
    }

    func testNoKeyIsEmpty() throws {
        // An empty string is an absent label, not copy. Turning one into a
        // lookup key invents a translatable entry for nothing.
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")

        let empty = try LocalizationScanner.sites()
            .filter(\.isKeyBearing)
            .filter { $0.key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false }
        XCTAssertTrue(empty.isEmpty, "empty localization keys: \(describe(empty))")
    }

    func testEveryKeyCallSiteUsesALiteral() throws {
        // A computed key cannot exist in a catalog, so it can never be
        // translated. Every site must pass a literal.
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")

        let unresolved = try LocalizationScanner.sites().filter { $0.isKeyBearing && $0.key == nil }
        XCTAssertTrue(unresolved.isEmpty, "non-literal keys: \(describe(unresolved))")
    }

    func testEveryPluralCallSiteHasTwoLiteralForms() throws {
        // `plural` looks up whichever form the count selects, so BOTH must be
        // literal and BOTH must reach the catalog. Reading only the first
        // argument -- the obvious implementation -- silently drops every plural
        // form from the table.
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")

        let sites = try LocalizationScanner.sites()
        let pluralSites = sites.filter { $0.kind == "plural" }
        XCTAssertFalse(pluralSites.isEmpty, "no plural call sites found; the scanner has regressed")

        let unresolved = pluralSites.filter { $0.key == nil }
        XCTAssertTrue(unresolved.isEmpty, "plural sites with a non-literal form: \(describe(unresolved))")

        // Each call contributes exactly two sites (argument 0 and argument 1).
        let byLocation = Dictionary(grouping: pluralSites) { "\($0.file):\($0.line)" }
        let incomplete = byLocation.filter { Set($0.value.map(\.argument)) != Set([0, 1]) }
        XCTAssertTrue(
            incomplete.isEmpty,
            "plural calls missing a form: \(incomplete.keys.sorted())"
        )
    }

    // MARK: Catalog parity

    func testCatalogExistsAndParses() throws {
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: TestResources.catalogPath),
            "missing \(TestResources.catalogPath); run .verify/genstrings.py --write"
        )
        let catalog = try StringCatalog.load()
        XCTAssertEqual(catalog.version, "1.0")
        XCTAssertFalse(catalog.entries.isEmpty, "catalog has no entries")
    }

    func testCatalogIsEnglishSourced() throws {
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")
        let catalog = try StringCatalog.load()
        XCTAssertEqual(catalog.sourceLanguage, "en")
    }

    func testCatalogCoversEveryKeyUsedInSource() throws {
        // The invariant `L10n.swift`'s header promises. A key that is used in
        // source but absent from the catalog still renders correctly in
        // English, so nothing else would ever catch it.
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")

        let catalog = try StringCatalog.load()
        let used = try LocalizationScanner.keys()
        let missing = used.subtracting(catalog.keys).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "\(missing.count) key(s) used in source but absent from the catalog "
                + "(run .verify/genstrings.py --write): \(missing.prefix(10))"
        )
    }

    func testCatalogHasNoStaleKeys() throws {
        // The converse: an entry nobody looks up is dead weight for a
        // translator and a sign the catalog was not regenerated after a rename.
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")

        let catalog = try StringCatalog.load()
        let used = try LocalizationScanner.keys()
        let stale = catalog.keys.subtracting(used).sorted()
        XCTAssertTrue(
            stale.isEmpty,
            "\(stale.count) catalog key(s) no longer used in source: \(stale.prefix(10))"
        )
    }

    func testEveryCatalogValueEqualsItsKey() throws {
        // Natural keys: the English text IS the key. If an entry's value ever
        // diverges, the app shows the value while the source reads the key, and
        // the two stop being interchangeable.
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")

        let divergent = try StringCatalog.load().entries
            .filter { $0.value.value != $0.key }
            .map { "\($0.key) -> \($0.value.value)" }
            .sorted()
        XCTAssertTrue(divergent.isEmpty, "entries whose value differs from their key: \(divergent.prefix(10))")
    }

    func testEveryCatalogEntryIsMarkedTranslated() throws {
        // Anything else makes Xcode report the string as needing translation,
        // which for a source-language entry is simply wrong.
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")

        let untranslated = try StringCatalog.load().entries
            .filter { $0.value.state != "translated" }
            .map(\.key)
            .sorted()
        XCTAssertTrue(untranslated.isEmpty, "entries not marked translated: \(untranslated.prefix(10))")
    }

    func testNoCatalogKeyUsesANumericConversionSpecifier() throws {
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")

        let offenders = try StringCatalog.load().keys
            .filter { !invalidPercentSpecifiers(in: $0).isEmpty }
            .sorted()
        XCTAssertTrue(offenders.isEmpty, "catalog keys with an illegal specifier: \(offenders.prefix(10))")
    }

    // MARK: Build wiring

    func testCatalogIsWiredIntoTheBuild() throws {
        // An `.xcstrings` file that is not a member of the resources build phase
        // is never compiled into the bundle, so every lookup falls back to the
        // key and the app ships with no translations at all -- while still
        // looking perfectly correct in English.
        try XCTSkipUnless(TestResources.isSourceAvailable, "Source tree not present in this checkout")

        let path = (TestResources.repositoryRoot as NSString).appendingPathComponent("project.yml")
        let spec = try String(contentsOfFile: path, encoding: .utf8)

        XCTAssertTrue(
            spec.contains("CleanMac/Resources/Localizable.xcstrings"),
            "project.yml does not reference the string catalog"
        )
        // Listed under `resources:`, and excluded from `sources:` so XcodeGen
        // does not add the same file to the target twice.
        let resources = spec.range(of: "resources:")
        XCTAssertNotNil(resources, "project.yml has no resources section")
        if let resources {
            let tail = spec[resources.lowerBound...]
            XCTAssertTrue(
                tail.contains("Localizable.xcstrings"),
                "the catalog is not listed under resources:"
            )
        }
        XCTAssertTrue(
            spec.contains("\"Resources/Localizable.xcstrings\""),
            "the catalog must be excluded from sources: to avoid a duplicate build file"
        )
        XCTAssertTrue(
            spec.contains("LOCALIZATION_PREFERS_STRING_CATALOGS: YES"),
            "string catalogs are not preferred over legacy .strings folders"
        )
    }

    // MARK: Helpers

    /// Every `%` in `key` that does not begin a permitted conversion specifier.
    private func invalidPercentSpecifiers(in key: String) -> [String] {
        let chars = Array(key)
        var bad: [String] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "%" else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j].isNumber { j += 1 }      // positional digits
            if j > i + 1, j < chars.count, chars[j] == "$" { j += 1 }
            let isObject = j < chars.count && chars[j] == "@"
            let isLiteralPercent = j == i + 1 && j < chars.count && chars[j] == "%"
            if isObject || isLiteralPercent { i = j + 1; continue }
            bad.append(String(chars[i..<min(i + 4, chars.count)]))
            i += 1
        }
        return bad
    }

    private func describe(_ sites: [LocalizationScanner.Site]) -> String {
        sites
            .map { "\(($0.file as NSString).lastPathComponent):\($0.line) L10n.\($0.kind) arg#\($0.argument) \($0.snippet)" }
            .joined(separator: "; ")
    }
}
