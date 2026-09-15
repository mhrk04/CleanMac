//
//  AppDelegate.swift
//  CleanMac
//
//  NSApplicationDelegate shim. SwiftUI owns the windows; this handles the
//  bits SwiftUI can't: activation policy, re-open behaviour, permission
//  polling lifecycle, and the app-wide menu commands.
//

import AppKit
import SwiftUI
import Combine

public final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Injected by `CleanMacApp` before the app finishes launching.
    @MainActor public weak var environment: AppEnvironment?

    public override init() {
        super.init()
    }

    // MARK: - Launch

    public func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Regular app with a Dock icon. The menu bar item is additive
            // and toggled from Settings.
            NSApp.setActivationPolicy(.regular)

            // Match the app's dark navy chrome regardless of system theme —
            // the UI is designed dark-only.
            NSApp.appearance = NSAppearance(named: .darkAqua)

            // The layout is a fixed two-pane design; below these sizes the
            // module lists collapse into each other.
            let minSize = NSSize(width: Theme.Metrics.windowMinWidth,
                                 height: Theme.Metrics.windowMinHeight)
            for window in NSApp.windows {
                window.minSize = minSize
                window.isMovableByWindowBackground = false
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }

            environment?.bootstrap()
            environment?.startPeriodicRefresh()
            environment?.permissions.startPolling()
        }
    }

    // MARK: - Reopen (Dock icon click with no windows)

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated {
                for window in sender.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        return true
    }

    // MARK: - Termination

    public func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            environment?.stopPeriodicRefresh()
            environment?.permissions.stopPolling()
        }
    }

    /// Never block quit — nothing here keeps unsaved state.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu commands

    /// Wired into SwiftUI's `Commands` so the standard menus behave.
    @MainActor
    public func runSmartScan() {
        environment?.smartScan.startScan()
        selectSidebarItem(.smartScan)
    }

    @MainActor
    public func openModule(_ item: SidebarItem) {
        selectSidebarItem(item)
    }

    @MainActor
    private func selectSidebarItem(_ item: SidebarItem) {
        environment?.settings.selectedSidebarItem = item.rawValue
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
