//
//  LeftoverFinder.swift
//  CleanMac
//
//  Given an AppBundleInfo, expands the `uninstaller-leftovers.yaml` rule pack
//  with `{bundleId}`, `{appName}`, `{execName}`, and `{appPath}` template
//  variables, then runs the ScannerEngine to collect every matching path.
//
//  Also provides `findOrphanedLeftovers()` which scans for leftover files
//  whose owning app is no longer installed — used by Smart Scan.
//

import Foundation

public struct LeftoverFinder: Sendable {

    private let fs: FileSystem
    private let matcher: PathMatcher
    private let scanner: ScannerEngine
    private let ruleLoader: RuleLoader
    private let sizeCalculator: SizeCalculator

    public init(
        fileSystem: FileSystem,
        scanner: ScannerEngine,
        ruleLoader: RuleLoader,
        matcher: PathMatcher = PathMatcher()
    ) {
        self.fs = fileSystem
        self.matcher = matcher
        self.scanner = scanner
        self.ruleLoader = ruleLoader
        self.sizeCalculator = SizeCalculator(fileSystem: fileSystem)
    }

    // MARK: - Per-app leftover scan

    /// Build the template context for a single app.
    public func context(for app: AppBundleInfo) -> PathMatcher.Context {
        var variables: [String: String] = [
            "bundleId": app.bundleIdentifier,
            L10n.string("appName"): app.presentationName,
            L10n.string("execName"): app.executableName,
            L10n.string("appPath"): app.path
        ]
        // Some rules use `{appNameLower}` for case-insensitive matches.
        variables["appNameLower"] = app.presentationName.lowercased()
        variables["bundleIdLower"] = app.bundleIdentifier.lowercased()
        return PathMatcher.Context(home: NSHomeDirectory(), variables: variables)
    }

    /// Find every leftover file/folder for a single installed app.
    ///
    /// - Parameters:
    ///   - app: The bundle to search for.
    ///   - runningAppBundlePaths: Snapshot of currently running bundles so
    ///     the denylist can refuse to touch them.
    /// - Returns: ScanItems grouped by rule category, sorted by size desc.
    public func findLeftovers(
        for app: AppBundleInfo,
        runningAppBundlePaths: Set<String> = []
    ) async -> [ScanItem] {
        let pack: RulePack
        do {
            pack = try ruleLoader.loadMerged(named: RulePackName.uninstallerLeftovers)
        } catch {
            return []
        }

        let context = self.context(for: app)

        // Filter out rules that would target the app bundle itself when the
        // app is running — we don't want to trash a live .app.
        let rules = pack.rules.filter { rule in
            // The `app-bundle` rule is always allowed; the ViewModel decides
            // whether to include it based on the user's choice.
            return true
        }

        let items = await scanner.scan(
            rules: rules,
            context: context,
            runningAppBundlePaths: runningAppBundlePaths
        )

        // De-duplicate by path (multiple rules can match the same folder).
        var seen = Set<String>()
        var unique: [ScanItem] = []
        for item in items {
            let std = matcher.standardize(item.path)
            guard !seen.contains(std) else { continue }
            seen.insert(std)
            unique.append(item)
        }

        // Always include the .app bundle itself as the first entry so the UI
        // can show it at the top of the list.
        let bundleItem = ScanItem(
            path: app.path,
            name: app.presentationName,
            ruleID: "app-bundle",
            ruleName: L10n.string("Application"),
            category: .application,
            safety: app.isSystemApp ? .review : .safe,
            size: app.size,
            isDirectory: true,
            annotation: app.isSystemApp ? L10n.string("System app — cannot be removed") : nil,
            isReadOnly: app.isSystemApp,
            isSelectedByDefault: !app.isSystemApp
        )

        // Replace any scanner-produced app-bundle entry with our authoritative one.
        unique.removeAll { $0.ruleID == "app-bundle" }
        return [bundleItem] + unique.sorted { $0.size > $1.size }
    }

    // MARK: - Orphaned leftovers (Smart Scan)

