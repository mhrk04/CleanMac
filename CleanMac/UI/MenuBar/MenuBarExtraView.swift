//
//  MenuBarExtraView.swift
//  CleanMac
//
//  Compact popover shown when the user clicks the menu bar icon.
//  Displays free disk space, last scan info, and quick actions.
//

import SwiftUI

public struct MenuBarExtraView: View {
    @ObservedObject public var settings: SettingsStore
    public var volumeInfo: VolumeInfo?
    public var lastScanDate: Date?
    public var totalReclaimed: Int64
    public var onOpenMainWindow: () -> Void
    public var onRunSmartScan: () -> Void

    public init(
        settings: SettingsStore,
        volumeInfo: VolumeInfo?,
        lastScanDate: Date?,
        totalReclaimed: Int64,
        onOpenMainWindow: @escaping () -> Void,
        onRunSmartScan: @escaping () -> Void
    ) {
        self.settings = settings
        self.volumeInfo = volumeInfo
        self.lastScanDate = lastScanDate
        self.totalReclaimed = totalReclaimed
        self.onOpenMainWindow = onOpenMainWindow
        self.onRunSmartScan = onRunSmartScan
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Colors.separator)
            diskSection
            Divider().background(Theme.Colors.separator)
            statsSection
            Divider().background(Theme.Colors.separator)
            actions
        }
        .frame(width: 280)
        .background(Theme.Colors.backgroundAlt)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.Gradients.accent)
                    .frame(width: 22, height: 22)
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(L10n.string("CleanMac"))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Colors.textPrimary)
            Spacer()
            Text(L10n.string("v1.0"))
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Disk

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let info = volumeInfo {
                Text(info.name)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(ByteCount.format(info.availableCapacity))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .contentTransition(.numericText())
                Text(L10n.string("free of %@", "\(ByteCount.format(info.totalCapacity))"))
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)

                // Capacity bar
                GeometryReader { geo in
                    let usedFraction = info.totalCapacity > 0
                        ? Double(info.totalCapacity - info.availableCapacity) / Double(info.totalCapacity)
                        : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.Colors.surfaceElevated)
                        Capsule()
                            .fill(barColor(for: usedFraction))
                            .frame(width: geo.size.width * usedFraction)
                    }
                }
                .frame(height: 5)
                .padding(.top, 2)
            } else {
                Text(L10n.string("Disk info unavailable"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func barColor(for fraction: Double) -> AnyShapeStyle {
        switch fraction {
        case ..<0.7: return AnyShapeStyle(Theme.Colors.success)
        case ..<0.9: return AnyShapeStyle(Theme.Colors.warning)
        default: return AnyShapeStyle(Theme.Colors.danger)
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            statRow(
                label: L10n.string("Last scan"),
                value: lastScanDate.map {
                    Self.relativeFormatter.localizedString(for: $0, relativeTo: Date())
                } ?? L10n.string("Never")
            )
            statRow(
                label: L10n.string("Total reclaimed"),
                value: ByteCount.format(totalReclaimed)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(Theme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.textPrimary)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 6) {
            Button(action: onRunSmartScan) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(L10n.string("Run Smart Scan"))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Theme.Gradients.accent)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Button(action: onOpenMainWindow) {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                        Text(L10n.string("Open CleanMac"))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text(L10n.string("Quit"))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Preview

#Preview {
    MenuBarExtraView(
        settings: SettingsStore(),
        volumeInfo: VolumeInfo(
            mountPoint: "/",
            name: L10n.string("Macintosh HD"),
            totalCapacity: 1_000_000_000_000,
            availableCapacity: 187_400_000_000,
            isRemovable: false,
            isInternal: true
        ),
        lastScanDate: Date().addingTimeInterval(-3600),
        totalReclaimed: 42_300_000_000,
        onOpenMainWindow: {},
        onRunSmartScan: {}
    )
}
