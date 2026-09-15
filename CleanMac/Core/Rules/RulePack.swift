//
//  RulePack.swift
//  CleanMac
//
//  The Codable model for a bundle of rules. A pack is one YAML file on disk;
//  `RuleLoader` decodes it, merges any user override with the same id, and
//  hands the result to `ScannerEngine`.
//

import Foundation

/// A named bundle of rules loaded from a single YAML file.
public struct RulePack: Identifiable, Hashable, Sendable, Codable {
    public var id: String { name }
    public var name: String
    public var version: Int
    public var rules: [Rule]
    /// Pack-wide excludes merged into every rule at load time.
    public var excludes: [String]
    /// Optional defaults block (used by large-files pack).
    public var defaults: [String: String]?

    public init(
        name: String,
        version: Int,
        rules: [Rule],
        excludes: [String] = [],
        defaults: [String: String]? = nil
    ) {
        self.name = name
        self.version = version
        self.rules = rules
        self.excludes = excludes
        self.defaults = defaults
    }
}

// MARK: - Rule pack names (bundle resource keys)

/// The stems of the YAML files shipped in `CleanMac/Resources/Rules`.
///
/// These double as bundle resource keys, so a rename here must be matched by a
/// rename on disk — `RuleLoaderTests` loads each of them and fails if one is
/// missing.
public enum RulePackName {
    public static let systemJunk = "system-junk"
    public static let uninstallerLeftovers = "uninstaller-leftovers"
    public static let largeFilesDefaults = "large-files-defaults"

    public static let allBundled: [String] = [systemJunk, uninstallerLeftovers, largeFilesDefaults]
}
