//
//  CleanMacApp.swift
//  CleanMac
//
//  App entry point. Owns the single `AppEnvironment`, renders the sidebar +
//  module split view, wires the menu commands, the optional menu bar item,
//  and the first-launch onboarding sheet.
//

import SwiftUI
import AppKit

@main
public struct CleanMacApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var environment = AppEnvironment()

    /// The environment owns the single settings store; views observe that
    /// same instance so a change anywhere re-renders everywhere.
    private var settings: SettingsStore { environment.settings }

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView(environment: environment, settings: settings)
                .frame(
                    minWidth: Theme.Metrics.windowMinWidth,
                    minHeight: Theme.Metrics.windowMinHeight
                )
                .preferredColorScheme(.dark)
                .environmentObject(environment)
                .environmentObject(settings)
                .onAppear { appDelegate.environment = environment }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CleanMacCommands(appDelegate: appDelegate, environment: environment)
        }

        // Menu bar item — user-toggleable from Settings.
        MenuBarExtra(isInserted: Binding(
            get: { settings.showMenuBarExtra },
            set: { settings.showMenuBarExtra = $0 }
        )) {
            MenuBarExtraView(
                settings: settings,
                volumeInfo: environment.volumeInfo,
                lastScanDate: environment.smartScan.lastScanDate,
                totalReclaimed: environment.smartScan.totalReclaimedAllTime,
                onOpenMainWindow: { openMainWindow() },
                onRunSmartScan: {
                    openMainWindow()
                    settings.selectedSidebarItem = SidebarItem.smartScan.rawValue
                    environment.smartScan.startScan()
                }
            )
        } label: {
            // The product name is a brand, not copy: routing it through
            // `verbatim` keeps it out of the translation table, which a bare
            // literal would not (SwiftUI would read it as a LocalizedStringKey).
            Label(L10n.verbatim("CleanMac"), systemImage: "internaldrive.fill")
        }
        .menuBarExtraStyle(.window)
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}

// MARK: - Root view

public struct RootView: View {
    @ObservedObject public var environment: AppEnvironment
    @ObservedObject public var settings: SettingsStore

    @State private var showOnboarding = false

    public init(environment: AppEnvironment, settings: SettingsStore) {
        self.environment = environment
        self.settings = settings
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(
                settings: settings,
                permissions: environment.permissions,
                selection: selectionBinding,
                badges: sidebarBadges
            )
            // Pinned to exactly 220pt: the sidebar is a fixed chrome rail, not
            // a column the user is meant to resize (spec §11).
            .navigationSplitViewColumnWidth(
                min: Theme.Metrics.sidebarWidth,
                ideal: Theme.Metrics.sidebarWidth,
                max: Theme.Metrics.sidebarWidth
            )
        } detail: {
            moduleContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // No collapse toggle: hiding the module list would leave the detail
        // pane with no way to switch modules.
        .toolbar(removing: .sidebarToggle)
        .themedBackground()
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet(
                permissions: environment.permissions,
                settings: settings
            ) {
                showOnboarding = false
                settings.hasCompletedOnboarding = true
                environment.permissions.refresh()
            }
        }
        .alert(L10n.string("Rules could not be loaded"), isPresented: warningBinding) {
            Button(L10n.string("OK"), role: .cancel) { environment.bootstrapWarning = nil }
        } message: {
            // Already-localised (or a rule-loader diagnostic), so render verbatim.
            Text(verbatim: environment.bootstrapWarning ?? "")
        }
        .onAppear {
            if !settings.hasCompletedOnboarding {
                // Delay one runloop turn so the sheet attaches to a window
                // that actually exists.
                DispatchQueue.main.async { showOnboarding = true }
            }
        }
    }

    private var selectionBinding: Binding<SidebarItem> {
        Binding(
            get: { SidebarItem(rawValue: settings.selectedSidebarItem) ?? .smartScan },
            set: { settings.selectedSidebarItem = $0.rawValue }
        )
    }

    private var warningBinding: Binding<Bool> {
        Binding(
            get: { environment.bootstrapWarning != nil },
            set: { if !$0 { environment.bootstrapWarning = nil } }
        )
    }

    /// Per-item badges so the sidebar hints at what the last scan found.
    private var sidebarBadges: [SidebarItem: String] {
        var badges: [SidebarItem: String] = [:]
        if environment.smartScan.junkStatus.isComplete, environment.smartScan.junkStatus.itemCount > 0 {
            badges[.systemJunk] = "\(environment.smartScan.junkStatus.itemCount)"
        }
        if environment.smartScan.largeStatus.isComplete, environment.smartScan.largeStatus.itemCount > 0 {
            badges[.largeAndOld] = "\(environment.smartScan.largeStatus.itemCount)"
        }
        if environment.smartScan.orphanStatus.isComplete, environment.smartScan.orphanStatus.itemCount > 0 {
            badges[.uninstaller] = "\(environment.smartScan.orphanStatus.itemCount)"
        }
        return badges
    }

    @ViewBuilder
    private var moduleContent: some View {
        switch selectionBinding.wrappedValue {
        case .smartScan:
            SmartScanView(viewModel: environment.smartScan) { item in
                settings.selectedSidebarItem = item.rawValue
            }
        case .systemJunk:
            SystemJunkView(viewModel: environment.systemJunk)
        case .uninstaller:
            UninstallerView(viewModel: environment.uninstaller)
        case .largeAndOld:
            LargeAndOldView(viewModel: environment.largeAndOld)
        case .history:
            HistoryView(viewModel: environment.historyModule)
        case .settings:
            SettingsView(
                settings: settings,
                permissions: environment.permissions,
                historyDirectory: environment.historyDirectory,
                totalReclaimed: environment.smartScan.totalReclaimedAllTime,
                onRevealHistory: { environment.historyModule.revealStorageDirectory() },
                onResetHistory: { environment.historyModule.deleteAll() }
            )
        }
    }
}

// MARK: - Commands

public struct CleanMacCommands: Commands {
    private let appDelegate: AppDelegate
    private let environment: AppEnvironment

    public init(appDelegate: AppDelegate, environment: AppEnvironment) {
        self.appDelegate = appDelegate
        self.environment = environment
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L10n.string("Run Smart Scan")) { appDelegate.runSmartScan() }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
        }

        CommandMenu(L10n.string("Modules")) {
            ForEach(SidebarItem.allCases) { item in
                // `item.title` is already localised at its source.
                Button(item.title) { appDelegate.openModule(item) }
            }
        }

        CommandMenu(L10n.string("Clean")) {
            Button(L10n.string("Select All Safe Items")) { environment.smartScan.selectAllSafe() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!environment.smartScan.hasResults)
            Button(L10n.string("Deselect All")) { environment.smartScan.deselectAll() }
                .disabled(!environment.smartScan.hasResults)
            Divider()
            Button(L10n.string("Reveal History Folder")) { environment.historyModule.revealStorageDirectory() }
        }
    }
}
