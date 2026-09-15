//
//  SmartScanViewModel.swift
//  CleanMac
//
//  Orchestrates the Smart Scan landing module: runs three sub-scans
//  concurrently (System Junk rules, Large & Old Files, orphaned app
//  leftovers), aggregates the results into a single review list, and
//  drives one unified clean through CleanerService.
//

import Foundation
import SwiftUI
import Combine

@MainActor
public final class SmartScanViewModel: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case scanning
        case reviewing
        case cleaning
        case completed(CleanManifest)
        case failed(String)
    }

    /// Per-module status shown on each of the three Smart Scan cards.
    public struct ModuleStatus: Equatable, Identifiable {
        public let id: String
        public let name: String
        public let systemImage: String
        public let accent: Color
        public var itemCount: Int = 0
        public var sizeBytes: Int64 = 0
        public var isRunning: Bool = false
        public var isComplete: Bool = false
        public var errorMessage: String? = nil

        public init(
            id: String,
            name: String,
            systemImage: String,
            accent: Color
        ) {
            self.id = id
            self.name = name
            self.systemImage = systemImage
            self.accent = accent
        }

        public var stateLabel: String {
            if let errorMessage { return errorMessage }
            if isRunning { return L10n.string("Scanning…") }
            if isComplete {
                return itemCount == 0
                    ? L10n.string("Nothing to clean")
                    : L10n.plural("%@ item", "%@ items", itemCount)
            }
            return L10n.string("Ready")
        }
    }

    // MARK: - Dependencies

    private let ruleLoader: RuleLoader
    private let scanner: ScannerEngine
    private let walker: FileWalker
    private let matcher: PathMatcher
    private let leftoverFinder: LeftoverFinder
    private let appScanner: InstalledAppScanner
    private let cleaner: CleanerService
    private let history: HistoryStore
    private let fs: FileSystem
    public let settings: SettingsStore
    public let largeFilesConfig: LargeFilesConfig

    // MARK: - Published state

    @Published public var phase: Phase = .idle
    @Published public var progress: ScanProgress = .idle
    @Published public var cleanProgress: CleanProgress = .idle

    @Published public var junkStatus = ModuleStatus(
        id: "junk", name: L10n.string("System Junk"), systemImage: "trash.square.fill",
        accent: Theme.Colors.accent
    )
    @Published public var largeStatus = ModuleStatus(
        id: "large", name: L10n.string("Large & Old Files"), systemImage: "externaldrive.fill",
        accent: Theme.Colors.info
    )
    @Published public var orphanStatus = ModuleStatus(
        id: "orphans", name: L10n.string("Uninstaller Leftovers"), systemImage: "app.dashed",
        accent: Theme.Colors.warning
    )

    @Published public private(set) var junkItems: [ScanItem] = []
    @Published public private(set) var largeItems: [ScanItem] = []
    @Published public private(set) var orphanItems: [ScanItem] = []

    @Published public var selectedIDs: Set<String> = []
    /// When true, review-safety items are pre-selected alongside safe ones.
    @Published public var includeReviewItems: Bool = false
    @Published public var lastManifest: CleanManifest? = nil
    @Published public var errorMessage: String? = nil

    /// Aggregate history stats for the landing hero.
    @Published public var totalReclaimedAllTime: Int64 = 0
    @Published public var cleanCountAllTime: Int = 0
    @Published public var lastCleanDate: Date? = nil
    @Published public var lastScanDate: Date? = nil

    private var scanTask: Task<Void, Never>?

    public init(
        fileSystem: FileSystem,
        ruleLoader: RuleLoader,
        scanner: ScannerEngine,
        leftoverFinder: LeftoverFinder,
        appScanner: InstalledAppScanner = InstalledAppScanner(),
        cleaner: CleanerService,
        history: HistoryStore,
        settings: SettingsStore,
        largeFilesConfig: LargeFilesConfig = .empty
    ) {
        self.fs = fileSystem
        self.ruleLoader = ruleLoader
        self.scanner = scanner
        self.matcher = PathMatcher()
        self.walker = FileWalker(fileSystem: fileSystem, matcher: PathMatcher())
        self.leftoverFinder = leftoverFinder
        self.appScanner = appScanner
        self.cleaner = cleaner
        self.history = history
        self.settings = settings
        self.largeFilesConfig = largeFilesConfig
        self.lastScanDate = settings.lastSmartScanDate
    }

    // MARK: - Derived

    public var allItems: [ScanItem] { junkItems + largeItems + orphanItems }

    /// Items the safety layer considers safe to remove without review.
    public var safeItems: [ScanItem] { allItems.filter { $0.safety == .safe && !$0.isReadOnly } }

    /// Items that need an explicit human decision.
    public var reviewItems: [ScanItem] { allItems.filter { $0.safety != .safe || $0.isReadOnly } }

    public var selectedItems: [ScanItem] { allItems.filter { selectedIDs.contains($0.id) } }

    public var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    public var totalFoundSize: Int64 { allItems.reduce(0) { $0 + $1.size } }

    public var hasResults: Bool { !allItems.isEmpty }

    public var canClean: Bool {
        !selectedItems.isEmpty && phase != .cleaning && phase != .scanning
    }

    public var isBusy: Bool { phase == .scanning || phase == .cleaning }

    public var moduleStatuses: [ModuleStatus] { [junkStatus, largeStatus, orphanStatus] }

    /// Weighted completion across the three sub-scans, for the hero ring.
    public var overallProgress: Double {
        let junk = junkStatus.isComplete ? 1.0 : (junkStatus.isRunning ? progress.fractionComplete * 0.6 : 0)
        let large = largeStatus.isComplete ? 1.0 : (largeStatus.isRunning ? 0.5 : 0)
        let orphan = orphanStatus.isComplete ? 1.0 : (orphanStatus.isRunning ? 0.4 : 0)
        return min(1, (junk + large + orphan) / 3)
    }

    public var heroValue: String {
        switch phase {
        // A bare percentage is a numeric figure, not copy: like the
        // `ByteCount` values below it is rendered verbatim and never looked
        // up. (It must not go through `L10n.string` — the trailing `%` would
        // be an unterminated conversion specifier in the format string.)
        case .scanning: return "\(Int(overallProgress * 100))%"
        case .cleaning: return ByteCount.compact(cleanProgress.bytesFreed)
        case .completed(let m): return ByteCount.format(m.bytesReclaimed)
        default: return ByteCount.format(totalFoundSize)
        }
    }

    public var heroLabel: String {
        switch phase {
        case .scanning: return L10n.string("Scanning")
        case .cleaning: return L10n.string("Freed so far")
        case .completed: return L10n.string("Reclaimed")
        case .reviewing: return L10n.string("Found")
        case .failed: return L10n.string("Scan failed")
        case .idle:
            return lastScanDate == nil
                ? L10n.string("Ready to scan")
                : L10n.string("Ready to rescan")
        }
    }

    public var heroSubtitle: String {
        switch phase {
        case .scanning:
            // A path component is data, never copy: it must survive
            // untranslated whatever locale is active.
            return progress.currentPath.map { (lastComponent(of: $0)) }
                ?? progress.statusMessage
                ?? L10n.string("Working…")
        case .reviewing:
            // Both counts pluralise independently, so each clause is built on
            // its own and then composed. Positional placeholders keep the word
            // order translatable.
            let items = L10n.plural("%@ item", "%@ items", allItems.count)
            let modules = L10n.plural("%@ module", "%@ modules", activeModuleCount)
            return L10n.string("%1$@ across %2$@", "\(items)", "\(modules)")
        case .cleaning:
            return L10n.string(
                "%@/%@ items processed", 
                "\(cleanProgress.itemsProcessed)", 
                "\(cleanProgress.itemsTotal)"
            )
        case .completed(let m):
            let failed = m.failures.count
            return failed == 0
                ? L10n.string("Everything went to the Trash")
                : L10n.plural(
                    "%@ item could not be removed",
                    "%@ items could not be removed",
                    failed
                )
        case .failed(let message): return message
        case .idle:
            if let d = lastScanDate {
                // `RelativeDateTimeFormatter` is already locale-aware.
                return L10n.string(
                    "Last scan %@", 
                    "\(Self.relativeFormatter.localizedString(for: d, relativeTo: Date()))")
            }
            return L10n.string("Junk, large files, and leftover app data in one pass")
        }
    }

    private var activeModuleCount: Int {
        moduleStatuses.filter { $0.itemCount > 0 }.count
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private func lastComponent(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // MARK: - History

    public func refreshHistoryStats() {
        Task { [history] in
            let total = await history.totalReclaimed()
            let count = await history.cleanCount()
            let last = await history.lastCleanDate()
            await MainActor.run { [weak self] in
                self?.totalReclaimedAllTime = total
                self?.cleanCountAllTime = count
                self?.lastCleanDate = last
            }
        }
    }

    // MARK: - Scan

    public func startScan() {
        cancelScan()
        errorMessage = nil
        junkItems = []
        largeItems = []
        orphanItems = []
        selectedIDs = []
        lastManifest = nil
        junkStatus = ModuleStatus(id: junkStatus.id, name: junkStatus.name,
                                  systemImage: junkStatus.systemImage, accent: junkStatus.accent)
        largeStatus = ModuleStatus(id: largeStatus.id, name: largeStatus.name,
                                   systemImage: largeStatus.systemImage, accent: largeStatus.accent)
        orphanStatus = ModuleStatus(id: orphanStatus.id, name: orphanStatus.name,
                                    systemImage: orphanStatus.systemImage, accent: orphanStatus.accent)
        junkStatus.isRunning = true
        largeStatus.isRunning = true
        orphanStatus.isRunning = true
        phase = .scanning
        progress = ScanProgress(statusMessage: L10n.string("Preparing scan…"))

        scanTask = Task { [weak self] in
            guard let self else { return }
            let runningApps = PathDenylist.currentRunningAppBundlePaths()
            let runningSnapshots = RunningAppSnapshot.captureAll()

            async let junk = self.runJunkScan(runningAppBundlePaths: runningApps)
            async let large = self.runLargeScan()
            async let orphans = self.runOrphanScan(
                runningApps: runningSnapshots,
                runningAppBundlePaths: runningApps
            )

            let (j, l, o) = await (junk, large, orphans)

            guard !Task.isCancelled else { return }

            self.junkItems = j.sorted { $0.size > $1.size }
            self.largeItems = Array(l.sorted { $0.size > $1.size }.prefix(500))
            self.orphanItems = o.sorted { $0.size > $1.size }

            self.applyModuleStatuses()
            self.applyDefaultSelection()

            self.settings.lastSmartScanDate = Date()
            self.lastScanDate = self.settings.lastSmartScanDate
            self.progress = ScanProgress(
                itemsFound: self.allItems.count,
                bytesFound: self.totalFoundSize,
                fractionComplete: 1,
                isFinished: true,
                statusMessage: L10n.string("Scan complete")
            )

            if let firstError = [self.junkStatus.errorMessage,
                                 self.largeStatus.errorMessage,
                                 self.orphanStatus.errorMessage].compactMap({ $0 }).first,
               self.allItems.isEmpty {
                self.phase = .failed(firstError)
            } else {
                self.phase = .reviewing
            }
            self.refreshHistoryStats()
        }
    }

    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if phase == .scanning {
            phase = allItems.isEmpty ? .idle : .reviewing
            junkStatus.isRunning = false
            largeStatus.isRunning = false
            orphanStatus.isRunning = false
        }
    }

    private func applyModuleStatuses() {
        junkStatus.isRunning = false
        junkStatus.isComplete = true
        junkStatus.itemCount = junkItems.count
        junkStatus.sizeBytes = junkItems.reduce(0) { $0 + $1.size }

        largeStatus.isRunning = false
        largeStatus.isComplete = true
        largeStatus.itemCount = largeItems.count
        largeStatus.sizeBytes = largeItems.reduce(0) { $0 + $1.size }

        orphanStatus.isRunning = false
        orphanStatus.isComplete = true
        orphanStatus.itemCount = orphanItems.count
        orphanStatus.sizeBytes = orphanItems.reduce(0) { $0 + $1.size }
    }

    /// Safe items are always pre-selected; review items only when opted in.
    private func applyDefaultSelection() {
        var ids = Set<String>()
        ids.formUnion(safeItems.map(\.id))
        if includeReviewItems {
            ids.formUnion(reviewItems.filter { !$0.isReadOnly }.map(\.id))
        }
        selectedIDs = ids
    }

    public func setIncludeReviewItems(_ include: Bool) {
        includeReviewItems = include
        if phase == .reviewing { applyDefaultSelection() }
    }

    // MARK: - Sub-scans

    private func runJunkScan(runningAppBundlePaths: Set<String>) async -> [ScanItem] {
        let pack: RulePack
        do {
            pack = try ruleLoader.loadMerged(named: RulePackName.systemJunk)
        } catch {
            await MainActor.run {
                self.junkStatus.errorMessage = L10n.string("Could not load rules")
                self.junkStatus.isRunning = false
                self.junkStatus.isComplete = true
            }
            return []
        }

        let rules = pack.rules.filter { $0.safety != .dangerous || settings.showDangerousRules }

        let found = await scanner.scan(
            rules: rules,
            runningAppBundlePaths: runningAppBundlePaths
        ) { [weak self] p in
            Task { @MainActor in self?.progress = p }
        }

        await MainActor.run {
            self.junkStatus.isRunning = false
            self.junkStatus.isComplete = true
            self.junkStatus.itemCount = found.count
            self.junkStatus.sizeBytes = found.reduce(0) { $0 + $1.size }
        }
        return found
    }

    private func runLargeScan() async -> [ScanItem] {
        let thresholdMB = max(settings.largeFileSizeThresholdMB, largeFilesConfig.sizeThresholdMB)
        let ageDays = settings.largeFileAgeDays > 0 ? settings.largeFileAgeDays : largeFilesConfig.ageDaysThreshold

        var roots = settings.largeFileSearchRoots.isEmpty
            ? largeFilesConfig.searchRoots
            : settings.largeFileSearchRoots
        if roots.isEmpty { roots = ["~/Downloads", "~/Documents", "~/Desktop", "~/Movies", "~/Music", "~/Pictures"] }
        roots = roots.map { matcher.expand($0) }

        var options = FileWalker.Options(
            includeHidden: false,
            followSymlinks: false,
            skipPathPatterns: largeFilesConfig.skipPaths,
            bundleExtensions: largeFilesConfig.bundleExtensions,
            minSizeBytes: Int64(thresholdMB) * 1024 * 1024,
            olderThanDays: ageDays > 0 ? ageDays : nil,
            allowedExtensions: nil,
            maxResults: 5_000
        )
        if !settings.largeFileIncludeLibrary {
            options.skipPathPatterns.append("~/Library")
        }

        // The walker callback is `@Sendable`: snapshot the config it needs and
        // collect hits in a lock-guarded box rather than a captured `var`.
        let protectedExtensions = largeFilesConfig.protectedExtensions
        let collector = ScanCollector<ScanItem>()
        do {
            try await walker.walk(roots: roots, options: options) { path, meta in
                if Task.isCancelled { return .skipDescendants }
                guard meta.isRegularFile else { return .continueEnumeration }

                let ext = "." + (path as NSString).pathExtension.lowercased()
                if protectedExtensions.contains(ext) {
                    return .continueEnumeration
                }

                let size = meta.allocatedSize > 0 ? meta.allocatedSize : meta.contentSize
                collector.append(ScanItem(
                    path: path,
                    ruleID: "smart-scan-large",
                    ruleName: L10n.string("Large & Old File"),
                    category: .other,
                    // Large user files always need a human decision.
                    safety: .review,
                    size: size,
                    isDirectory: false,
                    modificationDate: meta.modificationDate,
                    contentAccessDate: meta.contentAccessDate
                ))
                return .continueEnumeration
            }
        } catch {
            self.largeStatus.errorMessage = error.localizedDescription
            self.largeStatus.isRunning = false
            self.largeStatus.isComplete = true
            return []
        }

        let collected = collector.drain()
        self.largeStatus.isRunning = false
        self.largeStatus.isComplete = true
        self.largeStatus.itemCount = collected.count
        self.largeStatus.sizeBytes = collected.reduce(0) { $0 + $1.size }
        return collected
    }

    private func runOrphanScan(
        runningApps: [RunningAppSnapshot],
        runningAppBundlePaths: Set<String>
    ) async -> [ScanItem] {
        let installed = appScanner.scan(
            includeSystemApps: true,
            computeSizes: false,
            runningApps: runningApps
        )
        let bundleIDs = Set(installed.compactMap { $0.bundleIdentifier.isEmpty ? nil : $0.bundleIdentifier })

        let found = await leftoverFinder.findOrphanedLeftovers(
            installedBundleIDs: bundleIDs,
            runningAppBundlePaths: runningAppBundlePaths
        )

        await MainActor.run {
            self.orphanStatus.isRunning = false
            self.orphanStatus.isComplete = true
            self.orphanStatus.itemCount = found.count
            self.orphanStatus.sizeBytes = found.reduce(0) { $0 + $1.size }
        }
        return found
    }

    // MARK: - Selection

    public func toggle(item: ScanItem) {
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
        else { selectedIDs.insert(item.id) }
    }

    public func toggleModule(_ id: String) {
        let items: [ScanItem]
        switch id {
        case "junk": items = junkItems
        case "large": items = largeItems
        case "orphans": items = orphanItems
        default: return
        }
        let ids = items.filter { !$0.isReadOnly }.map(\.id)
        let allSelected = !ids.isEmpty && ids.allSatisfy { selectedIDs.contains($0) }
        if allSelected {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
        }
    }

    public func isModuleFullySelected(_ id: String) -> Bool {
        let items: [ScanItem]
        switch id {
        case "junk": items = junkItems
        case "large": items = largeItems
        case "orphans": items = orphanItems
        default: return false
        }
        let ids = items.filter { !$0.isReadOnly }.map(\.id)
        return !ids.isEmpty && ids.allSatisfy { selectedIDs.contains($0) }
    }

    public func selectAllSafe() {
        selectedIDs.formUnion(safeItems.map(\.id))
    }

    public func deselectAll() {
        selectedIDs.removeAll()
    }

    public func reveal(_ item: ScanItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Clean

    @discardableResult
    public func clean(confirmed: Bool) async -> Bool {
        guard canClean else { return false }
        if settings.confirmBeforeClean && !confirmed { return false }

        let toClean = selectedItems.filter { !$0.isReadOnly }
        guard !toClean.isEmpty else { return false }

        phase = .cleaning
        cleanProgress = CleanProgress(itemsTotal: toClean.count, itemsProcessed: 0, bytesFreed: 0)
        let runningApps = PathDenylist.currentRunningAppBundlePaths()

        let manifest = await cleaner.clean(
            items: toClean,
            source: "smart-scan",
            label: L10n.string("Smart Scan"),
            runningAppBundlePaths: runningApps
        ) { [weak self] p in
            Task { @MainActor in self?.cleanProgress = p }
        }

        let removedPaths = Set(manifest.entries.map(\.originalPath))
        junkItems.removeAll { removedPaths.contains($0.path) }
        largeItems.removeAll { removedPaths.contains($0.path) }
        orphanItems.removeAll { removedPaths.contains($0.path) }
        selectedIDs = []
        applyModuleStatuses()

        settings.addBytesReclaimed(manifest.bytesReclaimed)
        lastManifest = manifest
        phase = .completed(manifest)
        refreshHistoryStats()
        return true
    }

    public func reset() {
        phase = .idle
        junkItems = []
        largeItems = []
        orphanItems = []
        selectedIDs = []
        lastManifest = nil
        errorMessage = nil
        junkStatus.itemCount = 0
        junkStatus.sizeBytes = 0
        junkStatus.isComplete = false
        largeStatus.itemCount = 0
        largeStatus.sizeBytes = 0
        largeStatus.isComplete = false
        orphanStatus.itemCount = 0
        orphanStatus.sizeBytes = 0
        orphanStatus.isComplete = false
    }
}
