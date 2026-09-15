//
//  RuleLoader.swift
//  CleanMac
//
//  Loads rule packs from two places:
//    1. Bundled YAML shipped inside the app (read-only, always present).
//    2. User YAML in ~/Library/Application Support/CleanMac/Rules/ (optional).
//
//  User rules with the same `id` as a bundled rule replace it. Extra rules
//  are appended. Pack-level `excludes` are merged into every rule.
//

import Foundation

public enum RuleLoadError: Error, CustomStringConvertible, Equatable {
    case missingResource(String)
    case malformed(String, String)         // pack name, message
    case io(String)

    public var description: String {
        switch self {
        case .missingResource(let n): return "Missing rule pack resource: \(n)"
        case .malformed(let p, let m): return "Malformed rule pack '\(p)': \(m)"
        case .io(let m): return "I/O error loading rules: \(m)"
        }
    }
}

public struct RuleLoader: Sendable {

    private let parser: YAMLParser
    private let bundle: Bundle
    private let fs: FileSystem

    /// Directory searched for user-supplied rule overrides.
    /// Defaults to ~/Library/Application Support/CleanMac/Rules.
    public let userRulesDirectory: String

    public init(
        bundle: Bundle = .main,
        fileSystem: FileSystem = LiveFileSystem(),
        userRulesDirectory: String? = nil
    ) {
        self.parser = YAMLParser()
        self.bundle = bundle
        self.fs = fileSystem
        self.userRulesDirectory = userRulesDirectory ?? {
            let support = (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support/CleanMac/Rules")
            return support
        }()
    }

    // MARK: - Public API

    /// Load a single bundled pack by name (without the `.yaml` suffix).
    public func loadBundled(named name: String) throws -> RulePack {
        // The Rules folder is copied as a folder reference, so resources live
        // at <bundle>/Resources/Rules/<name>.yaml.
        var url = bundle.url(forResource: name, withExtension: "yaml", subdirectory: "Rules")
        if url == nil {
            url = bundle.url(forResource: name, withExtension: "yaml")
        }
        guard let resolved = url else { throw RuleLoadError.missingResource(name) }

        let text: String
        do {
            text = try String(contentsOf: resolved, encoding: .utf8)
        } catch {
            throw RuleLoadError.io(error.localizedDescription)
        }
        return try decode(text: text, packNameHint: name)
    }

    /// Load every bundled pack in `RulePackName.allBundled`.
    public func loadAllBundled() -> [RulePack] {
        var out: [RulePack] = []
        for name in RulePackName.allBundled {
            if let pack = try? loadBundled(named: name) {
                out.append(pack)
            }
        }
        return out
    }

    /// Load a bundled pack and merge user overrides for that pack.
    public func loadMerged(named name: String) throws -> RulePack {
        let bundled = try loadBundled(named: name)
        let userOverride = try loadUser(named: name)
        guard let user = userOverride else { return bundled }
        return Self.merge(bundled: bundled, user: user)
    }

    /// Load a user-supplied pack if it exists. Returns nil when absent.
    public func loadUser(named name: String) throws -> RulePack? {
        let path = (userRulesDirectory as NSString).appendingPathComponent("\(name).yaml")
        guard fs.exists(path) else { return nil }
        let url = URL(fileURLWithPath: path)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw RuleLoadError.io(error.localizedDescription)
        }
        return try decode(text: text, packNameHint: name)
    }

    // MARK: - Merging

    /// Merge a user pack into a bundled pack:
    ///   - Rules with matching ids: user wins entirely (not field-merged).
    ///   - Extra user rules: appended.
    ///   - Pack-level excludes: union.
    ///   - Version: max(bundled, user).
    public static func merge(bundled: RulePack, user: RulePack) -> RulePack {
        var byId: [String: Rule] = [:]
        var orderedIds: [String] = []
        for rule in bundled.rules {
            byId[rule.id] = rule
            orderedIds.append(rule.id)
        }
        for rule in user.rules {
            if byId[rule.id] == nil { orderedIds.append(rule.id) }
            byId[rule.id] = rule
        }
        let mergedRules = orderedIds.compactMap { byId[$0] }
        let mergedExcludes = Array(Set(bundled.excludes + user.excludes)).sorted()

        return RulePack(
            name: bundled.name,
            version: max(bundled.version, user.version),
            rules: mergedRules,
            excludes: mergedExcludes,
            defaults: user.defaults ?? bundled.defaults
        )
    }

