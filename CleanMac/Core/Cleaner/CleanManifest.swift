//
//  CleanManifest.swift
//  CleanMac
//
//  A record of one clean operation. Persisted to disk so the user can undo
//  it later from the History view.
//

import Foundation

public struct CleanManifest: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    /// When the clean started.
    public let startedAt: Date
    /// When the clean finished.
    public let finishedAt: Date
    /// Which module produced this clean ("system-junk", "uninstaller", etc.).
    public let source: String
    /// Optional label shown in History, e.g. "Uninstall Google Chrome".
    public let label: String?
    /// Every item that was successfully moved to Trash.
    public let entries: [Entry]
    /// Every item we tried and failed to move.
    public let failures: [Failure]

    public struct Entry: Hashable, Sendable, Codable, Identifiable {
        public var id: String { originalPath }
        /// Absolute path before cleaning.
        public let originalPath: String
        /// Absolute path after cleaning (inside the Trash).
        public let trashPath: String
        /// Allocated size in bytes at the time of cleaning.
        public let size: Int64
        /// Rule id that produced this item (empty for direct user actions).
        public let ruleID: String
        /// Rule display name.
        public let ruleName: String
        /// Category rawValue.
        public let category: String

        public init(
            originalPath: String,
            trashPath: String,
            size: Int64,
            ruleID: String,
            ruleName: String,
            category: String
        ) {
            self.originalPath = originalPath
            self.trashPath = trashPath
            self.size = size
            self.ruleID = ruleID
            self.ruleName = ruleName
            self.category = category
        }
    }

    public struct Failure: Hashable, Sendable, Codable, Identifiable {
        public var id: String { path }
        public let path: String
        public let reason: String
        public let errorCode: Int?

        public init(path: String, reason: String, errorCode: Int? = nil) {
            self.path = path
            self.reason = reason
            self.errorCode = errorCode
        }
    }

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date,
        source: String,
        label: String?,
        entries: [Entry],
        failures: [Failure]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.source = source
        self.label = label
        self.entries = entries
        self.failures = failures
    }

    /// Source string for manifests that record an *undo* rather than a clean.
    /// A constant so the writer (`CleanerService`, `HistoryStore.restore`) and
    /// the readers (`HistoryStore.totalReclaimed`/`cleanCount`) cannot drift.
    public static let restoreSource = "restore"

    /// Whether this manifest records an undo. A restore moves bytes *back* onto
    /// the disk, so it must never be counted as reclaimed space.
    public var isRestore: Bool { source == Self.restoreSource }

    /// Total bytes successfully reclaimed.
    public var bytesReclaimed: Int64 { entries.reduce(0) { $0 + $1.size } }

    /// Number of items successfully moved.
    public var itemCount: Int { entries.count }

    /// Wall-clock duration.
    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    /// Human label for the History list.
    ///
    /// A caller-supplied `label` is returned as-is: it was already localized
    /// where it was written (the UI passes `L10n` strings). Only the
    /// source-derived fallbacks are looked up here.
    public var displayLabel: String {
        if let label, !label.isEmpty { return label }
        switch source {
        case "system-junk": return L10n.string("System Junk clean")
        case "uninstaller": return L10n.string("App uninstall")
        case "large-and-old": return L10n.string("Large & Old Files clean")
        case "smart-scan": return L10n.string("Smart Scan clean")
        default: return source.capitalized
        }
    }

    /// Label for the manifest that records undoing `manifest`.
    /// Centralised so `CleanerService.restore` and `HistoryStore.restore`
    /// cannot word the same event differently.
    public static func restoreLabel(for manifest: CleanManifest) -> String {
        L10n.string("Restore of %@", manifest.displayLabel)
    }
}
