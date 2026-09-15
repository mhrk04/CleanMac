//
//  SettingsStore.swift
//  CleanMac
//
//  Central place for every persisted user preference. Wraps UserDefaults
//  with typed accessors so views don't sprinkle raw keys everywhere.
//

import Foundation
import Combine

public final class SettingsStore: ObservableObject, @unchecked Sendable {

    public enum Keys {
        public static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
        public static let selectedSidebarItem = "settings.selectedSidebarItem"
        public static let showMenuBarExtra = "settings.showMenuBarExtra"
        public static let showDangerousRules = "settings.showDangerousRules"
        public static let largeFileSizeThresholdMB = "settings.largeFileSizeThresholdMB"
        public static let largeFileAgeDays = "settings.largeFileAgeDays"
        public static let largeFileSearchRoots = "settings.largeFileSearchRoots"
        public static let largeFileIncludeLibrary = "settings.largeFileIncludeLibrary"
        public static let uninstallIncludeSystemApps = "settings.uninstallIncludeSystemApps"
        public static let lastSmartScanDate = "settings.lastSmartScanDate"
        public static let totalBytesReclaimed = "settings.totalBytesReclaimed"
        public static let confirmBeforeClean = "settings.confirmBeforeClean"
        public static let theme = "settings.theme"
    }

    /// Appearance options. The MVP ships dark only; the key is persisted now
    /// so a light/auto theme can be added later without a migration.
    public enum Appearance: String, CaseIterable, Sendable {
        case dark
    }

    private let defaults: UserDefaults
    private let publisher = PassthroughSubject<Void, Never>()
    private var changeCancellable: AnyCancellable?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
        // Bridge the manual publisher into `objectWillChange` so views that
        // observe the store re-render when any preference changes.
        changeCancellable = publisher.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.hasCompletedOnboarding: false,
            Keys.selectedSidebarItem: "smart-scan",
            Keys.showMenuBarExtra: true,
            Keys.showDangerousRules: false,
            Keys.largeFileSizeThresholdMB: 100,
            Keys.largeFileAgeDays: 180,
            Keys.largeFileIncludeLibrary: false,
            Keys.uninstallIncludeSystemApps: false,
            Keys.totalBytesReclaimed: 0,
            Keys.confirmBeforeClean: true,
            Keys.theme: Appearance.dark.rawValue
        ])
    }

    /// Publisher that fires whenever any setting changes. Views can subscribe
    /// when they need to react to a settings change without observing every
    /// key individually.
    public var changes: AnyPublisher<Void, Never> { publisher.eraseToAnyPublisher() }

    // MARK: - Onboarding

    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedOnboarding); publisher.send() }
    }

    // MARK: - Navigation

    public var selectedSidebarItem: String {
        get { defaults.string(forKey: Keys.selectedSidebarItem) ?? "smart-scan" }
        set { defaults.set(newValue, forKey: Keys.selectedSidebarItem); publisher.send() }
    }

    // MARK: - Menu bar

    public var showMenuBarExtra: Bool {
        get { defaults.bool(forKey: Keys.showMenuBarExtra) }
        set { defaults.set(newValue, forKey: Keys.showMenuBarExtra); publisher.send() }
    }

    // MARK: - Rule visibility

    public var showDangerousRules: Bool {
        get { defaults.bool(forKey: Keys.showDangerousRules) }
        set { defaults.set(newValue, forKey: Keys.showDangerousRules); publisher.send() }
    }

    // MARK: - Large & Old Files

    public var largeFileSizeThresholdMB: Int {
        get { defaults.integer(forKey: Keys.largeFileSizeThresholdMB) }
        set { defaults.set(newValue, forKey: Keys.largeFileSizeThresholdMB); publisher.send() }
    }

    public var largeFileAgeDays: Int {
        get { defaults.integer(forKey: Keys.largeFileAgeDays) }
        set { defaults.set(newValue, forKey: Keys.largeFileAgeDays); publisher.send() }
    }

    public var largeFileSearchRoots: [String] {
        get { defaults.stringArray(forKey: Keys.largeFileSearchRoots) ?? [] }
        set { defaults.set(newValue, forKey: Keys.largeFileSearchRoots); publisher.send() }
    }

    public var largeFileIncludeLibrary: Bool {
        get { defaults.bool(forKey: Keys.largeFileIncludeLibrary) }
        set { defaults.set(newValue, forKey: Keys.largeFileIncludeLibrary); publisher.send() }
    }

    // MARK: - Uninstaller

    public var uninstallIncludeSystemApps: Bool {
        get { defaults.bool(forKey: Keys.uninstallIncludeSystemApps) }
        set { defaults.set(newValue, forKey: Keys.uninstallIncludeSystemApps); publisher.send() }
    }

    // MARK: - Appearance

    public var theme: Appearance {
        get { Appearance(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .dark }
        set { defaults.set(newValue.rawValue, forKey: Keys.theme); publisher.send() }
    }

    // MARK: - Smart Scan bookkeeping

    public var lastSmartScanDate: Date? {
        get {
            let t = defaults.double(forKey: Keys.lastSmartScanDate)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Keys.lastSmartScanDate)
            publisher.send()
        }
    }

    public var totalBytesReclaimed: Int64 {
        get { Int64(defaults.double(forKey: Keys.totalBytesReclaimed)) }
        set { defaults.set(Double(newValue), forKey: Keys.totalBytesReclaimed); publisher.send() }
    }

    public func addBytesReclaimed(_ bytes: Int64) {
        totalBytesReclaimed = totalBytesReclaimed + bytes
    }

    // MARK: - Safety

    public var confirmBeforeClean: Bool {
        get { defaults.bool(forKey: Keys.confirmBeforeClean) }
        set { defaults.set(newValue, forKey: Keys.confirmBeforeClean); publisher.send() }
    }

    // MARK: - Reset

    /// Wipe every setting. Useful in tests and in the "Reset CleanMac" button.
    public func resetAll() {
        for key in [
            Keys.hasCompletedOnboarding,
            Keys.selectedSidebarItem,
            Keys.showMenuBarExtra,
            Keys.showDangerousRules,
            Keys.largeFileSizeThresholdMB,
            Keys.largeFileAgeDays,
            Keys.largeFileSearchRoots,
            Keys.largeFileIncludeLibrary,
            Keys.uninstallIncludeSystemApps,
            Keys.lastSmartScanDate,
            Keys.totalBytesReclaimed,
            Keys.confirmBeforeClean
        ] {
            defaults.removeObject(forKey: key)
        }
        registerDefaults()
        publisher.send()
    }
}