    /// Merge pack-level excludes into every rule that doesn't already list them.
    public static func applyPackExcludes(_ pack: RulePack) -> RulePack {
        guard !pack.excludes.isEmpty else { return pack }
        var updated = pack.rules
        for i in updated.indices {
            let existing = Set(updated[i].excludes)
            for e in pack.excludes where !existing.contains(e) {
                updated[i].excludes.append(e)
            }
        }
        var out = pack
        out.rules = updated
        return out
    }

    // MARK: - Decoding

    func decode(text: String, packNameHint: String) throws -> RulePack {
        let root: YAMLValue
        do {
            root = try parser.parse(text)
        } catch let error as YAMLParseError {
            throw RuleLoadError.malformed(packNameHint, error.description)
        } catch {
            throw RuleLoadError.malformed(packNameHint, error.localizedDescription)
        }

        guard case .map(let dict) = root else {
            throw RuleLoadError.malformed(packNameHint, "Top-level node must be a mapping")
        }

        let name = dict["pack"]?.stringValue ?? packNameHint
        let version = dict["version"]?.intValue ?? 1

        // Pack-level excludes
        let packExcludes = dict["excludes"]?.stringList ?? []

        // Optional defaults block (large-files pack)
        var defaults: [String: String]? = nil
        if let defaultsNode = dict["defaults"], case .map(let dmap) = defaultsNode {
            var m: [String: String] = [:]
            for (k, v) in dmap { m[k] = v.stringValue ?? "" }
            defaults = m
        }

        // Rules
        var rules: [Rule] = []
        if let rulesNode = dict["rules"] {
            guard case .list(let items) = rulesNode else {
                throw RuleLoadError.malformed(name, "'rules' must be a list")
            }
            for item in items {
                guard case .map(let rd) = item else {
                    throw RuleLoadError.malformed(name, "Every rule must be a mapping")
                }
                rules.append(try Self.decodeRule(rd, packName: name))
            }
        }

        // Non-rule packs (large-files-defaults) also carry `searchRoots`,
        // `skipPaths`, `protectedExtensions`, `bundleExtensions`, `presets`.
        // These are surfaced through `defaults` as stringified JSON so
        // callers can decode them on demand without us adding another model.
        var combinedDefaults = defaults
        let extraKeys = ["searchRoots", "skipPaths", "protectedExtensions",
                         "bundleExtensions", "presets"]
        for key in extraKeys {
            if let node = dict[key] {
                if combinedDefaults == nil { combinedDefaults = [:] }
                combinedDefaults?[key] = Self.yamlValueToJSONString(node)
            }
        }

        let pack = RulePack(
            name: name,
            version: version,
            rules: rules,
            excludes: packExcludes,
            defaults: combinedDefaults
        )
        return Self.applyPackExcludes(pack)
    }

    // MARK: - Rule decoding

    static func decodeRule(_ dict: [String: YAMLValue], packName: String) throws -> Rule {
        guard let id = dict["id"]?.stringValue, !id.isEmpty else {
            throw RuleLoadError.malformed(packName, "Rule is missing 'id'")
        }
        let name = dict["name"]?.stringValue ?? id
        let categoryRaw = dict["category"]?.stringValue ?? "other"
        let safetyRaw = dict["safety"]?.stringValue ?? "safe"
        guard let safety = SafetyLevel(rawValue: safetyRaw.lowercased()) else {
            throw RuleLoadError.malformed(packName, "Rule '\(id)': invalid safety '\(safetyRaw)'")
        }
        let paths = dict["paths"]?.stringList ?? []
        let excludes = dict["excludes"]?.stringList ?? []

        var strategy: RuleStrategy? = nil
        if let s = dict["strategy"]?.stringValue {
            guard let parsed = RuleStrategy(rawValue: s) else {
                throw RuleLoadError.malformed(packName, "Rule '\(id)': unknown strategy '\(s)'")
            }
            strategy = parsed
        }

        let modifiedWithinHours = dict["modifiedWithinHours"]?.intValue
        let keepLanguages = dict["keepLanguages"]?.stringList
        let description = dict["description"]?.stringValue

        return Rule(
            id: id,
            name: name,
            category: RuleCategory(rawValue: categoryRaw),
            safety: safety,
            paths: paths,
            excludes: excludes,
            strategy: strategy,
            modifiedWithinHours: modifiedWithinHours,
            keepLanguages: keepLanguages,
            description: description,
            packName: packName
        )
    }

