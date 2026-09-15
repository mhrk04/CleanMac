//
//  View+Theme.swift
//  CleanMac
//
//  Small view modifiers that apply the theme consistently. Views opt in with
//  `.card()`, `.themedBackground()`, etc., rather than repeating padding,
//  corner radius, and shadow values everywhere.
//

import SwiftUI

public extension View {
    /// Standard card look: surface background, rounded corners, subtle border.
    func card(elevated: Bool = false, padding: CGFloat = Theme.Metrics.cardPadding) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge, style: .continuous)
                    .fill(elevated ? Theme.Colors.surfaceElevated : Theme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge, style: .continuous)
                    .strokeBorder(Theme.Colors.separator, lineWidth: 1)
            )
    }

    /// Gradient-bordered card — used for the Smart Scan hero and module tiles.
    func gradientCard(borderWidth: CGFloat = 1.5) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge, style: .continuous)
                    .fill(Theme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge, style: .continuous)
                    .strokeBorder(Theme.Gradients.accent, lineWidth: borderWidth)
            )
    }

    /// Full-window dark gradient background.
    func themedBackground() -> some View {
        self.background(
            Theme.Gradients.background
                .ignoresSafeArea()
        )
    }

    /// Standard hover lift for interactive cards.
    func hoverLift(_ isHovered: Bool, amount: CGFloat = 2) -> some View {
        self
            .scaleEffect(isHovered ? 1.008 : 1.0)
            .offset(y: isHovered ? -amount : 0)
            .shadow(color: isHovered ? Theme.Colors.accent.opacity(0.25) : .clear,
                    radius: isHovered ? 14 : 0, x: 0, y: 6)
            .animation(Theme.Animation.spring, value: isHovered)
    }

    /// Apply the standard text selection color for monospaced path labels.
    func pathStyle() -> some View {
        self
            .font(Theme.Typography.path)
            .foregroundStyle(Theme.Colors.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    /// Dim + disable when a condition is true.
    func dimmed(when condition: Bool, opacity: Double = 0.35) -> some View {
        self.opacity(condition ? opacity : 1.0)
            .allowsHitTesting(!condition)
    }
}

// MARK: - Conditional modifier

public extension View {
    /// Apply `modifier` only when `condition` is true.
    @ViewBuilder
    func `if`<M: ViewModifier>(_ condition: Bool, apply modifier: (Self) -> M) -> some View {
        if condition {
            self.modifier(modifier(self))
        } else {
            self
        }
    }
}

// MARK: - Size class helper (unused on macOS today, kept for future iPad parity)

public enum HorizontalSizeClass {
    case compact
    case regular
}
