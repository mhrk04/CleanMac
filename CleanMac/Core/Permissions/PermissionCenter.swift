//
//  PermissionCenter.swift
//  CleanMac
//
//  Observable façade over the various permission probes. Views subscribe to
//  this to render onboarding prompts and settings indicators.
//

import Foundation
import AppKit
import Combine

@MainActor
public final class PermissionCenter: ObservableObject {

    public enum Kind: String, CaseIterable, Sendable {
        case fullDiskAccess
        case accessibility
        case automation       // Apple Events, needed for quit-before-uninstall
    }

    public struct Status: Equatable, Sendable {
        public var kind: Kind
        public var granted: Bool
        public var lastChecked: Date
        public init(kind: Kind, granted: Bool, lastChecked: Date = Date()) {
            self.kind = kind
            self.granted = granted
            self.lastChecked = lastChecked
        }
    }

    @Published public private(set) var statuses: [Kind: Status] = [:]

    private let fdaProbe: FullDiskAccessProbe
    private let axProbe: AccessibilityProbe
    private var pollTask: Task<Void, Never>?

    public init(
        fdaProbe: FullDiskAccessProbe = FullDiskAccessProbe(),
        axProbe: AccessibilityProbe = AccessibilityProbe()
    ) {
        self.fdaProbe = fdaProbe
        self.axProbe = axProbe
        refresh()
    }

    // MARK: - Queries

    public var fullDiskAccessGranted: Bool { statuses[.fullDiskAccess]?.granted ?? false }
    public var accessibilityGranted: Bool { statuses[.accessibility]?.granted ?? false }

    /// True when every permission required for a normal Smart Scan is granted.
    public var canPerformFullScan: Bool { fullDiskAccessGranted }

    // MARK: - Refresh

    /// Re-check every permission synchronously. Cheap enough to call on every
    /// window focus event.
    public func refresh() {
        statuses[.fullDiskAccess] = Status(kind: .fullDiskAccess, granted: fdaProbe.isGranted())
        statuses[.accessibility] = Status(kind: .accessibility, granted: axProbe.isGranted(prompt: false))
        // Automation is per-target (each app you want to send events to). We
        // optimistically report true; the actual failure surfaces when the
        // first quit event is sent.
        statuses[.automation] = Status(kind: .automation, granted: true)
    }

    /// Start polling every `interval` seconds. Polling stops when `predicate`
    /// returns true or the caller invokes `stopPolling()`. Used during
    /// onboarding so the UI updates the moment the user flips the switch in
    /// System Settings.
    ///
    /// The default predicate never fires, so callers who omit it must stop
    /// polling explicitly (e.g. when the onboarding sheet is dismissed).
    public func startPolling(
        interval: TimeInterval = 2.0,
        until predicate: @escaping @MainActor @Sendable () -> Bool = { false }
    ) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                if predicate() { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Deep links into System Settings

    /// Open the System Settings pane relevant to `kind`.
    public func openSystemSettings(for kind: Kind) {
        let urlString: String
        switch kind {
        case .fullDiskAccess:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .automation:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Trigger the OS-level prompt for Accessibility (only works once per
    /// process lifetime; subsequent calls are silent no-ops).
    public func promptForAccessibility() {
        _ = axProbe.isGranted(prompt: true)
    }
}
