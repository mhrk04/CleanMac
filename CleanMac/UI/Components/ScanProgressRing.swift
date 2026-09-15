//
//  ScanProgressRing.swift
//  CleanMac
//
//  The signature animated ring shown on the Smart Scan hero card. Draws a
//  gradient stroke that fills as progress advances, with a live numeric
//  readout in the middle.
//

import SwiftUI

public struct ScanProgressRing: View {
    /// Progress from 0.0 to 1.0.
    public let progress: Double
    /// Big number shown in the middle of the ring.
    public let primaryValue: String
    /// Small label under the primary value.
    public let primaryLabel: String
    /// Optional secondary line (e.g. current path being scanned).
    public let secondaryText: String?
    /// True while scanning — triggers the rotating shimmer.
    public let isAnimating: Bool
    /// Ring diameter.
    public let diameter: CGFloat
    /// Stroke width.
    public let lineWidth: CGFloat

    @State private var shimmerAngle: Double = 0

    public init(
        progress: Double,
        primaryValue: String,
        primaryLabel: String,
        secondaryText: String? = nil,
        isAnimating: Bool = false,
        diameter: CGFloat = Theme.Metrics.heroRingSize,
        lineWidth: CGFloat = 14
    ) {
        self.progress = min(max(progress, 0), 1)
        self.primaryValue = primaryValue
        self.primaryLabel = primaryLabel
        self.secondaryText = secondaryText
        self.isAnimating = isAnimating
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            // Radial glow behind the ring.
            Theme.Gradients.heroGlow
                .frame(width: diameter * 1.7, height: diameter * 1.7)
                .opacity(isAnimating ? 0.9 : 0.55)
                .blur(radius: isAnimating ? 4 : 12)
                .animation(Theme.Animation.slow, value: isAnimating)

            // Track.
            Circle()
                .strokeBorder(Theme.Colors.surfaceElevated, lineWidth: lineWidth)
                .frame(width: diameter, height: diameter)

            // Progress arc.
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        gradient: Theme.Gradients.accentStops,
                        center: .center,
                        angle: .degrees(shimmerAngle)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
                .animation(Theme.Animation.ringFill, value: progress)

            // Leading dot on the arc.
            if progress > 0.005 && progress < 0.995 {
                Circle()
                    .fill(Color.white)
                    .frame(width: lineWidth * 0.55, height: lineWidth * 0.55)
                    .shadow(color: Theme.Colors.accent.opacity(0.9), radius: 6)
                    .offset(x: cos(angleRadians(progress)) * diameter / 2,
                            y: sin(angleRadians(progress)) * diameter / 2)
                    .animation(Theme.Animation.ringFill, value: progress)
            }

            // Center content.
            VStack(spacing: 4) {
                Text(primaryValue)
                    .font(.system(size: diameter * 0.19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text(primaryLabel)
                    .font(.system(size: max(11, diameter * 0.055), weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)

                if let secondary = secondaryText, !secondary.isEmpty {
                    Text(secondary)
                        .font(.system(size: max(10, diameter * 0.045), design: .monospaced))
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: diameter * 0.75)
                        .padding(.top, 2)
                }
            }
        }
        .frame(width: diameter * 1.7, height: diameter * 1.7)
        .onAppear {
            guard isAnimating else { return }
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                shimmerAngle = 360
            }
        }
        .onChange(of: isAnimating) { _, newValue in
            if newValue {
                withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                    shimmerAngle = 360
                }
            } else {
                withAnimation(.default) { shimmerAngle = 0 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.string("%@ %@, %@ percent", "\(primaryLabel)", "\(primaryValue)", "\(Int(progress * 100))")))
    }

    /// Convert a 0...1 progress value into an angle in radians, with 0 at
    /// the top of the ring (12 o'clock) and increasing clockwise.
    private func angleRadians(_ p: Double) -> Double {
        // Start at -90 degrees (top).
        let degrees = -90 + (p * 360)
        return degrees * .pi / 180
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 24) {
        ScanProgressRing(
            progress: 0.0,
            primaryValue: "0",
            primaryLabel: L10n.string("Ready to scan"),
            isAnimating: false
        )
        ScanProgressRing(
            progress: 0.42,
            primaryValue: L10n.string("3.4 GB"),
            primaryLabel: L10n.string("Found so far"),
            secondaryText: L10n.string("Scanning ~/Library/Caches/com.apple.Safari"),
            isAnimating: true
        )
        ScanProgressRing(
            progress: 1.0,
            primaryValue: L10n.string("12.4 GB"),
            primaryLabel: L10n.string("Scan complete"),
            secondaryText: L10n.string("1,428 items across 9 categories")
        )
    }
    .padding(32)
    .background(Theme.Colors.background)
}