    /// Scan for leftover files whose owning app no longer exists. Used by
    /// Smart Scan to surface "ghost" files from uninstalled apps.
    ///
    /// Strategy: enumerate the well-known leftover locations, extract a
    /// probable bundle id from each entry's name, and check whether any
    /// installed app owns it. Entries with no owner are reported.
    public func findOrphanedLeftovers(
        installedBundleIDs: Set<String>,
        runningAppBundlePaths: Set<String> = []
    ) async -> [ScanItem] {
        let pack: RulePack
        do {
            pack = try ruleLoader.loadMerged(named: RulePackName.uninstallerLeftovers)
        } catch {
            return []
        }

        // We only care about rules whose paths contain `{bundleId}` — those
        // are the ones we can reverse-engineer an owner for.
        let orphanRules = pack.rules.filter { rule in
            rule.paths.contains { $0.contains(L10n.string("{bundleId}")) }
        }

        var orphans: [ScanItem] = []

        for rule in orphanRules {
            for pattern in rule.paths {
                // Expand the pattern with an empty bundleId to get the
                // directory we should enumerate.
                let expanded = matcher.expand(pattern, context: .empty)
                let (searchDir, _) = splitAtFirstGlob(expanded)
                guard fs.exists(searchDir),
                      let children = try? fs.contentsOfDirectory(searchDir) else { continue }

                for child in children {
                    let childPath = (searchDir as NSString).appendingPathComponent(child)
                    let std = matcher.standardize(childPath)

                    // Guess the bundle id from the entry name.
                    guard let guessedBundleID = guessBundleID(from: child, pattern: pattern) else { continue }

                    // If any installed app owns this bundle id, it's not an orphan.
                    if installedBundleIDs.contains(guessedBundleID) { continue }
                    // Also check prefix matches (e.g. "com.foo.bar" owns "com.foo.bar.helper").
                    let owned = installedBundleIDs.contains { installed in
                        guessedBundleID.hasPrefix(installed + ".") || installed.hasPrefix(guessedBundleID + ".")
                    }
                    if owned { continue }

                    // Skip Apple-owned paths.
                    if guessedBundleID.hasPrefix("com.apple.") { continue }

                    let meta = try? fs.metadata(at: std)
                    let size: Int64
                    if let meta, !meta.isDirectory {
                        size = meta.allocatedSize > 0 ? meta.allocatedSize : meta.contentSize
                    } else {
                        size = sizeCalculator.size(of: std)
                    }
                    guard size > 0 else { continue }

                    orphans.append(ScanItem(
                        path: std,
                        ruleID: "orphaned-" + rule.id,
                        ruleName: L10n.string("Orphaned ") + rule.name,
                        category: rule.category,
                        safety: .review,
                        size: size,
                        isDirectory: meta?.isDirectory ?? false,
                        modificationDate: meta?.modificationDate,
                        annotation: L10n.string("App no longer installed (%@)", "\(guessedBundleID)"),
                        isSelectedByDefault: false
                    ))
                }
            }
        }

        // De-duplicate by path.
        var seen = Set<String>()
        return orphans.filter { seen.insert($0.path).inserted }
            .sorted { $0.size > $1.size }
    }

    /// Extract a probable bundle id from a filename that matched a pattern
    /// containing `{bundleId}`. Handles the common shapes:
    ///   - `com.foo.bar` (exact)
    ///   - `com.foo.bar.plist`
    ///   - `com.foo.bar.savedState`
    ///   - `com.foo.bar-helper`
    ///   - `group.com.foo.bar`
    private func guessBundleID(from filename: String, pattern: String) -> String? {
        var name = filename

        // Strip known suffixes that rules append after `{bundleId}`.
        let suffixes = [".plist", L10n.string(".savedState"), ".binarycookies", ".lockfile",
                        ".cache", ".db", "-helper", ".helper"]
        for suffix in suffixes where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }

        // Strip trailing `*` matches: if the pattern was `{bundleId}*`, the
        // filename may have extra characters. We can't know where the bundle
        // id ends, so take the longest prefix that looks like a bundle id.
        // Heuristic: at least two dots, all segments alphanumeric+dash.
        guard name.contains(".") else { return nil }
        let segments = name.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        // Validate each segment looks like part of a reverse-domain id.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for segment in segments {
            if segment.isEmpty { return nil }
            if !segment.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return nil }
        }

        return name
    }

    private func splitAtFirstGlob(_ pattern: String) -> (base: String, remainder: String) {
        var idx = pattern.startIndex
        while idx < pattern.endIndex {
            let c = pattern[idx]
            if c == "*" || c == "?" || c == "[" {
                let prefix = String(pattern[pattern.startIndex..<idx])
                if let lastSlash = prefix.lastIndex(of: "/") {
                    let base = String(prefix[prefix.startIndex...lastSlash])
                    let remainder = String(pattern[lastSlash...])
                    return (base.hasSuffix("/") ? String(base.dropLast()) : base, remainder)
                }
                return (prefix, String(pattern[idx...]))
            }
            idx = pattern.index(after: idx)
        }
        return (pattern, "")
    }
}
