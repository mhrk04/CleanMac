//
//  ScanItem.swift
//  CleanMac
//
//  The result of a single rule match — one filesystem entry the user may
//  choose to clean.
//

import Foundation

public struct ScanItem: Identifiable, Hashable, Sendable {
    /// Stable identity across scans: path + rule id. Two items from different
    /// rules that happen to point at the same path are distinct entries.
    public var id: String { "\(ruleID)|\(path)" }

    /// Absolute, standardised path.
    public let path: String
    /// Display name (last path component).
    public let name: String
    /// Rule that produced this item.
    public let ruleID: String
    /// Human-readable rule name for the UI.
    public let ruleName: String
    /// Category bucket.
    public let category: RuleCategory
    /// Safety level inherited from the rule.
    public let safety: SafetyLevel
    /// Allocated size on disk, in bytes.
    public let size: Int64
    /// True when the entry is a directory (including bundles).
    public let isDirectory: Bool
    /// Modification time, when known.
    public let modificationDate: Date?
    /// Content access time (last opened), when known.
    public let contentAccessDate: Date?
    /// Optional human-readable note (e.g. "requires admin", "app is running").
    public var annotation: String?
    /// When true, the cleaner should refuse to touch this item even if the
    /// user checks it. Set by the safety layer.
    public var isReadOnly: Bool
    /// Whether the item was pre-selected in the UI when first displayed.
    /// Defaults to the rule's `safety.isPreselected`.
    public var isSelectedByDefault: Bool

    public init(
        path: String,
        name: String? = nil,
        ruleID: String,
        ruleName: String,
        category: RuleCategory,
        safety: SafetyLevel,
        size: Int64,
        isDirectory: Bool,
        modificationDate: Date? = nil,
        contentAccessDate: Date? = nil,
        annotation: String? = nil,
        isReadOnly: Bool = false,
        isSelectedByDefault: Bool? = nil
    ) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.category = category
        self.safety = safety
        self.size = size
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.contentAccessDate = contentAccessDate
        self.annotation = annotation
        self.isReadOnly = isReadOnly
        self.isSelectedByDefault = isSelectedByDefault ?? safety.isPreselected
    }

    /// URL form for AppKit interop (Reveal in Finder, Quick Look).
    public var url: URL { URL(fileURLWithPath: path) }

    /// Path relative to the user's home directory when possible; falls back
    /// to the absolute path. Used for compact display in the UI.
    public var displayPath: String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Grouping helpers

public extension Array where Element == ScanItem {
    /// Group items by category, preserving a stable category order (safe first,
    /// then review, then dangerous; within the same safety, alphabetical).
    func groupedByCategory() -> [(category: RuleCategory, items: [ScanItem])] {
        var buckets: [RuleCategory: [ScanItem]] = [:]
        for item in self {
            buckets[item.category, default: []].append(item)
        }
        let safetyRank: [SafetyLevel: Int] = [.safe: 0, .review: 1, .dangerous: 2]
        return buckets.map { (category: $0.key, items: $0.value) }
            .sorted { a, b in
                let aSafety = a.items.map(\.safety).min(by: {
                    (safetyRank[$0] ?? 9) < (safetyRank[$1] ?? 9)
                }) ?? .dangerous
                let bSafety = b.items.map(\.safety).min(by: {
                    (safetyRank[$0] ?? 9) < (safetyRank[$1] ?? 9)
                }) ?? .dangerous
                if aSafety != bSafety { return (safetyRank[aSafety] ?? 9) < (safetyRank[bSafety] ?? 9) }
                return a.category.displayName < b.category.displayName
            }
    }

    /// Group items by rule id (finer-grained than category).
    func groupedByRule() -> [(ruleID: String, ruleName: String, items: [ScanItem])] {
        var buckets: [String: (name: String, items: [ScanItem])] = [:]
        for item in self {
            var entry = buckets[item.ruleID] ?? (name: item.ruleName, items: [])
            entry.items.append(item)
            buckets[item.ruleID] = entry
        }
        return buckets.map { (ruleID: $0.key, ruleName: $0.value.name, items: $0.value.items) }
            .sorted { $0.items.reduce(0) { $0 + $1.size } > $1.items.reduce(0) { $0 + $1.size } }
    }

    /// Total allocated bytes across all items.
    var totalSize: Int64 { reduce(0) { $0 + $1.size } }

    /// Total bytes for the subset where `isSelectedByDefault` is true.
    var defaultSelectedSize: Int64 {
        reduce(0) { $0 + ($1.isSelectedByDefault ? $1.size : 0) }
    }

    /// Number of items where `isSelectedByDefault` is true.
    var defaultSelectedCount: Int {
        reduce(0) { $0 + ($1.isSelectedByDefault ? 1 : 0) }
    }
}
