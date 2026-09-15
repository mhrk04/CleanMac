//
//  Theme.swift
//  CleanMac
//
//  Centralised palette, gradients, typography, and spacing tokens. Every view
//  references these constants so the whole app can be re-skinned from one
//  place. Inspired by the dark navy + violet/blue gradient look of modern
//  Mac cleaning utilities.
//

import SwiftUI
import AppKit

public enum Theme {

    // MARK: - Colors

    public enum Colors {
        /// Deepest background — used behind everything.
        public static let background = Color(hex: 0x0F1220)
        /// Slightly lighter background for the sidebar / secondary panes.
        public static let backgroundAlt = Color(hex: 0x12162A)
        /// Card surface.
        public static let surface = Color(hex: 0x1A1E35)
        /// Elevated surface (hovered cards, popovers).
        public static let surfaceElevated = Color(hex: 0x242946)
        /// Subtle hairline between stacked surfaces.
        public static let separator = Color.white.opacity(0.06)

        /// Primary accent — used for CTAs and progress rings.
        public static let accent = Color(hex: 0x7B5CFF)
        /// Secondary accent — paired with `accent` in gradients.
        public static let accentSecondary = Color(hex: 0x3BA9FF)

        /// Semantic colors.
        public static let success = Color(hex: 0x3DDC97)
        public static let warning = Color(hex: 0xFFB547)
        public static let danger = Color(hex: 0xFF5C7A)
        public static let info = Color(hex: 0x4FC3F7)

        /// Text.
        public static let textPrimary = Color.white.opacity(0.92)
        public static let textSecondary = Color.white.opacity(0.60)
        public static let textTertiary = Color.white.opacity(0.38)

        /// Selection highlight for sidebar rows.
        public static let selection = Color.white.opacity(0.08)
    }

    // MARK: - Gradients

    public enum Gradients {
        /// Raw colour stops of the brand gradient. Shared by the linear
        /// `accent` fill and the angular stroke of `ScanProgressRing`.
        public static let accentStops = Gradient(colors: [Colors.accent, Colors.accentSecondary])

        /// Primary CTA / progress ring stroke.
        public static let accent = LinearGradient(
            gradient: accentStops,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Radial glow used behind the Smart Scan hero.
        public static let heroGlow = RadialGradient(
            colors: [
                Colors.accent.opacity(0.45),
                Colors.accentSecondary.opacity(0.18),
                .clear
            ],
            center: .center,
            startRadius: 20,
            endRadius: 340
        )

        /// Subtle vertical gradient for the app background.
        public static let background = LinearGradient(
            colors: [Colors.background, Colors.backgroundAlt],
            startPoint: .top,
            endPoint: .bottom
        )

        /// Warning stripe used on cards with `safety: review`.
        public static let warning = LinearGradient(
            colors: [Colors.warning.opacity(0.9), Colors.danger.opacity(0.7)],
            startPoint: .leading,
            endPoint: .trailing
        )

        /// Success stripe used after a clean completes.
        public static let success = LinearGradient(
            colors: [Colors.success, Colors.info],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Typography

    public enum Typography {
        /// Big numeric readouts (e.g. "12.4 GB").
        public static let heroNumber = Font.system(size: 34, weight: .bold, design: .rounded)
        /// Section titles inside modules.
        public static let sectionTitle = Font.system(size: 20, weight: .semibold, design: .rounded)
        /// Card titles.
        public static let cardTitle = Font.system(size: 16, weight: .semibold)
        /// Body copy.
        public static let body = Font.system(size: 15, weight: .medium)
        /// Small captions.
        public static let caption = Font.system(size: 12, weight: .regular)
        /// Micro labels (badges, tags).
        public static let micro = Font.system(size: 10, weight: .semibold)
        /// Monospaced path display.
        public static let path = Font.system(size: 12, design: .monospaced)
        /// Sidebar item titles.
        public static let sidebarItem = Font.system(size: 13, weight: .medium)
    }

    // MARK: - Metrics

    public enum Metrics {
        public static let cornerRadiusSmall: CGFloat = 6
        public static let cornerRadius: CGFloat = 10
        public static let cornerRadiusLarge: CGFloat = 16
        public static let cardPadding: CGFloat = 16
        public static let sectionSpacing: CGFloat = 20
        public static let sidebarWidth: CGFloat = 220
        public static let windowMinWidth: CGFloat = 1000
        public static let windowMinHeight: CGFloat = 680
        public static let heroRingSize: CGFloat = 220
    }

    // MARK: - Animation

    public enum Animation {
        public static let quick = SwiftUI.Animation.easeOut(duration: 0.15)
        public static let standard = SwiftUI.Animation.easeInOut(duration: 0.25)
        public static let slow = SwiftUI.Animation.easeInOut(duration: 0.45)
        public static let spring = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.82)
        /// Progress ring fill animation — deliberately slow so the eye can
        /// follow the number changing.
        public static let ringFill = SwiftUI.Animation.easeInOut(duration: 0.6)
    }
}

// MARK: - Color(hex:) convenience

public extension Color {
    /// Create a Color from a 24-bit hex value, e.g. `Color(hex: 0x7B5CFF)`.
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Safety-level styling

public extension SafetyLevel {
    var tint: Color {
        switch self {
        case .safe: return Theme.Colors.success
        case .review: return Theme.Colors.warning
        case .dangerous: return Theme.Colors.danger
        }
    }

    var badgeLabel: String {
        switch self {
        case .safe: return L10n.string("Safe")
        case .review: return L10n.string("Review")
        case .dangerous: return L10n.string("Advanced")
        }
    }

    var symbolName: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .review: return "exclamationmark.triangle.fill"
        case .dangerous: return "xmark.octagon.fill"
        }
    }
}
