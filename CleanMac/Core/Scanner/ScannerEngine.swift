//
//  ScannerEngine.swift
//  CleanMac
//
//  The orchestrator. Consumes RulePacks, walks the filesystem in parallel,
//  applies excludes and the safety denylist, and emits ScanItems plus a
//  live progress stream.
//

import Foundation
import AppKit

public actor ScannerEngine {

    // MARK: - Dependencies

    private let fs: FileSystem
    private let matcher: PathMatcher
    private let walker: FileWalker
    private let denylist: PathDenylist
    private let sizeCalculator: SizeCalculator

    /// Own bundle path — never touch ourselves.
    private let ownBundlePath: String?

    // No mutable state: `runningAppBundlePaths` is threaded through `scan` as a
    // parameter rather than parked here, because a stored property would force
    // the evaluation path to stay actor-isolated and serialise the TaskGroup.

    public init(
        fileSystem: FileSystem,
        matcher: PathMatcher = PathMatcher(),
        denylist: PathDenylist = PathDenylist(),
        ownBundlePath: String? = Bundle.main.bundlePath
    ) {
        self.fs = fileSystem
        self.matcher = matcher
        self.walker = FileWalker(fileSystem: fileSystem, matcher: matcher)
        self.denylist = denylist
        self.sizeCalculator = SizeCalculator(fileSystem: fileSystem)
        self.ownBundlePath = ownBundlePath
    }

    // MARK: - Public API

    /// Scan `rules`, publishing live progress and returning every matched item.
    ///
    /// This is the whole pipeline (spec §3) and the only entry point to it. It
    /// used to be split across a streaming `scan` and a `scanAndAwait` wrapper:
    /// the streaming one returned `([], stream)` — never any items — and the
    /// wrapper called it, threw the stream away unread, then walked the disk a
    /// second time to produce the real answer. Every module scan therefore paid
    /// for two full traversals and leaked the first one's unbounded
    /// `AsyncStream` buffer.
    ///
    /// - Parameters:
    ///   - rules: The rule list to evaluate.
    ///   - context: Template variable context (for `{bundleId}` etc.).
    ///   - runningAppBundlePaths: Snapshot taken on the main actor before the
    ///     scan starts. Passed in so this type stays off AppKit, and threaded
    ///     through to the denylist rather than stored on `self` — storing it
    ///     would pin the evaluation path to the actor and serialise the
    ///     TaskGroup below.
    ///   - concurrency: Upper bound on parallel rule evaluation.
    ///   - progress: Writable half of an `AsyncStream<ScanProgress>` the caller
    ///     created, for rendering live counters. Iterate the stream concurrently
    ///     with awaiting this method:
    ///
    ///         let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
    ///         async let items = scanner.scan(rules: r, runningAppBundlePaths: a,
    ///                                        progress: continuation)
    ///         for await p in stream { … }
    ///         let found = await items
    ///
    ///     The stream is finished exactly once, when the scan ends.
    ///   - onProgress: Plain callback alternative, for callers already holding
    ///     the isolation domain they want to update. Both sinks receive
    ///     identical events.
    /// - Returns: Every matched item, in rule-completion order.
    ///
    /// `nonisolated` so the TaskGroup children genuinely run concurrently: an
    /// actor-isolated `evaluate` makes every child hop back onto this actor's
    /// single executor, which turns "in parallel, bounded to
    /// activeProcessorCount" into "serial" while still looking parallel.
    @discardableResult
    public nonisolated func scan(
        rules: [Rule],
        context: PathMatcher.Context = .empty,
        runningAppBundlePaths: Set<String>,
        concurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
        progress: AsyncStream<ScanProgress>.Continuation? = nil,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> [ScanItem] {
        let totalRules = max(rules.count, 1)
        var collected: [ScanItem] = []

        await withTaskGroup(of: (Int, [ScanItem]).self) { group in
            var inFlight = 0
            var nextIndex = 0
            var completed = 0

            func scheduleNext() {
                while inFlight < concurrency && nextIndex < rules.count {
                    let idx = nextIndex
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        let items = await self.evaluate(
                            rule: rules[idx],
                            context: context,
                            runningAppBundlePaths: runningAppBundlePaths
                        )
                        return (idx, items)
                    }
                }
            }
            scheduleNext()

            while let (idx, items) = await group.next() {
                inFlight -= 1
                completed += 1
                collected.append(contentsOf: items)
                let event = ScanProgress(
                    ruleID: rules[idx].id,
                    ruleName: rules[idx].name,
                    currentPath: items.last?.path,
                    itemsFound: collected.count,
                    bytesFound: collected.totalSize,
                    fractionComplete: Double(completed) / Double(totalRules),
                    isFinished: false,
                    statusMessage: "Scanning \(rules[idx].name)…"
                )
                progress?.yield(event)
                onProgress?(event)
                if Task.isCancelled { group.cancelAll(); break }
                scheduleNext()
            }
        }

        let finalEvent = ScanProgress(
            itemsFound: collected.count,
            bytesFound: collected.totalSize,
            fractionComplete: 1,
            isFinished: true,
            statusMessage: Task.isCancelled ? "Cancelled" : "Scan complete"
        )
        progress?.yield(finalEvent)
        onProgress?(finalEvent)
        progress?.finish()
        return collected
    }

    // MARK: - Rule evaluation

    /// `nonisolated` throughout the evaluation path: every dependency below is
    /// an immutable `Sendable` value, so rule evaluation can run on the
    /// cooperative pool in parallel. Leaving these actor-isolated would compile
    /// and look concurrent while actually queueing every rule behind this
    /// actor's single executor.
    private nonisolated func evaluate(
        rule: Rule,
        context: PathMatcher.Context,
        runningAppBundlePaths: Set<String>
    ) async -> [ScanItem] {
        if Task.isCancelled { return [] }

        // Dispatch specialised strategies.
        if let strategy = rule.strategy {
            return await evaluateSpecialized(
                rule: rule,
                strategy: strategy,
                context: context,
                runningAppBundlePaths: runningAppBundlePaths
            )
        }

        // Default: glob-based matching.
        var items: [ScanItem] = []
        let excludesCompiled = rule.excludes
            .map { matcher.compile(matcher.expand($0, context: context)) }

        for pattern in rule.paths {
            if Task.isCancelled { break }
            let expanded = matcher.expand(pattern, context: context)
            guard !expanded.isEmpty else { continue }

            let matches = collectMatches(for: expanded)
            let compiled = matcher.compile(expanded)

            for path in matches {
                if Task.isCancelled { break }
                let std = matcher.standardize(path)

                // Verify against the full compiled pattern (collectMatches
                // returns candidates by prefix; the regex confirms).
                let ns = NSRange(std.startIndex..., in: std)
                guard compiled.firstMatch(in: std, range: ns) != nil else { continue }

                // Exclude check
                if Self.matchesAny(regexes: excludesCompiled, path: std) { continue }

                // Metadata (may fail for protected files — skip silently)
                let meta = try? fs.metadata(at: std)

                // Denylist
                let decision = denylist.decide(
                    path: std,
                    metadata: meta,
                    rule: rule,
                    runningAppBundlePaths: runningAppBundlePaths,
                    ownBundlePath: ownBundlePath
                )
                if case .denied = decision { continue }

                let isDir = meta?.isDirectory ?? false
                let size: Int64
                if let meta, !meta.isDirectory {
                    size = meta.allocatedSize > 0 ? meta.allocatedSize : meta.contentSize
                } else {
                    size = sizeCalculator.size(of: std)
                }

                items.append(ScanItem(
                    path: std,
                    ruleID: rule.id,
                    ruleName: rule.name,
                    category: rule.category,
                    safety: rule.safety,
                    size: size,
                    isDirectory: isDir,
                    modificationDate: meta?.modificationDate,
                    contentAccessDate: meta?.contentAccessDate,
                    annotation: nil,
                    isReadOnly: meta == nil
                ))
            }
        }

        return items
    }

    /// Given an expanded pattern, return candidate paths to test against the
    /// compiled regex. Strategy: split the pattern at the first glob
    /// metacharacter, list the directory containing that point, and produce
    /// every descendant up to the pattern's depth (or one level when only
    /// `*` is used).
    private nonisolated func collectMatches(for expandedPattern: String) -> [String] {
        let (base, remainder) = splitAtFirstGlob(expandedPattern)

        // No glob at all: check the literal path.
        if remainder.isEmpty {
            return fs.exists(base) ? [base] : []
        }

        // `base` may itself be a file (e.g. `~/foo.plist*` where base is
        // `~/foo.plist`). If so, and remainder is just `*`, return the file.
        if fs.exists(base), let meta = try? fs.metadata(at: base), !meta.isDirectory {
            return [base]
        }

        // Determine the directory to list. If base is a directory, list it.
        // Otherwise, list its parent.
        let (searchDir, tailPattern) = resolveSearchDirectory(base: base, remainder: remainder)

        guard fs.exists(searchDir), let dirMeta = try? fs.metadata(at: searchDir), dirMeta.isDirectory else {
            return []
        }

        let isRecursive = tailPattern.contains("**")

        var out: [String] = []

        if isRecursive {
            // Deep enumeration. Cap the results to protect against runaway
            // scans of enormous trees.
            let cap = 20_000
            try? fs.enumerate(root: searchDir, includeHidden: true, followSymlinks: false) { path, _ in
                out.append(path)
                if out.count >= cap { return .skipDescendants }
                return .continueEnumeration
            }
        } else {
            // Single-level: list direct children of searchDir.
            if let children = try? fs.contentsOfDirectory(searchDir) {
                for child in children {
                    out.append((searchDir as NSString).appendingPathComponent(child))
                }
            }
        }
        return out
    }

    private nonisolated func splitAtFirstGlob(_ pattern: String) -> (base: String, remainder: String) {
        var idx = pattern.startIndex
        while idx < pattern.endIndex {
            let c = pattern[idx]
            if c == "*" || c == "?" || c == "[" {
                // Back up to the last '/' before the glob.
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

    /// Given `base` (the literal prefix) and `remainder` (the glob tail),
    /// return the directory to enumerate and the pattern to test each entry
    /// against. If `base` is an existing directory we enumerate it directly;
    /// otherwise we enumerate its parent.
    private nonisolated func resolveSearchDirectory(base: String, remainder: String) -> (String, String) {
        if fs.exists(base), let meta = try? fs.metadata(at: base), meta.isDirectory {
            return (base, remainder)
        }
        let parent = (base as NSString).deletingLastPathComponent
        let last = (base as NSString).lastPathComponent
        // Rebuild the tail pattern to include the last path component.
        let tail: String
        if remainder.hasPrefix("/") {
            tail = "/" + last + remainder.dropFirst()
        } else {
            tail = last + remainder
        }
        return (parent, tail)
    }

    private static func matchesAny(regexes: [NSRegularExpression], path: String) -> Bool {
        let ns = NSRange(path.startIndex..., in: path)
        for r in regexes where r.firstMatch(in: path, range: ns) != nil { return true }
        return false
    }

    // MARK: - Specialised strategies

    private nonisolated func evaluateSpecialized(
        rule: Rule,
        strategy: RuleStrategy,
        context: PathMatcher.Context,
        runningAppBundlePaths: Set<String>
    ) async -> [ScanItem] {
        switch strategy {
        case .languageFilter:
            return await evaluateLanguageFilter(
                rule: rule,
                context: context,
                runningAppBundlePaths: runningAppBundlePaths
            )
        case .trashBins:
            return evaluateTrashBins(rule: rule, runningAppBundlePaths: runningAppBundlePaths)
        case .brokenLoginItems:
            return evaluateBrokenLoginItems(rule: rule, runningAppBundlePaths: runningAppBundlePaths)
        case .tmutilSnapshots:
            return evaluateTmutilSnapshots(rule: rule)
        }
    }

    // MARK: Language filter

    private nonisolated func evaluateLanguageFilter(
        rule: Rule,
        context: PathMatcher.Context,
        runningAppBundlePaths: Set<String>
    ) async -> [ScanItem] {
        // `keepLanguages` is data-driven and resolved here, at scan time: the
        // token "active" expands to the user's AppleLanguages, while any other
        // entry is a literal language code the rule wants preserved.
        let active = Set(Self.currentAppleLanguages())
        let keep = Set(rule.effectiveKeepLanguages.flatMap { token -> [String] in
            let lowercased = token.lowercased()
            return lowercased == Rule.activeLanguagesToken ? Array(active) : [lowercased]
        })
        var items: [ScanItem] = []

        for pattern in rule.paths {
            let expanded = matcher.expand(pattern, context: context)
            let (base, _) = splitAtFirstGlob(expanded)
            guard fs.exists(base) else { continue }

            try? fs.enumerate(root: base, includeHidden: false, followSymlinks: false) { path, meta in
                guard meta.isDirectory, path.hasSuffix(".lproj") else { return .continueEnumeration }
                let lang = (path as NSString).lastPathComponent
                    .replacingOccurrences(of: ".lproj", with: "")
                // Never touch Base or Root: they hold the language-neutral
                // resources every locale falls back to.
                if lang == "Base" || lang == "Root" { return .continueEnumeration }
                // Compared case-insensitively. On-disk bundles are capitalised
                // ("zh-Hans.lproj") while AppleLanguages are not ("zh-Hans" vs
                // "zh-hans"), so a case-sensitive compare would offer up the
                // user's own language for deletion.
                let langKey = lang.lowercased()
                if keep.contains(where: { $0.hasPrefix(langKey) || langKey.hasPrefix($0) }) {
                    return .continueEnumeration
                }
                let std = matcher.standardize(path)
                let decision = denylist.decide(
                    path: std, metadata: meta, rule: rule,
                    runningAppBundlePaths: runningAppBundlePaths,
                    ownBundlePath: ownBundlePath
                )
                if case .denied = decision { return .continueEnumeration }
                let size = sizeCalculator.size(of: std)
                items.append(ScanItem(
                    path: std,
                    ruleID: rule.id,
                    ruleName: rule.name,
                    category: rule.category,
                    safety: rule.safety,
                    size: size,
                    isDirectory: true,
                    modificationDate: meta.modificationDate,
                    annotation: L10n.string("%@ localisation", lang)
                ))
                return .continueEnumeration
            }
        }
        return items
    }

    /// AppleLanguages defaults to ["en-US", ...]. We normalise by stripping
    /// region suffixes so "en" matches "en-US", "en-GB", etc.
    static func currentAppleLanguages() -> [String] {
        let raw = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? ["en"]
        return raw.map { $0.lowercased() }
    }

    // MARK: Trash bins

    private nonisolated func evaluateTrashBins(
        rule: Rule,
        runningAppBundlePaths: Set<String>
    ) -> [ScanItem] {
        var items: [ScanItem] = []
        let volumes = fs.mountedVolumes()
        let uid = getuid()

        for volume in volumes {
            // User trash for the boot volume lives at ~/.Trash.
            // External volumes keep per-user trashes at /.Trashes/<uid>.
            let trashPath: String
            if volume == "/" {
                trashPath = fs.userTrashDirectory
            } else {
                trashPath = (volume as NSString)
                    .appendingPathComponent(".Trashes/\(uid)")
            }

            guard fs.exists(trashPath) else { continue }
            let size = sizeCalculator.size(of: trashPath)
            guard size > 0 else { continue }

            let std = matcher.standardize(trashPath)
            let decision = denylist.decide(
                path: std, metadata: nil, rule: rule,
                runningAppBundlePaths: runningAppBundlePaths,
                ownBundlePath: ownBundlePath
            )
            if case .denied = decision { continue }

            items.append(ScanItem(
                path: std,
                name: volume == "/" ? L10n.string("Trash") : L10n.string("Trash on %@", volume),
                ruleID: rule.id,
                ruleName: rule.name,
                category: rule.category,
                safety: rule.safety,
                size: size,
                isDirectory: true,
                annotation: volume == "/" ? nil : L10n.string("Volume: %@", volume)
            ))
        }
        return items
    }

    // MARK: Broken login items

    private nonisolated func evaluateBrokenLoginItems(
        rule: Rule,
        runningAppBundlePaths: Set<String>
    ) -> [ScanItem] {
        // Scan user + system LaunchAgents/Daemons for plists whose Program
        // or ProgramArguments[0] points to a nonexistent file.
        var items: [ScanItem] = []
        let searchDirs = [
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents"),
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons"
        ]

        for dir in searchDirs {
            guard fs.exists(dir),
                  let children = try? fs.contentsOfDirectory(dir) else { continue }
            for child in children where child.hasSuffix(".plist") {
                let plistPath = (dir as NSString).appendingPathComponent(child)
                guard let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else { continue }

                var executablePath: String?
                if let p = dict["Program"] as? String {
                    executablePath = p
                } else if let args = dict["ProgramArguments"] as? [String], let first = args.first {
                    executablePath = first
                }
                guard let execPath = executablePath else { continue }

                // Skip plists that use label-only or non-absolute references.
                if !execPath.hasPrefix("/") { continue }
                if fs.exists(execPath) { continue }

                let meta = try? fs.metadata(at: plistPath)
                let std = matcher.standardize(plistPath)
                let decision = denylist.decide(
                    path: std, metadata: meta, rule: rule,
                    runningAppBundlePaths: runningAppBundlePaths,
                    ownBundlePath: ownBundlePath
                )
                if case .denied = decision { continue }

                items.append(ScanItem(
                    path: std,
                    ruleID: rule.id,
                    ruleName: rule.name,
                    category: rule.category,
                    safety: rule.safety,
                    size: meta?.allocatedSize ?? 0,
                    isDirectory: false,
                    modificationDate: meta?.modificationDate,
                    annotation: L10n.string("Missing executable: %@", execPath)
                ))
            }
        }
        return items
    }

    // MARK: APFS local snapshots (read-only report)

    private nonisolated func evaluateTmutilSnapshots(rule: Rule) -> [ScanItem] {
        // We cannot delete these without root; surface them as read-only
        // informational items so the user knows they exist and how much
        // space they occupy. Actual removal requires `tmutil deletelocalsnapshots`.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        task.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var items: [ScanItem] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("com.apple.TimeMachine.") else { continue }
            // Format: com.apple.TimeMachine.2025-08-14-123456.local
            items.append(ScanItem(
                path: "/\(trimmed)",
                name: trimmed,
                ruleID: rule.id,
                ruleName: rule.name,
                category: rule.category,
                safety: rule.safety,
                size: 0,             // real size requires diskutil; report 0
                isDirectory: false,
                annotation: L10n.string(
                    "Local snapshot. Run `sudo tmutil deletelocalsnapshots /` to remove."),
                isReadOnly: true,
                isSelectedByDefault: false
            ))
        }
        return items
    }
}
