//
//  UninstallerViewModel.swift
//  CleanMac
//
//  Drives the Uninstaller module: enumerates installed apps, finds leftovers
//  for the selected app, tracks per-item selection, and coordinates the
//  quit-then-trash flow through CleanerService.
//

import Foundation
import SwiftUI
import Combine
import AppKit

@MainActor
public final class UninstallerViewModel: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case loadingApps
        case scanningLeftovers
        case reviewing
        case quitting
        case cleaning
        case completed(CleanManifest)
        case failed(String)
    }

    // MARK: - Dependencies

    private let appScanner: InstalledAppScanner
    private let leftoverFinder: LeftoverFinder
    private let cleaner: CleanerService
    /// Exposed so the view can bind the "show system apps" toggle.
    public let settings: SettingsStore
    private let fs: FileSystem

    // MARK: - Published state

    @Published public var phase: Phase = .idle
    @Published public private(set) var apps: [AppBundleInfo] = []
    @Published public var selectedAppID: String? = nil
    @Published public var searchText: String = ""
    @Published public var includeSystemApps: Bool = false
    @Published public private(set) var leftovers: [ScanItem] = []
    @Published public var selectedIDs: Set<String> = []
    @Published public var expandedCategories: Set<String> = []
    @Published public var cleanProgress: CleanProgress = .idle
    @Published public var lastManifest: CleanManifest? = nil
    @Published public var errorMessage: String? = nil
    @Published public var quitWarning: String? = nil

    private var loadTask: Task<Void, Never>?
    private var leftoverTask: Task<Void, Never>?

    public init(
        fileSystem: FileSystem,
        appScanner: InstalledAppScanner,
        leftoverFinder: LeftoverFinder,
        cleaner: CleanerService,
        settings: SettingsStore
    ) {
        self.fs = fileSystem
        self.appScanner = appScanner
        self.leftoverFinder = leftoverFinder
        self.cleaner = cleaner
        self.settings = settings
        self.includeSystemApps = settings.uninstallIncludeSystemApps
    }

    // MARK: - Derived

    public var filteredApps: [AppBundleInfo] {
        let base = includeSystemApps ? apps : apps.filter { !$0.isSystemApp }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter {
            $0.presentationName.lowercased().contains(q)
            || $0.bundleIdentifier.lowercased().contains(q)
        }
    }

    public var selectedApp: AppBundleInfo? {
        guard let id = selectedAppID else { return nil }
        return apps.first { $0.id == id }
    }

    public var groupedLeftovers: [(category: RuleCategory, items: [ScanItem])] {
        leftovers.groupedByCategory()
    }

    public var selectedItems: [ScanItem] {
        leftovers.filter { selectedIDs.contains($0.id) }
    }

    public var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    public var totalLeftoverSize: Int64 {
        leftovers.reduce(0) { $0 + $1.size }
    }

    public var canUninstall: Bool {
        guard let app = selectedApp else { return false }
        if app.isSystemApp { return false }
        return !selectedItems.isEmpty && phase != .cleaning && phase != .quitting
    }

    public var isBusy: Bool {
        phase == .loadingApps || phase == .scanningLeftovers || phase == .cleaning || phase == .quitting
    }

    // MARK: - Actions

    /// Load the list of installed apps. Safe to call repeatedly; cancels any
    /// in-flight load first.
    public func loadApps() {
        loadTask?.cancel()
        phase = .loadingApps
        errorMessage = nil

        loadTask = Task { [weak self] in
            guard let self else { return }
            let running = RunningAppSnapshot.captureAll()
            let found = self.appScanner.scan(
                includeSystemApps: true,   // always load; UI filters
                computeSizes: false,       // sizes computed lazily on selection
                runningApps: running
            )
            guard !Task.isCancelled else { return }
            self.apps = found
            self.phase = .idle
            // Auto-select the first non-system app if nothing is selected.
            if self.selectedAppID == nil {
                self.selectedAppID = found.first { !$0.isSystemApp }?.id
            }
        }
    }

    /// Compute the size of a single app bundle (called lazily when the user
    /// selects an app so the initial list loads fast).
    public func computeSize(for app: AppBundleInfo) async -> Int64 {
        await Task.detached(priority: .utility) { [fs = self.fs] in
            SizeCalculator(fileSystem: fs).size(of: app.path)
        }.value
    }

    /// Select an app and scan for its leftovers.
    public func selectApp(_ app: AppBundleInfo) {
        selectedAppID = app.id
        quitWarning = nil
        scanLeftovers(for: app)
    }

    public func scanLeftovers(for app: AppBundleInfo) {
        leftoverTask?.cancel()
        phase = .scanningLeftovers
        leftovers = []
        selectedIDs = []
        expandedCategories = []
        errorMessage = nil

        leftoverTask = Task { [weak self] in
            guard let self else { return }
            let running = PathDenylist.currentRunningAppBundlePaths()
            let found = await self.leftoverFinder.findLeftovers(
                for: app,
                runningAppBundlePaths: running
            )
            guard !Task.isCancelled else { return }

            self.leftovers = found
            // Pre-select everything except read-only items and the app bundle
            // itself when the app is a system app.
            self.selectedIDs = Set(found.filter { item in
                guard !item.isReadOnly else { return false }
                return item.isSelectedByDefault
            }.map(\.id))

            // Auto-expand categories with review items so they're visible.
            self.expandedCategories = Set(found.filter { $0.safety != .safe }.map(\.ruleID))

            if app.isRunning {
                self.quitWarning = L10n.string(
                    "%@ is currently running. It will be quit before uninstalling.", 
                    "\(app.presentationName)")
            }
            self.phase = .reviewing
        }
    }

    public func toggle(item: ScanItem) {
        guard !item.isReadOnly else { return }
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
        else { selectedIDs.insert(item.id) }
    }

    public func toggle(category: RuleCategory, items: [ScanItem]) {
        let ids = Set(items.filter { !$0.isReadOnly }.map(\.id))
        let allSelected = !ids.isEmpty && ids.isSubset(of: selectedIDs)
        if allSelected { selectedIDs.subtract(ids) }
        else { selectedIDs.formUnion(ids) }
    }

    public func selectAll() {
        selectedIDs = Set(leftovers.filter { !$0.isReadOnly }.map(\.id))
    }

    public func deselectAll() {
        selectedIDs.removeAll()
    }

    /// Uninstall the selected app: quit if running, then move the app bundle
    /// and every selected leftover to the Trash.
    @discardableResult
    public func uninstall(confirmed: Bool) async -> Bool {
        guard let app = selectedApp, canUninstall else { return false }
        if settings.confirmBeforeClean && !confirmed { return false }
        if app.isSystemApp {
            errorMessage = L10n.string(
                "%@ is a system app and cannot be removed.", 
                "\(app.presentationName)")
            return false
        }

        let toClean = selectedItems
        guard !toClean.isEmpty else { return false }

        // 1. Quit the app if it's running.
        if app.isRunning, !app.runningPIDs.isEmpty {
            phase = .quitting
            let success = await AppQuitter.quit(pids: app.runningPIDs, timeout: 5.0)
            if !success {
                errorMessage = L10n.string(
                    "Could not quit %@. Close it manually and try again.", 
                    "\(app.presentationName)")
                phase = .reviewing
                return false
            }
            // Give launchd a moment to release file handles.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // 2. Move everything to Trash.
        phase = .cleaning
        cleanProgress = CleanProgress(itemsTotal: toClean.count, itemsProcessed: 0, bytesFreed: 0)

        let running = PathDenylist.currentRunningAppBundlePaths()
        let manifest = await cleaner.clean(
            items: toClean,
            source: "uninstaller",
            label: L10n.string("Uninstall %@", "\(app.presentationName)"),
            runningAppBundlePaths: running
        ) { [weak self] p in
            Task { @MainActor in self?.cleanProgress = p }
        }

        // 3. Update local state.
        let removedPaths = Set(manifest.entries.map(\.originalPath))
        leftovers.removeAll { removedPaths.contains($0.path) }
        apps.removeAll { removedPaths.contains($0.path) }
        selectedIDs = []
        selectedAppID = nil

        settings.addBytesReclaimed(manifest.bytesReclaimed)
        lastManifest = manifest
        phase = .completed(manifest)
        return true
    }

    /// Reset back to the app list without reloading.
    public func reset() {
        phase = apps.isEmpty ? .idle : .reviewing
        leftovers = []
        selectedIDs = []
        selectedAppID = nil
        lastManifest = nil
        errorMessage = nil
        quitWarning = nil
    }

    public func reveal(_ item: ScanItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    public func revealApp(_ app: AppBundleInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
    }
}
