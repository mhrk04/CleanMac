//
//  AppEnvironment.swift
//  CleanMac
//
//  Composition root. Builds the file-system abstraction, rule loader,
//  scanner, cleaner, stores, and every module view model exactly once,
//  then hands them to the views. Keeping wiring here means tests can
//  build the same graph with a `MockFileSystem`.
//

import Foundation
import SwiftUI
import Combine

@MainActor
public final class AppEnvironment: ObservableObject {

    // MARK: - Core services

    public let fileSystem: FileSystem
    public let matcher: PathMatcher
    public let denylist: PathDenylist
    public let settings: SettingsStore
    public let permissions: PermissionCenter
    public let ruleLoader: RuleLoader
    public let scanner: ScannerEngine
    public let history: HistoryStore
    public let cleaner: CleanerService
    public let leftoverFinder: LeftoverFinder
    public let appScanner: InstalledAppScanner
    public let largeFilesConfig: LargeFilesConfig

    // MARK: - Module view models

    public let smartScan: SmartScanViewModel
    public let systemJunk: SystemJunkViewModel
    public let uninstaller: UninstallerViewModel
    public let largeAndOld: LargeAndOldViewModel
    public let historyModule: HistoryViewModel

    // MARK: - Live state

    @Published public var volumeInfo: VolumeInfo? = nil
    /// Non-fatal startup problem (e.g. a rule pack failed to load).
    @Published public var bootstrapWarning: String? = nil

    private var volumeTimer: Timer?

    public init(fileSystem: FileSystem = LiveFileSystem(),
                settings: SettingsStore = SettingsStore()) {
        // Build the shared service graph once, then hand the same instances
        // to every module so state stays consistent across screens.
        let matcher = PathMatcher()
        let denylist = PathDenylist()
        let permissions = PermissionCenter()
        let ruleLoader = RuleLoader(fileSystem: fileSystem)
        let scanner = ScannerEngine(fileSystem: fileSystem, matcher: matcher, denylist: denylist)
        let history = HistoryStore(fileSystem: fileSystem)
        let cleaner = CleanerService(fileSystem: fileSystem, history: history, denylist: denylist)
        let leftoverFinder = LeftoverFinder(
            fileSystem: fileSystem,
            scanner: scanner,
            ruleLoader: ruleLoader,
            matcher: matcher
        )
        let appScanner = InstalledAppScanner(fileSystem: fileSystem)

        // Large & Old Files tuning lives in a rule pack so users can edit it.
        var config = LargeFilesConfig.empty
        var warning: String? = nil
        do {
            let pack = try ruleLoader.loadMerged(named: RulePackName.largeFilesDefaults)
            config = LargeFilesConfig.decode(from: pack)
        } catch {
            warning = "Could not load large-file defaults (\(error.localizedDescription)). Using built-in values."
        }

        self.fileSystem = fileSystem
        self.settings = settings
        self.matcher = matcher
        self.denylist = denylist
        self.permissions = permissions
        self.ruleLoader = ruleLoader
        self.scanner = scanner
        self.history = history
        self.cleaner = cleaner
        self.leftoverFinder = leftoverFinder
        self.appScanner = appScanner
        self.largeFilesConfig = config
        self.bootstrapWarning = warning

        self.systemJunk = SystemJunkViewModel(
            ruleLoader: ruleLoader,
            scanner: scanner,
            cleaner: cleaner,
            settings: settings
        )

        self.uninstaller = UninstallerViewModel(
            fileSystem: fileSystem,
            appScanner: appScanner,
            leftoverFinder: leftoverFinder,
            cleaner: cleaner,
            settings: settings
        )

        self.largeAndOld = LargeAndOldViewModel(
            fileSystem: fileSystem,
            cleaner: cleaner,
            settings: settings,
            config: config
        )

        self.smartScan = SmartScanViewModel(
            fileSystem: fileSystem,
            ruleLoader: ruleLoader,
            scanner: scanner,
            leftoverFinder: leftoverFinder,
            appScanner: appScanner,
            cleaner: cleaner,
            history: history,
            settings: settings,
            largeFilesConfig: config
        )

        self.historyModule = HistoryViewModel(
            history: history,
            cleaner: cleaner,
            settings: settings
        )
    }

    // MARK: - Lifecycle

    /// Refresh permissions, disk usage, and history totals.
    public func bootstrap() {
        permissions.refresh()
        refreshVolumeInfo()
        smartScan.refreshHistoryStats()
        historyModule.load()
    }

    /// Start a low-frequency poll so the menu bar popover and sidebar badge
    /// stay honest about free disk space and Full Disk Access.
    public func startPeriodicRefresh(interval: TimeInterval = 30) {
        stopPeriodicRefresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshVolumeInfo()
                self?.permissions.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        volumeTimer = timer
    }

    public func stopPeriodicRefresh() {
        volumeTimer?.invalidate()
        volumeTimer = nil
    }

    public func refreshVolumeInfo() {
        do {
            volumeInfo = try fileSystem.volumeInfo(forPath: "/")
        } catch {
            volumeInfo = nil
        }
    }

    // MARK: - Convenience

    /// Where CleanManifest JSON files live. Computed statically so callers
    /// don't have to hop into the HistoryStore actor.
    public var historyDirectory: String { HistoryStore.defaultDirectory() }

    public var totalReclaimedAllTime: Int64 { smartScan.totalReclaimedAllTime }

    /// Reset every persisted preference and wipe the history log.
    public func resetEverything() {
        settings.resetAll()
        Task { [history] in
            try? await history.deleteAll()
            await MainActor.run { [weak self] in
                self?.smartScan.refreshHistoryStats()
                self?.historyModule.load()
            }
        }
    }
}
