//
//  FileWalker.swift
//  CleanMac
//
//  Directory traversal helpers used by the ScannerEngine and the Large & Old
//  Files module. Wraps FileSystem.enumerate with cancellation, skip patterns,
//  and a streaming callback.
//

import Foundation

public struct FileWalker: Sendable {

    private let fs: FileSystem
    private let matcher: PathMatcher

    public init(fileSystem: FileSystem, matcher: PathMatcher = PathMatcher()) {
        self.fs = fileSystem
        self.matcher = matcher
    }

    /// Options controlling a walk.
    public struct Options: Sendable {
        public var includeHidden: Bool
        public var followSymlinks: Bool
        /// Glob patterns; any match causes the entry to be skipped and, if a
        /// directory, its descendants pruned.
        public var skipPathPatterns: [String]
        /// Bundle extensions to treat as opaque (never descend inside).
        public var bundleExtensions: [String]
        /// When set, only files at least this many bytes are reported.
        public var minSizeBytes: Int64?
        /// When set, only entries whose contentAccessDate is older than this
        /// many days are reported. Directories are exempt (we cannot know
        /// "last opened" for a folder reliably).
        public var olderThanDays: Int?
        /// When set, only files with these extensions are reported. Case-insensitive.
        public var allowedExtensions: [String]?
        /// Cap on the number of entries reported. `nil` for unlimited.
        public var maxResults: Int?

        public init(
            includeHidden: Bool = false,
            followSymlinks: Bool = false,
            skipPathPatterns: [String] = [],
            bundleExtensions: [String] = [],
            minSizeBytes: Int64? = nil,
            olderThanDays: Int? = nil,
            allowedExtensions: [String]? = nil,
            maxResults: Int? = nil
        ) {
            self.includeHidden = includeHidden
            self.followSymlinks = followSymlinks
            self.skipPathPatterns = skipPathPatterns
            self.bundleExtensions = bundleExtensions.map { $0.lowercased() }
            self.minSizeBytes = minSizeBytes
            self.olderThanDays = olderThanDays
            self.allowedExtensions = allowedExtensions?.map { $0.lowercased() }
            self.maxResults = maxResults
        }

        public static let `default` = Options()
    }

    /// Streaming walk. The closure is called for every entry that passes the
    /// filters. Return `.skipDescendants` from the closure to prune a
    /// directory's children.
    ///
    /// The callback is `@Sendable` because the walk hops off the caller's
    /// isolation domain; accumulate results in a `ScanItemCollector` (or any
    /// other synchronised box) rather than in a captured `var`.
    ///
    /// Cancellation: this method cooperatively checks `Task.isCancelled`
    /// between entries.
    public func walk(
        roots: [String],
        options: Options,
        onEntry: @Sendable (String, FileMetadata) throws -> EnumerationAction
    ) async throws {
        let skipGlobs = options.skipPathPatterns.map {
            matcher.compile(matcher.expand($0))
        }
        let referenceDate = Date()
        let ageCutoffSeconds: TimeInterval? = options.olderThanDays.map {
            TimeInterval($0) * 86_400
        }

        var resultsEmitted = 0

        for root in roots {
            if Task.isCancelled { return }
            let expandedRoot = matcher.expand(root)
            guard fs.exists(expandedRoot) else { continue }

            // Skip the root itself if it matches a skip pattern.
            if matchesAny(regexes: skipGlobs, path: expandedRoot) { continue }

            // Emit the root's own contents, not the root itself.
            do {
                try fs.enumerate(
                    root: expandedRoot,
                    includeHidden: options.includeHidden,
                    followSymlinks: options.followSymlinks
                ) { path, meta in
                    // Cooperative cancellation: throw out of the whole walk
                    // rather than merely pruning one subtree.
                    try Task.checkCancellation()
                    if let cap = options.maxResults, resultsEmitted >= cap { return .skipDescendants }

                    // Skip pattern check
                    if !skipGlobs.isEmpty, matchesAny(regexes: skipGlobs, path: path) {
                        return meta.isDirectory ? .skipDescendants : .continueEnumeration
                    }

                    // Bundle extension pruning
                    if meta.isDirectory, !options.bundleExtensions.isEmpty {
                        let ext = (path as NSString).pathExtension.lowercased()
                        if options.bundleExtensions.contains(".\(ext)") || options.bundleExtensions.contains(ext) {
                            // Treat as opaque: report it, then prune.
                            if self.passesFilters(path: path, meta: meta, options: options,
                                                  referenceDate: referenceDate,
                                                  ageCutoff: ageCutoffSeconds) {
                                resultsEmitted += 1
                                _ = try onEntry(path, meta)
                            }
                            return .skipDescendants
                        }
                    }

                    // Regular filters
                    guard passesFilters(path: path, meta: meta, options: options,
                                        referenceDate: referenceDate,
                                        ageCutoff: ageCutoffSeconds) else {
                        return .continueEnumeration
                    }

                    resultsEmitted += 1
                    return try onEntry(path, meta)
                }
            } catch is CancellationError {
                // Cancellation is not an unreadable root — propagate it.
                throw CancellationError()
            } catch {
                // Unreadable root: keep going with the others.
                continue
            }
        }
    }

