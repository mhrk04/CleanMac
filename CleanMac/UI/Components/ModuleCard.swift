//
//  ModuleCard.swift
//  CleanMac
//
//  Big clickable card used on the Smart Scan landing page and in module
//  headers. Shows an icon, title, subtitle, and optional size badge.
//

import SwiftUI

public struct ModuleCard: View {
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public var accentColor: Color = Theme.Colors.accent
    public var sizeBytes: Int64? = nil
    public var itemCount: Int? = nil
    public var isEnabled: Bool = true
    public var isBusy: Bool = false
    public var onTap: () -> Void

    @State private var isHovered = false

    public init(
        title: String,
        subtitle: String,
        systemImage: String,
        accentColor: Color = Theme.Colors.accent,
        sizeBytes: Int64? = nil,
        itemCount: Int? = nil,
        isEnabled: Bool = true,
        isBusy: Bool = false,
        onTap: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accentColor = accentColor
        self.sizeBytes = sizeBytes
        self.itemCount = itemCount
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: { if isEnabled && !isBusy { onTap() } }) {
            HStack(alignment: .top, spacing: 14) {
                iconBadge
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if sizeBytes != nil || itemCount != nil {
                        HStack(spacing: 8) {
                            if let bytes = sizeBytes {
                                SizeBadge(bytes: bytes, style: .tint(accentColor))
                            }
                            if let count = itemCount {
                                Text(L10n.string("%@ items", "\(count)"))
                                    .font(Theme.Typography.micro)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                trailingIndicator
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge, style: .continuous)
                    .strokeBorder(
                        isHovered && isEnabled
                            ? AnyShapeStyle(accentColor.opacity(0.5))
                            : AnyShapeStyle(Color.clear),
                        lineWidth: 1
                    )
            )
            .hoverLift(isHovered && isEnabled)
            .opacity(isEnabled ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.string("%@. %@", title, subtitle)))
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accentColor.opacity(0.32), accentColor.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accentColor)
        }
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if isBusy {
            ProgressView().controlSize(.small).tint(accentColor)
        } else if isEnabled {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
                .padding(.top, 4)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        ModuleCard(
            title: L10n.string("System Junk"),
            subtitle: L10n.string("Caches, logs, language files and more."),
            systemImage: "externaldrive.badge.timemachine",
            sizeBytes: 3_400_000_000,
            itemCount: 148,
            onTap: {}
        )
        ModuleCard(
            title: L10n.string("Uninstaller"),
            subtitle: L10n.string("Remove apps and all their leftover files."),
            systemImage: "app.badge.trash",
            accentColor: Theme.Colors.warning,
            onTap: {}
        )
        ModuleCard(
            title: L10n.string("Large & Old Files"),
            subtitle: L10n.string("Find big files you haven't opened in months."),
            systemImage: "doc.text.magnifyingglass",
            accentColor: Theme.Colors.info,
            isBusy: true,
            onTap: {}
        )
        ModuleCard(
            title: L10n.string("Disabled module"),
            subtitle: L10n.string("This card is not interactive."),
            systemImage: "lock",
            isEnabled: false,
            onTap: {}
        )
    }
    .padding()
    .frame(width: 480)
    .background(Theme.Colors.background)
}
