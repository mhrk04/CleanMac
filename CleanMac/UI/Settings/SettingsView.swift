//
//  SettingsView.swift
//  CleanMac
//
//  Application settings. Uses Form-style grouped sections with themed
//  backgrounds so it matches the rest of the app rather than the standard
//  macOS Settings chrome.
//

import SwiftUI

public struct SettingsView: View {
    @ObservedObject public var settings: SettingsStore
    @ObservedObject public var permissions: PermissionCenter
    public var historyDirectory: String
    public var onRevealHistory: () -> Void
    public var onResetHistory: () -> Void
    public var totalReclaimed: Int64

    public init(
        settings: SettingsStore,
        permissions: PermissionCenter,
        historyDirectory: String,
        totalReclaimed: Int64,
        onRevealHistory: @escaping () -> Void,
        onResetHistory: @escaping () -> Void
    ) {
        self.settings = settings
        self.permissions = permissions
        self.historyDirectory = historyDirectory
        self.totalReclaimed = totalReclaimed
        self.onRevealHistory = onRevealHistory
        self.onResetHistory = onResetHistory
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                headerSection
                permissionsSection
                scanningSection
                historySection
                advancedSection
                aboutSection
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .themedBackground()
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("Settings"))
                .font(Theme.Typography.heroNumber)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(L10n.string("Configure scanning behaviour, permissions, and history."))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        SettingsSection(title: L10n.string("Permissions"), systemImage: "lock.shield") {
            PermissionRow(
                title: L10n.string("Full Disk Access"),
                description: L10n.string("Required to scan system caches and other apps' containers."),
                granted: permissions.fullDiskAccessGranted,
                actionTitle: permissions.fullDiskAccessGranted ? L10n.string("Show in System Settings") : L10n.string("Grant Access")
            ) {
                permissions.openSystemSettings(for: .fullDiskAccess)
            }
            PermissionRow(
                title: L10n.string("Accessibility"),
                description: L10n.string("Optional. Used for the Startup Items module (coming soon)."),
                granted: permissions.accessibilityGranted,
                actionTitle: permissions.accessibilityGranted ? L10n.string("Show in System Settings") : L10n.string("Grant Access")
            ) {
                permissions.promptForAccessibility()
                permissions.openSystemSettings(for: .accessibility)
            }
        }
    }

    // MARK: - Scanning

    private var scanningSection: some View {
        SettingsSection(title: L10n.string("Scanning"), systemImage: "magnifyingglass") {
            Toggle(isOn: Binding(
                get: { settings.showDangerousRules },
                set: { settings.showDangerousRules = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Show advanced rules"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(L10n.string("Reveals rules marked 'dangerous'. Read every description before enabling."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.Colors.accent)

            Divider().background(Theme.Colors.separator)

            Toggle(isOn: Binding(
                get: { settings.confirmBeforeClean },
                set: { settings.confirmBeforeClean = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Confirm before cleaning"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(L10n.string("Shows a review sheet before moving items to Trash."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.Colors.accent)

            Divider().background(Theme.Colors.separator)

            Toggle(isOn: Binding(
                get: { settings.uninstallIncludeSystemApps },
                set: { settings.uninstallIncludeSystemApps = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("List system apps in Uninstaller"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(L10n.string("Shows /System/Applications entries as read-only reference rows."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.Colors.accent)
        }
    }

    // MARK: - History

    private var historySection: some View {
        SettingsSection(title: L10n.string("History"), systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.string("Total reclaimed"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Spacer()
                    Text(ByteCount.format(totalReclaimed))
                        .font(Theme.Typography.body)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                HStack {
                    Text(L10n.string("Storage"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Spacer()
                    Text(historyDirectory)
                        .pathStyle()
                }
                HStack(spacing: 10) {
                    GhostButton(L10n.string("Reveal in Finder"), systemImage: "folder") { onRevealHistory() }
                    GhostButton(L10n.string("Delete all history"), systemImage: "trash", role: .destructive) {
                        onResetHistory()
                    }
                    Spacer()
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        SettingsSection(title: L10n.string("Advanced"), systemImage: "gearshape.2") {
            Toggle(isOn: Binding(
                get: { settings.showMenuBarExtra },
                set: { settings.showMenuBarExtra = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Show menu bar item"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(L10n.string("Displays free disk space and a quick-scan shortcut in the menu bar."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.Colors.accent)

            Divider().background(Theme.Colors.separator)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Reset CleanMac"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(L10n.string("Restores every setting to its default value. History is preserved."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                GhostButton(L10n.string("Reset"), systemImage: "arrow.counterclockwise", role: .destructive) {
                    settings.resetAll()
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsSection(title: L10n.string("About"), systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("CleanMac 1.0.0"))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(L10n.string("A rule-driven, trash-first cleaner for macOS 14 and later."))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(L10n.string("Not affiliated with MacPaw Inc. CleanMyMac is a trademark of MacPaw."))
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Reusable section container

public struct SettingsSection<Content: View>: View {
    public let title: String
    public let systemImage: String
    @ViewBuilder public var content: Content

    public init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .tracking(0.6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.Colors.surfaceElevated.opacity(0.6))

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
        }
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Theme.Colors.separator, lineWidth: 1)
        )
    }
}

// MARK: - Permission row

private struct PermissionRow: View {
    let title: String
    let description: String
    let granted: Bool
    let actionTitle: String
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(granted ? Theme.Colors.success : Theme.Colors.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(description)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
            GhostButton(actionTitle, systemImage: "gearshape") { onAction() }
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView(
        settings: SettingsStore(),
        permissions: PermissionCenter(),
        historyDirectory: HistoryStore.defaultDirectory(),
        totalReclaimed: 42_000_000_000,
        onRevealHistory: {},
        onResetHistory: {}
    )
    .frame(width: 720, height: 640)
}