    /// Non-streaming convenience: collect everything into an array.
    public func collect(roots: [String], options: Options) async throws -> [(String, FileMetadata)] {
        let box = ScanCollector<(String, FileMetadata)>()
        try await walk(roots: roots, options: options) { path, meta in
            box.append((path, meta))
            return .continueEnumeration
        }
        return box.drain()
    }

    // MARK: - Filters

    private func passesFilters(
        path: String,
        meta: FileMetadata,
        options: Options,
        referenceDate: Date,
        ageCutoff: TimeInterval?
    ) -> Bool {
        if let min = options.minSizeBytes {
            // For directories we let the caller decide; here we only enforce
            // the size filter on regular files. Directories pass through and
            // their children are filtered individually.
            if meta.isRegularFile {
                let effective = meta.allocatedSize > 0 ? meta.allocatedSize : meta.contentSize
                if effective < min { return false }
            }
        }

        if let cutoff = ageCutoff, meta.isRegularFile {
            // Prefer content access date; fall back to modification date.
            let reference = meta.contentAccessDate ?? meta.modificationDate
            if let ref = reference {
                let age = referenceDate.timeIntervalSince(ref)
                if age < cutoff { return false }
            } else {
                // No date info: skip rather than guess.
                return false
            }
        }

        if let allowed = options.allowedExtensions, meta.isRegularFile {
            let ext = (path as NSString).pathExtension.lowercased()
            if !allowed.contains(".\(ext)") && !allowed.contains(ext) { return false }
        }

        return true
    }

    private func matchesAny(regexes: [NSRegularExpression], path: String) -> Bool {
        let std = matcher.standardize(path)
        let ns = NSRange(std.startIndex..., in: std)
        for r in regexes where r.firstMatch(in: std, range: ns) != nil { return true }
        return false
    }
}

// MARK: - ScanCollector

/// Lock-guarded accumulator for results produced inside a `@Sendable` walk
/// callback. A captured `var` array cannot be mutated from such a closure, so
/// callers funnel their hits through one of these and `drain()` it when the
/// walk returns.
public final class ScanCollector<Element>: @unchecked Sendable {

    private let lock = NSLock()
    private var elements: [Element] = []

    public init() {}

    /// Append one element and return the new element count — convenient for
    /// throttling progress updates (`if collector.append(item) % 32 == 0`).
    @discardableResult
    public func append(_ element: Element) -> Int {
        lock.lock()
        elements.append(element)
        let count = elements.count
        lock.unlock()
        return count
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return elements.count
    }

    /// Fold over a snapshot of the accumulated elements, e.g. to sum sizes.
    public func fold<Result>(_ initial: Result, _ combine: (Result, Element) -> Result) -> Result {
        lock.lock()
        let snapshot = elements
        lock.unlock()
        return snapshot.reduce(initial, combine)
    }

    /// Return everything collected so far and empty the box.
    public func drain() -> [Element] {
        lock.lock()
        let out = elements
        elements = []
        lock.unlock()
        return out
    }
}
