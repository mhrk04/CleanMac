//
//  SidebarView.swift
//  CleanMac
//
//  Left-hand navigation. Lists the four modules, a History shortcut, and
//  Settings. Selection is bound to SettingsStore.selectedSidebarItem so it
//  persists across launches.
//

import SwiftUI

public enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    case smartScan = "smart-scan"
    case systemJunk = "system-junk"
    case uninstaller = "uninstaller"
    case largeAndOld = "large-and-old"
    case history = "history"
    case settings = "settings"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smartScan: return L10n.string("Smart Scan")
        case .systemJunk: return L10n.string("System Junk")
        case .uninstaller: return L10n.string("Uninstaller")
        case .largeAndOld: return L10n.string("Large & Old Files")
        case .history: return L10n.string("History")
        case .settings: return L10n.string("Settings")
        }
    }

    public var systemImage: String {
        switch self {
        case .smartScan: return "sparkles"
        case .systemJunk: return "externaldrive.badge.timemachine"
        case .uninstaller: return "trash.square.fill"
        case .largeAndOld: return "doc.text.magnifyingglass"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }

    public var accent: Color {
        switch self {
        case .smartScan: return Theme.Colors.accent
        case .systemJunk: return Theme.Colors.accentSecondary
        case .uninstaller: return Theme.Colors.warning
        case .largeAndOld: return Theme.Colors.info
        case .history: return Theme.Colors.textSecondary
        case .settings: return Theme.Colors.textSecondary
        }
    }

    /// Sections group the sidebar into "Modules" and "App".
    public var section: Section {
        switch self {
        case .smartScan, .systemJunk, .uninstaller, .largeAndOld: return .modules
        case .history, .settings: return .app
        }
    }

    public enum Section: String, CaseIterable {
        case modules
        case app

        public var label: String {
            switch self {
            case .modules: return L10n.string("Modules")
            case .app: return ""
            }
        }
    }
}

public struct SidebarView: View {
    @ObservedObject public var settings: SettingsStore
    @ObservedObject public var permissions: PermissionCenter
    /// Optional per-item badge counts (e.g. items found in the last scan).
    public var badges: [SidebarItem: String] = [:]

    @Binding public var selection: SidebarItem

    public init(
        settings: SettingsStore,
        permissions: PermissionCenter,
        selection: Binding<SidebarItem>,
        badges: [SidebarItem: String] = [:]
    ) {
        self.settings = settings
        self.permissions = permissions
        self._selection = selection
        self.badges = badges
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    section(.modules)
                    section(.app)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }

            permissionFooter
        }
        .frame(width: Theme.Metrics.sidebarWidth)
        .background(Theme.Colors.backgroundAlt)
    }

    // MARK: - Header

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.Gradients.accent)
                    .frame(width: 30, height: 30)
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.string("CleanMac"))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(L10n.string("v1.0"))
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(_ section: SidebarItem.Section) -> some View {
        let items = SidebarItem.allCases.filter { $0.section == section }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if !section.label.isEmpty {
                    Text(section.label.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                }
                ForEach(items) { item in
                    row(for: item)
                }
            }
        }
    }

    private func row(for item: SidebarItem) -> some View {
        let isSelected = selection == item
        return Button(action: { selection = item }) {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : item.accent)
                    .frame(width: 18)
                Text(item.title)
                    .font(Theme.Typography.sidebarItem)
                    .foregroundStyle(isSelected ? .white : Theme.Colors.textPrimary)
                Spacer(minLength: 0)
                if let badge = badges[item] {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.22) : Theme.Colors.surfaceElevated))
                        .foregroundStyle(isSelected ? .white : Theme.Colors.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Theme.Gradients.accent) : AnyShapeStyle(Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var permissionFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().background(Theme.Colors.separator)
            HStack(spacing: 8) {
                Circle()
                    .fill(permissions.fullDiskAccessGranted
                          ? Theme.Colors.success
                          : Theme.Colors.warning)
                    .frame(width: 7, height: 7)
                Text(permissions.fullDiskAccessGranted
                     ? L10n.string("Full Disk Access on")
                     : L10n.string("Full Disk Access needed"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                if !permissions.fullDiskAccessGranted {
                    Button(L10n.string("Fix")) {
                        permissions.openSystemSettings(for: .fullDiskAccess)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var selection: SidebarItem = .smartScan
    SidebarView(
        settings: SettingsStore(),
        permissions: PermissionCenter(),
        selection: $selection,
        badges: [.systemJunk: L10n.string("3.4 GB"), .uninstaller: "12"]
    )
}
