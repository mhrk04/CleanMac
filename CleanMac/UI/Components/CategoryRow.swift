//
//  CategoryRow.swift
//  CleanMac
//
//  Disclosure row used in System Junk and Uninstaller to represent a group
//  of items (a rule or category). Shows a checkbox, icon, title, item count,
//  and total size, and expands to reveal the individual ScanItems.
//

import SwiftUI

public struct CategoryRow: View {
    public let title: String
    public let systemImage: String
    public let itemCount: Int
    public let sizeBytes: Int64
    public let accentColor: Color
    public let safety: SafetyLevel?
    @Binding public var isSelected: Bool
    @Binding public var isExpanded: Bool
    public var annotation: String? = nil
    public var detail: AnyView? = nil

    @State private var isHovered = false

    public init(
        title: String,
        systemImage: String,
        itemCount: Int,
        sizeBytes: Int64,
        accentColor: Color = Theme.Colors.accent,
        safety: SafetyLevel? = nil,
        isSelected: Binding<Bool>,
        isExpanded: Binding<Bool>,
        annotation: String? = nil,
        @ViewBuilder detail: () -> AnyView = { AnyView(EmptyView()) }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.itemCount = itemCount
        self.sizeBytes = sizeBytes
        self.accentColor = accentColor
        self.safety = safety
        self._isSelected = isSelected
        self._isExpanded = isExpanded
        self.annotation = annotation
        self.detail = detail()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().background(Theme.Colors.separator).padding(.leading, 52)
                detail
                    .padding(.leading, 52)
                    .padding(.trailing, 16)
                    .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .fill(isHovered ? Theme.Colors.surfaceElevated : Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Theme.Colors.separator, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .animation(Theme.Animation.standard, value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: 12) {
            checkbox
            iconBadge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    if let safety, safety != .safe {
                        safetyBadge(safety)
                    }
                }
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            SizeBadge(bytes: sizeBytes, style: .tint(accentColor))
            disclosureChevron
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Theme.Animation.standard) { isExpanded.toggle() }
        }
    }

    private var subtitle: String {
        if let annotation, !annotation.isEmpty { return annotation }
        return L10n.plural("%@ item", "%@ items", itemCount)
    }

    private var checkbox: some View {
        Button(action: { isSelected.toggle() }) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(isSelected ? accentColor : Theme.Colors.textTertiary)
                .symbolEffect(.bounce, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isSelected ? L10n.string("Deselect %@", "\(title)") : L10n.string("Select %@", "\(title)")))
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accentColor.opacity(0.18))
                .frame(width: 30, height: 30)
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
        }
    }

    private func safetyBadge(_ level: SafetyLevel) -> some View {
        HStack(spacing: 3) {
            Image(systemName: level.symbolName)
                .font(.system(size: 8, weight: .bold))
            Text(level.badgeLabel)
                .font(Theme.Typography.micro)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(level.tint.opacity(0.20)))
        .foregroundStyle(level.tint)
    }

    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.Colors.textTertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(Theme.Animation.standard, value: isExpanded)
            .frame(width: 14)
    }
}

// MARK: - Scan item row (used inside an expanded CategoryRow)

public struct ScanItemRow: View {
    public let item: ScanItem
    @Binding public var isSelected: Bool
    public var onReveal: ((ScanItem) -> Void)? = nil

    @State private var isHovered = false

    public init(
        item: ScanItem,
        isSelected: Binding<Bool>,
        onReveal: ((ScanItem) -> Void)? = nil
    ) {
        self.item = item
        self._isSelected = isSelected
        self.onReveal = onReveal
    }

    public var body: some View {
        HStack(spacing: 10) {
            Button(action: { if !item.isReadOnly { isSelected.toggle() } }) {
                Image(systemName: item.isReadOnly
                      ? "lock.fill"
                      : (isSelected ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 14))
                    .foregroundStyle(
                        item.isReadOnly
                            ? Theme.Colors.textTertiary
                            : (isSelected ? Theme.Colors.accent : Theme.Colors.textTertiary)
                    )
            }
            .buttonStyle(.plain)
            .disabled(item.isReadOnly)

            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.textTertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.displayPath)
                    .pathStyle()
            }
            Spacer(minLength: 0)
            if let annotation = item.annotation, !annotation.isEmpty {
                Text(annotation)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .padding(.trailing, 4)
            }
            SizeBadge(bytes: item.size)
            if let onReveal {
                Button(action: { onReveal(item) }) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHovered ? Theme.Colors.accent : Theme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Reveal in Finder"))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Theme.Colors.selection : Color.clear)
        )
        .onHover { isHovered = $0 }
        .opacity(item.isReadOnly ? 0.5 : 1.0)
        .contextMenu {
            if let onReveal {
                Button(L10n.string("Reveal in Finder")) { onReveal(item) }
            }
            Button(L10n.string("Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var selected1 = true
    @Previewable @State var expanded1 = true
    @Previewable @State var selected2 = false
    @Previewable @State var expanded2 = false

    VStack(spacing: 10) {
        CategoryRow(
            title: L10n.string("Cache Files"),
            systemImage: "externaldrive.badge.timemachine",
            itemCount: 148,
            sizeBytes: 3_400_000_000,
            safety: .safe,
            isSelected: $selected1,
            isExpanded: $expanded1
        ) {
            AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<3, id: \.self) { i in
                        Text(L10n.string("Item %@", "\(i)"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            )
        }
        CategoryRow(
            title: L10n.string("iOS Device Backups"),
            systemImage: "externaldrive.badge.checkmark",
            itemCount: 2,
            sizeBytes: 24_000_000_000,
            accentColor: Theme.Colors.warning,
            safety: .review,
            isSelected: $selected2,
            isExpanded: $expanded2
        )
    }
    .padding()
    .background(Theme.Colors.background)
}