    // MARK: - YAML -> JSON string (for pass-through defaults)

    /// Convert a YAMLValue into a compact JSON string. Used to smuggle the
    /// extra large-files config through `defaults` without a second model.
    static func yamlValueToJSONString(_ value: YAMLValue) -> String {
        let obj = yamlToJSONObject(value)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return str
    }

    private static func yamlToJSONObject(_ v: YAMLValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .list(let xs): return xs.map { yamlToJSONObject($0) }
        case .map(let m):
            var out: [String: Any] = [:]
            for (k, v) in m { out[k] = yamlToJSONObject(v) }
            return out
        }
    }
}

// MARK: - Typed defaults for the Large & Old Files pack

/// Decoded view of `large-files-defaults.yaml`. Callers instantiate this
/// from a `RulePack` whose `defaults` were populated by `RuleLoader`.
public struct LargeFilesConfig: Sendable, Equatable {
    public var sizeThresholdMB: Int
    public var ageDaysThreshold: Int
    public var includeHiddenFiles: Bool
    public var followSymlinks: Bool
    public var searchRoots: [String]
    public var skipPaths: [String]
    public var protectedExtensions: [String]
    public var bundleExtensions: [String]
    public var presets: [Preset]

    public struct Preset: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var extensions: [String]
        public var minSizeMB: Int
        public var pathContains: String?
    }

    public static let empty = LargeFilesConfig(
        sizeThresholdMB: 100,
        ageDaysThreshold: 180,
        includeHiddenFiles: false,
        followSymlinks: false,
        searchRoots: [],
        skipPaths: [],
        protectedExtensions: [],
        bundleExtensions: [],
        presets: []
    )

    public init(
        sizeThresholdMB: Int,
        ageDaysThreshold: Int,
        includeHiddenFiles: Bool,
        followSymlinks: Bool,
        searchRoots: [String],
        skipPaths: [String],
        protectedExtensions: [String],
        bundleExtensions: [String],
        presets: [Preset]
    ) {
        self.sizeThresholdMB = sizeThresholdMB
        self.ageDaysThreshold = ageDaysThreshold
        self.includeHiddenFiles = includeHiddenFiles
        self.followSymlinks = followSymlinks
        self.searchRoots = searchRoots
        self.skipPaths = skipPaths
        self.protectedExtensions = protectedExtensions
        self.bundleExtensions = bundleExtensions
        self.presets = presets
    }

    /// Decode from the `defaults` dictionary on a `RulePack`.
    public static func decode(from pack: RulePack) -> LargeFilesConfig {
        guard let d = pack.defaults else { return .empty }

        func intOr(_ key: String, _ fallback: Int) -> Int {
            guard let raw = d[key] else { return fallback }
            return Int(raw) ?? fallback
        }
        func boolOr(_ key: String, _ fallback: Bool) -> Bool {
            guard let raw = d[key]?.lowercased() else { return fallback }
            switch raw {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return fallback
            }
        }
        func stringArray(_ key: String) -> [String] {
            guard let raw = d[key],
                  let data = raw.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                return []
            }
            return arr
        }

        var presets: [Preset] = []
        if let raw = d["presets"],
           let data = raw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for p in arr {
                let id = p["id"] as? String ?? UUID().uuidString
                let name = p["name"] as? String ?? id
                let exts = p["extensions"] as? [String] ?? []
                let minMB = p["minSizeMB"] as? Int ?? 0
                let pathContains = p["pathContains"] as? String
                presets.append(Preset(id: id, name: name, extensions: exts,
                                      minSizeMB: minMB, pathContains: pathContains))
            }
        }

        return LargeFilesConfig(
            sizeThresholdMB: intOr("sizeThresholdMB", 100),
            ageDaysThreshold: intOr("ageDaysThreshold", 180),
            includeHiddenFiles: boolOr("includeHiddenFiles", false),
            followSymlinks: boolOr("followSymlinks", false),
            searchRoots: stringArray("searchRoots"),
            skipPaths: stringArray("skipPaths"),
            protectedExtensions: stringArray("protectedExtensions"),
            bundleExtensions: stringArray("bundleExtensions"),
            presets: presets
        )
    }
}
