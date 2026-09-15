//
//  SystemJunkViewModel.swift
//  CleanMac
//
//  Drives the System Junk module: loads the rule pack, runs the scanner,
//  tracks selection state, and coordinates cleans through CleanerService.
//

import Foundation
import SwiftUI
import Combine

@MainActor
public final class SystemJunkViewModel: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case scanning
        case reviewing
        case cleaning
        case completed(CleanManifest)
        case failed(String)
    }

    // MARK: - Dependencies

    private let ruleLoader: RuleLoader
    private let scanner: ScannerEngine
    private let cleaner: CleanerService
    private let settings: SettingsStore

    // MARK: - Published state

    @Published public var phase: Phase = .idle
    @Published public var progress: ScanProgress = .idle
    @Published public var cleanProgress: CleanProgress = .idle
    @Published public private(set) var items: [ScanItem] = []
    @Published public var selectedIDs: Set<String> = []
    @Published public var expandedCategories: Set<String> = []
    @Published public var rules: [Rule] = []
    @Published public var lastManifest: CleanManifest? = nil
    @Published public var errorMessage: String? = nil

    private var scanTask: Task<Void, Never>?

    public init(
        ruleLoader: RuleLoader,
        scanner: ScannerEngine,
        cleaner: CleanerService,
        settings: SettingsStore
    ) {
        self.ruleLoader = ruleLoader
        self.scanner = scanner
        self.cleaner = cleaner
        self.settings = settings
    }

    // MARK: - Derived state

    /// Items grouped by rule for display. Rules with no matches are hidden
    /// unless `includeEmpty` is true.
    public func groupedItems(includeEmpty: Bool = false) -> [(rule: Rule, items: [ScanItem])] {
        let visibleRules = rules.filter { rule in
            if rule.safety == .dangerous && !settings.showDangerousRules { return false }
            return true
        }
        let buckets = Dictionary(grouping: items, by: \.ruleID)
        return visibleRules.compactMap { rule in
            let groupItems = buckets[rule.id] ?? []
            if groupItems.isEmpty && !includeEmpty { return nil }
            return (rule: rule, items: groupItems)
        }
    }

    public var selectedItems: [ScanItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    public var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    public var totalFoundSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    public var canClean: Bool {
        !selectedItems.isEmpty && phase != .cleaning && phase != .scanning
    }

    public var isBusy: Bool {
        phase == .scanning || phase == .cleaning
    }

    // MARK: - Actions

    /// Load rules and start a fresh scan. Cancels any in-flight scan first.
    public func startScan() {
        cancelScan()
        errorMessage = nil

        let pack: RulePack
        do {
            pack = try ruleLoader.loadMerged(named: RulePackName.systemJunk)
        } catch {
            phase = .failed(L10n.string("Could not load rules: %@", "\(error.localizedDescription)"))
            return
        }

        // Filter out dangerous rules if the user hasn't opted in.
        let visibleRules = pack.rules.filter { rule in
            rule.safety != .dangerous || settings.showDangerousRules
        }
        self.rules = visibleRules

        phase = .scanning
        progress = ScanProgress(statusMessage: L10n.string("Preparing scan…"))
        items = []
        selectedIDs = []

        scanTask = Task { [weak self] in
            guard let self else { return }
            let runningApps = PathDenylist.currentRunningAppBundlePaths()

            // Progress arrives on an AsyncStream (spec §3) and is consumed
            // concurrently with the scan, so the counters animate while rules
            // are still being evaluated. Reading the stream in-line rather than
            // through a per-event `Task { @MainActor in … }` keeps events in
            // order and avoids spawning one task per progress event.
            let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
            async let found = self.scanner.scan(
                rules: visibleRules,
                runningAppBundlePaths: runningApps,
                progress: continuation
            )
            for await event in stream {
                self.progress = event
            }
            let results = await found

            guard !Task.isCancelled else { return }

            self.items = results.sorted { $0.size > $1.size }
            // Pre-select every safe item.
            self.selectedIDs = Set(results.filter(\.isSelectedByDefault).map(\.id))
            // Auto-expand categories with review/dangerous items so they're
            // not silently ignored.
            self.expandedCategories = Set(
                results.filter { $0.safety != .safe }.map(\.ruleID)
            )
            self.phase = results.isEmpty ? .idle : .reviewing
        }
    }

    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if phase == .scanning {
            phase = items.isEmpty ? .idle : .reviewing
        }
    }

    /// Toggle selection for a single item.
    public func toggle(item: ScanItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    /// Toggle every item belonging to a rule.
    public func toggle(rule: Rule, all itemsForRule: [ScanItem]) {
        let ids = Set(itemsForRule.map(\.id))
        let allSelected = ids.isSubset(of: selectedIDs)
        if allSelected {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
        }
    }

    public func selectAll() {
        selectedIDs = Set(items.filter { !$0.isReadOnly }.map(\.id))
    }

    public func deselectAll() {
        selectedIDs.removeAll()
    }

    /// Clean the currently selected items. Respects `confirmBeforeClean`.
    /// Returns true when the clean actually ran (false when cancelled).
    @discardableResult
    public func clean(confirmed: Bool) async -> Bool {
        guard canClean else { return false }
        if settings.confirmBeforeClean && !confirmed { return false }

        let toClean = selectedItems
        guard !toClean.isEmpty else { return false }

        phase = .cleaning
        cleanProgress = CleanProgress(itemsTotal: toClean.count, itemsProcessed: 0, bytesFreed: 0)

        let runningApps = PathDenylist.currentRunningAppBundlePaths()
        let manifest = await cleaner.clean(
            items: toClean,
            source: "system-junk",
            label: nil,
            runningAppBundlePaths: runningApps
        ) { [weak self] p in
            Task { @MainActor in self?.cleanProgress = p }
        }

        // Remove cleaned items from the visible list.
        let removedPaths = Set(manifest.entries.map(\.originalPath))
        items.removeAll { removedPaths.contains($0.path) }
        selectedIDs = Set(items.filter(\.isSelectedByDefault).map(\.id))

        settings.addBytesReclaimed(manifest.bytesReclaimed)
        lastManifest = manifest
        phase = .completed(manifest)
        return true
    }

    /// Reset back to idle without rescanning.
    public func reset() {
        phase = .idle
        progress = .idle
        cleanProgress = .idle
        items = []
        selectedIDs = []
        lastManifest = nil
        errorMessage = nil
    }

    /// Reveal an item in Finder.
    public func reveal(_ item: ScanItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
