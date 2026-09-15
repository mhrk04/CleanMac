//
//  Rule.swift
//  CleanMac
//
//  The unit of cleaning logic. Rules are loaded from YAML rule packs and
//  consumed by the ScannerEngine. Rules describe *what* to match; the
//  engine decides *how*.
//

import Foundation

/// How eager the UI should be about pre-checking this rule's matches.
public enum SafetyLevel: String, Sendable, Codable, CaseIterable {
    /// Always safe to remove. Pre-checked in the UI.
    case safe
    /// Usually safe but the user should read the description first.
    /// Unchecked by default with a warning badge.
    case review
    /// Almost never safe to remove automatically. Hidden unless the user
    /// enables "Show advanced rules" in Settings.
    case dangerous

    public var isPreselected: Bool { self == .safe }
}

/// Specialised handling that cannot be expressed as a plain glob match.
/// Extend this enum + `ScannerEngine.specializedHandler(for:)` to add more.
public enum RuleStrategy: String, Sendable, Codable {
    /// Keep .lproj directories whose language is not in the user's active set.
    case languageFilter
    /// Enumerate `.Trashes` on every mounted volume.
    case trashBins
    /// Login items whose target app no longer exists.
    case brokenLoginItems
    /// APFS local Time Machine snapshots — reported read-only.
    case tmutilSnapshots
}

/// The category a rule belongs to. Drives UI grouping and iconography.
public struct RuleCategory: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }

    public static let caches = RuleCategory(rawValue: "caches")
    public static let logs = RuleCategory(rawValue: "logs")
    public static let languages = RuleCategory(rawValue: "languages")
    public static let developer = RuleCategory(rawValue: "developer")
    public static let trash = RuleCategory(rawValue: "trash")
    public static let mail = RuleCategory(rawValue: "mail")
    public static let backups = RuleCategory(rawValue: "backups")
    public static let other = RuleCategory(rawValue: "other")

    // Uninstaller categories
    public static let application = RuleCategory(rawValue: "application")
    public static let support = RuleCategory(rawValue: "support")
    public static let containers = RuleCategory(rawValue: "containers")
    public static let preferences = RuleCategory(rawValue: "preferences")
    public static let launchItems = RuleCategory(rawValue: "launchitems")
    public static let state = RuleCategory(rawValue: "state")
    public static let helpers = RuleCategory(rawValue: "helpers")
    public static let plugins = RuleCategory(rawValue: "plugins")

    /// SF Symbol name used in the UI for this category.
    public var symbolName: String {
        switch rawValue {
        case "caches": return "externaldrive.badge.timemachine"
        case "logs": return "doc.text.magnifyingglass"
        case "languages": return "globe"
        case "developer": return "hammer"
        case "trash": return "trash"
        case "mail": return "envelope"
        case "backups": return "externaldrive.badge.checkmark"
        case "application": return "app.dashed"
        case "support": return "folder"
        case "containers": return "shippingbox"
        case "preferences": return "slider.horizontal.3"
        case "launchitems": return "play.circle"
        case "state": return "rectangle.on.rectangle"
        case "helpers": return "wrench.and.screwdriver"
        case "plugins": return "puzzlepiece.extension"
        default: return "questionmark.folder"
        }
    }

    /// Human-readable name for section headers.
    ///
    /// Localized because it is rendered verbatim as a section title. An
    /// unmapped raw value falls back to its capitalised identifier, which is
    /// a machine string and deliberately left untranslated.
    public var displayName: String {
        switch rawValue {
        case "caches": return L10n.string("Cache Files")
        case "logs": return L10n.string("Log Files")
        case "languages": return L10n.string("Language Files")
        case "developer": return L10n.string("Developer Files")
        case "trash": return L10n.string("Trash")
        case "mail": return L10n.string("Mail")
        case "backups": return L10n.string("Backups")
        case "application": return L10n.string("Application")
        case "support": return L10n.string("Application Support")
        case "containers": return L10n.string("Containers")
        case "preferences": return L10n.string("Preferences")
        case "launchitems": return L10n.string("Launch Items")
        case "state": return L10n.string("Saved State")
        case "helpers": return L10n.string("Helpers & Receipts")
        case "plugins": return L10n.string("Plug-ins")
        default: return rawValue.capitalized
        }
    }
}

/// A single rule from a rule pack.
public struct Rule: Identifiable, Hashable, Sendable, Codable {
    /// The `keepLanguages` token meaning "whatever the user's system is set to".
    public static let activeLanguagesToken = "active"

    public var id: String
    public var name: String
    public var category: RuleCategory
    public var safety: SafetyLevel
    public var paths: [String]
    public var excludes: [String]
    public var strategy: RuleStrategy?
    public var modifiedWithinHours: Int?
    /// Languages the `languageFilter` strategy must never remove.
    ///
    /// The token `active` is resolved at scan time to the user's
    /// `AppleLanguages`; any other entry is a literal language code. Keeping
    /// this data-driven is the point of the field: a rule pack can widen or
    /// narrow what counts as "in use" without a new binary.
    public var keepLanguages: [String]?
    public var description: String?
    /// Which pack this rule came from — used for grouping in Settings.
    public var packName: String?

    public init(
        id: String,
        name: String,
        category: RuleCategory,
        safety: SafetyLevel,
        paths: [String],
        excludes: [String] = [],
        strategy: RuleStrategy? = nil,
        modifiedWithinHours: Int? = nil,
        keepLanguages: [String]? = nil,
        description: String? = nil,
        packName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.safety = safety
        self.paths = paths
        self.excludes = excludes
        self.strategy = strategy
        self.modifiedWithinHours = modifiedWithinHours
        self.keepLanguages = keepLanguages
        self.description = description
        self.packName = packName
    }

    /// Whether the rule requires a specialised handler rather than plain
    /// glob matching.
    public var isSpecialized: Bool { strategy != nil }

    /// `keepLanguages` with the safe default applied.
    ///
    /// An absent or empty list means `["active"]`, never `[]`. A rule that
    /// forgets the key must not become a rule that deletes every language the
    /// user actually reads.
    public var effectiveKeepLanguages: [String] {
        guard let keepLanguages, !keepLanguages.isEmpty else { return [Self.activeLanguagesToken] }
        return keepLanguages
    }
}
