//
//  LargeAndOldViewModel.swift
//  CleanMac
//
//  Drives the Large & Old Files module. Walks user-chosen folders, filters
//  by size and age, and paginates results for the UI.
//

import Foundation
import SwiftUI
import Combine

@MainActor
public final class LargeAndOldViewModel: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case scanning
        case reviewing
        case cleaning
        case completed(CleanManifest)
        case failed(String)
    }

    public enum SortKey: String, CaseIterable, Identifiable {
        case size
        case name
        case lastOpened
        case path

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .size: return L10n.string("Size")
            case .name: return L10n.string("Name")
            case .lastOpened: return L10n.string("Last opened")
            case .path: return L10n.string("Path")
            }
        }
    }

    // MARK: - Dependencies

    private let fs: FileSystem
    private let walker: FileWalker
    private let matcher: PathMatcher
    private let cleaner: CleanerService
    /// Exposed so the view can bind the "include ~/Library" switch.
    public let settings: SettingsStore
    /// Exposed so the view can render the rule-pack presets.
    public let config: LargeFilesConfig

    // MARK: - Published state

    @Published public var phase: Phase = .idle
    @Published public var progress: ScanProgress = .idle
    @Published public var cleanProgress: CleanProgress = .idle
    @Published public private(set) var items: [ScanItem] = []
    @Published public var selectedIDs: Set<String> = []
    @Published public var searchRoots: [String] = []
    @Published public var sizeThresholdMB: Int = 100
    @Published public var ageDays: Int = 180
    @Published public var activePreset: LargeFilesConfig.Preset? = nil
    @Published public var sortKey: SortKey = .size
    @Published public var sortAscending: Bool = false
    @Published public var visibleCount: Int = 100
    @Published public var lastManifest: CleanManifest? = nil

    private var scanTask: Task<Void, Never>?

    public init(
        fileSystem: FileSystem,
        cleaner: CleanerService,
        settings: SettingsStore,
        config: LargeFilesConfig
    ) {
        self.fs = fileSystem
        self.matcher = PathMatcher()
        self.walker = FileWalker(fileSystem: fileSystem, matcher: PathMatcher())
        self.cleaner = cleaner
        self.settings = settings
        self.config = config

        // Seed from persisted settings, falling back to the rule pack.
        let persistedRoots = settings.largeFileSearchRoots
        self.searchRoots = persistedRoots.isEmpty ? config.searchRoots : persistedRoots
        self.sizeThresholdMB = settings.largeFileSizeThresholdMB
        self.ageDays = settings.largeFileAgeDays
    }

    // MARK: - Derived

    public var visibleItems: [ScanItem] {
        Array(sortedItems.prefix(visibleCount))
    }

    public var sortedItems: [ScanItem] {
        let filtered = items
        switch sortKey {
        case .size:
            return filtered.sorted { sortAscending ? $0.size < $1.size : $0.size > $1.size }
        case .name:
            return filtered.sorted {
                sortAscending
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.name.localizedStandardCompare($1.name) == .orderedDescending
            }
        case .lastOpened:
            return filtered.sorted {
                let a = $0.contentAccessDate ?? .distantPast
                let b = $1.contentAccessDate ?? .distantPast
                return sortAscending ? a < b : a > b
            }
        case .path:
            return filtered.sorted {
                sortAscending ? $0.path < $1.path : $0.path > $1.path
            }
        }
    }

    public var selectedItems: [ScanItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    public var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    public var canClean: Bool {
        !selectedItems.isEmpty && phase != .cleaning && phase != .scanning
    }

    // MARK: - Actions

    public func startScan() {
        cancelScan()
        let roots = effectiveSearchRoots()
        guard !roots.isEmpty else {
            phase = .failed(L10n.string("Choose at least one folder to scan."))
            return
        }

        phase = .scanning
        progress = ScanProgress(statusMessage: L10n.string("Preparing scan…"))
        items = []
        selectedIDs = []
        visibleCount = 100

        let minBytes = Int64(sizeThresholdMB) * 1024 * 1024
        let olderThan = ageDays > 0 ? ageDays : nil

        var walkerOptions = FileWalker.Options(
            includeHidden: false,
            followSymlinks: false,
            skipPathPatterns: config.skipPaths,
            bundleExtensions: config.bundleExtensions,
            minSizeBytes: minBytes,
            olderThanDays: olderThan,
            allowedExtensions: activePreset?.extensions.isEmpty == false ? activePreset?.extensions : nil,
            maxResults: 50_000
        )
        if !settings.largeFileIncludeLibrary {
            // Skip the user's Library folder entirely unless opted in.
            walkerOptions.skipPathPatterns.append("~/Library")
        }

        // The walker callback is `@Sendable`, so it may not touch MainActor
        // state. Snapshot everything it needs and funnel hits into a
        // lock-guarded collector instead of a captured `var`.
        let preset = activePreset
        let protectedExtensions = config.protectedExtensions
        let collector = ScanCollector<ScanItem>()
        let walker = self.walker

        scanTask = Task { [weak self] in
            do {
                try await walker.walk(roots: roots, options: walkerOptions) { path, meta in
                    if Task.isCancelled { return .skipDescendants }
                    guard meta.isRegularFile else { return .continueEnumeration }

                    // Skip protected extensions unless a preset overrides.
                    let ext = "." + (path as NSString).pathExtension.lowercased()
                    if preset == nil, protectedExtensions.contains(ext) {
                        return .continueEnumeration
                    }

                    // Skip preset path filter if set.
                    if let contains = preset?.pathContains,
                       !path.contains(contains) {
                        return .continueEnumeration
                    }

                    let size = meta.allocatedSize > 0 ? meta.allocatedSize : meta.contentSize
                    let count = collector.append(ScanItem(
                        path: path,
                        ruleID: "large-and-old",
                        ruleName: L10n.string("Large & Old File"),
                        category: .other,
                        safety: .safe,
                        size: size,
                        isDirectory: false,
                        modificationDate: meta.modificationDate,
                        contentAccessDate: meta.contentAccessDate
                    ))

                    // Throttled progress updates.
                    if count % 32 == 0 {
                        let bytes = collector.fold(Int64(0)) { $0 + $1.size }
                        Task { @MainActor in
                            self?.progress = ScanProgress(
                                currentPath: path,
                                itemsFound: count,
                                bytesFound: bytes,
                                fractionComplete: 0.5,
                                statusMessage: L10n.string("Scanning %@…", "\(path)")
                            )
                        }
                    }
                    return .continueEnumeration
                }
            } catch {
                self?.phase = .failed(error.localizedDescription)
                return
            }

            guard !Task.isCancelled else { return }
            guard let self else { return }

            let collected = collector.drain()
            self.items = collected
            self.progress = ScanProgress(
                itemsFound: collected.count,
                bytesFound: collected.reduce(0) { $0 + $1.size },
                fractionComplete: 1,
                isFinished: true,
                statusMessage: L10n.string("Scan complete")
            )
            self.phase = .reviewing
        }
    }

    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if phase == .scanning {
            phase = items.isEmpty ? .idle : .reviewing
        }
    }

    /// Merge persisted roots with any user-added folders.
    private func effectiveSearchRoots() -> [String] {
        var roots = searchRoots
        if roots.isEmpty { roots = config.searchRoots }
        // Always expand ~ so the walker doesn't have to.
        return roots.map { matcher.expand($0) }
    }

    public func addSearchRoot(_ path: String) {
        guard !searchRoots.contains(path) else { return }
        searchRoots.append(path)
        persistSearchRoots()
    }

    public func removeSearchRoot(_ path: String) {
        searchRoots.removeAll { $0 == path }
        persistSearchRoots()
    }

    private func persistSearchRoots() {
        settings.largeFileSearchRoots = searchRoots
    }

    public func applyPreset(_ preset: LargeFilesConfig.Preset?) {
        activePreset = preset
        if let p = preset {
            sizeThresholdMB = max(sizeThresholdMB, p.minSizeMB)
        }
        settings.largeFileSizeThresholdMB = sizeThresholdMB
    }

    public func setSizeThreshold(_ mb: Int) {
        sizeThresholdMB = mb
        settings.largeFileSizeThresholdMB = mb
    }

    public func setAgeDays(_ days: Int) {
        ageDays = days
        settings.largeFileAgeDays = days
    }

    public func toggle(item: ScanItem) {
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
        else { selectedIDs.insert(item.id) }
    }

    public func selectAllVisible() {
        selectedIDs.formUnion(visibleItems.map(\.id))
    }

    public func deselectAll() {
        selectedIDs.removeAll()
    }

    public func loadMore() {
        visibleCount = min(visibleCount + 100, items.count)
    }

    @discardableResult
    public func clean(confirmed: Bool) async -> Bool {
        guard canClean else { return false }
        if settings.confirmBeforeClean && !confirmed { return false }

        let toClean = selectedItems
        phase = .cleaning
        cleanProgress = CleanProgress(itemsTotal: toClean.count, itemsProcessed: 0, bytesFreed: 0)

        let manifest = await cleaner.clean(
            items: toClean,
            source: "large-and-old",
            label: nil
        ) { [weak self] p in
            Task { @MainActor in self?.cleanProgress = p }
        }

        let removedPaths = Set(manifest.entries.map(\.originalPath))
        items.removeAll { removedPaths.contains($0.path) }
        selectedIDs = []
        settings.addBytesReclaimed(manifest.bytesReclaimed)
        lastManifest = manifest
        phase = .completed(manifest)
        return true
    }

    public func reveal(_ item: ScanItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    public func quickLook(_ item: ScanItem) {
        // Quick Look previews the file in place. `NSWorkspace.open` would
        // launch it in its default editor instead — see `QuickLookPresenter`.
        QuickLookPresenter.shared.preview(item.url)
    }

    public func reset() {
        phase = .idle
        items = []
        selectedIDs = []
        lastManifest = nil
    }
}
