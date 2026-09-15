//
//  SizeBadge.swift
//  CleanMac
//
//  A compact pill showing a byte count, color-coded by magnitude.
//

import SwiftUI

public struct SizeBadge: View {
    public let bytes: Int64
    public var style: Style = .adaptive

    public enum Style {
        /// Color shifts green -> yellow -> red as size grows.
        case adaptive
        /// Always use the accent gradient.
        case accent
        /// Always use the given color.
        case tint(Color)
    }

    public init(bytes: Int64, style: Style = .adaptive) {
        self.bytes = bytes
        self.style = style
    }

    public var body: some View {
        Text(ByteCount.compact(bytes))
            .font(Theme.Typography.micro)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
            .foregroundStyle(foreground)
            .accessibilityLabel(Text(ByteCount.format(bytes)))
    }

    private var background: some ShapeStyle {
        switch style {
        case .adaptive:
            return AnyShapeStyle(color(for: bytes).opacity(0.18))
        case .accent:
            return AnyShapeStyle(Theme.Colors.accent.opacity(0.22))
        case .tint(let c):
            return AnyShapeStyle(c.opacity(0.18))
        }
    }

    private var foreground: Color {
        switch style {
        case .adaptive: return color(for: bytes)
        case .accent: return Theme.Colors.accentSecondary
        case .tint(let c): return c
        }
    }

    /// Colour-coded by magnitude: green under 100 MB, yellow under 1 GB,
    /// red at 1 GB and above.
    private func color(for bytes: Int64) -> Color {
        let mb: Int64 = 1024 * 1024
        let gb: Int64 = 1024 * mb
        switch bytes {
        case ..<(100 * mb): return Theme.Colors.success
        case ..<(1 * gb): return Theme.Colors.warning
        default: return Theme.Colors.danger
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        SizeBadge(bytes: 512)
        SizeBadge(bytes: 42 * 1024 * 1024)
        SizeBadge(bytes: 2 * 1024 * 1024 * 1024)
        SizeBadge(bytes: 42 * 1024 * 1024 * 1024)
        SizeBadge(bytes: 1_500_000_000, style: .accent)
        SizeBadge(bytes: 1_500_000_000, style: .tint(Theme.Colors.success))
    }
    .padding()
    .background(Theme.Colors.background)
}
