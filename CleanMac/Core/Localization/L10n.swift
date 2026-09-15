//
//  L10n.swift
//  CleanMac
//
//  Single entry point for every string a user can read. English is the source
//  language and the English text doubles as the lookup key ("natural keys"),
//  so an un-translated entry falls back to the key itself and the app is
//  correct with no translation table installed at all.
//
//  Adding a locale is therefore purely mechanical: drop a `<lang>.lproj`
//  folder containing `Localizable.strings` (or add a column to
//  `Localizable.xcstrings`), translate the keys, and not one call site
//  changes. `.verify/`-style CI parity is enforced by
//  `LocalizationTests.testCatalogCoversEveryKeyUsedInSource`.
//
//  Why a facade instead of leaning on SwiftUI alone:
//
//  SwiftUI's `Text`, `Button`, `Label`, `.navigationTitle`, `.help` and
//  `TextField` all accept a `LocalizedStringKey` and look *literals* up
//  automatically. That convenience evaporates the moment the copy is computed
//  at runtime — `Text(viewModel.statusLine)` takes the `StringProtocol`
//  overload and renders the value verbatim, with no lookup and no warning.
//  Almost all of this app's interesting copy is computed (progress lines,
//  byte counts, pluralised item counts, trash errors, history labels), so
//  every user-facing string is funnelled through here instead. That makes the
//  guarantee uniform, greppable, and independent of which SwiftUI initializer
//  an overload-resolution happened to pick.
//

import Foundation

public enum L10n {

    // MARK: - Lookup

    /// Localize a key with no substitutions.
    ///
    /// The key is the English text itself. When no table entry exists the key
    /// is returned unchanged, which is exactly the English-only MVP behaviour.
    public static func string(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: bundle, comment: nil)
    }

    /// Localize a key carrying `%@` placeholders, then substitute.
    ///
    /// Arguments are `String` **only**, and the only permitted placeholder is
    /// `%@` (use `%%` for a literal percent). This is a deliberate constraint,
    /// not a stylistic one: `String(format:)` reads a `%@` conversion as an
    /// Objective-C object pointer, so passing a Swift `Int` or `Double` for it
    /// dereferences garbage and dies with `SIGSEGV` — no compile error, no
    /// warning, just a crash the first time that branch runs. Typing the
    /// parameter as `String...` turns that entire class of runtime crash into
    /// a compile error at the call site. `LocalizationTests` additionally
    /// asserts no key anywhere in the app uses a numeric conversion specifier.
    ///
    /// Stringify numbers at the call site: `string("%@ items", "\(count)")`.
    /// Placeholders may be positional (`%1$@`) so a translation can reorder
    /// them for a language with different word order.
    public static func string(_ key: String, _ arguments: String...) -> String {
        String(format: string(key), locale: nil, arguments: arguments)
    }

    /// Localize a count, picking the correct English plural form.
    ///
    /// Both arguments are full natural keys containing exactly one `%@`,
    /// e.g. `plural("%@ item", "%@ items", count)`. Selecting the form in
    /// Swift rather than relying on a `%@ item;%@ items` compound key is
    /// deliberate: compound `.stringsdict` syntax is only resolved *inside* a
    /// real plural table, so with no table installed `String(format:)` would
    /// consume the count twice and emit garbage for the second half.
    ///
    /// Languages with more than two plural forms (Polish, Arabic, …) get them
    /// by attaching `variations.plural` to these same keys in the catalog —
    /// the call sites do not change.
    public static func plural(_ singular: String, _ plural: String, _ count: Int) -> String {
        string(count == 1 ? singular : plural, String(count))
    }

    // MARK: - Non-localized text

    /// Copy that must never be translated: file paths, bundle identifiers,
    /// app names read off disk, version strings, byte figures.
    ///
    /// In SwiftUI pass the result to `Text(verbatim:)` so the value is not
    /// re-interpreted as a `LocalizedStringKey` — an app named "Mail" would
    /// otherwise be looked up as a key.
    public static func verbatim(_ value: String) -> String { value }

    // MARK: - Configuration

    /// Bundle holding `Localizable.xcstrings`.
    ///
    /// A `let` on purpose. Localizing is a pure read of an immutable bundle, so
    /// it is safe to call from any actor without synchronisation; making it
    /// settable would put a lock on every string in the app for no benefit.
    /// The English fallback is observable with no table installed at all, and
    /// catalog/source parity is checked by reading the `.xcstrings` directly.
    public static let bundle: Bundle = .main

    // Substitutions deliberately pass `locale: nil` (the C locale). With
    // `Locale.current`, Foundation decorates numeric conversions with
    // thousands separators, turning the counter "0/40" into "0/1,234,567"-style
    // output that reads worse in a progress line and differs from the plain
    // interpolation it replaces. Every numeric figure in this app is either
    // such a counter or already rendered by `ByteCount`, so locale-aware number
    // grouping is never wanted here. A translation needing it can spell the
    // grouping out in its own catalog entry.
}
