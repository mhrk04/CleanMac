//
//  GradientButton.swift
//  CleanMac
//
//  Primary CTA button with a gradient fill, hover state, and press state.
//  Used for "Scan", "Clean", "Uninstall" and other main actions.
//

import SwiftUI

public struct GradientButton: View {
    public enum Role {
        case primary        // accent gradient
        case destructive    // red gradient
        case success        // green gradient
    }

    public let title: String
    public var systemImage: String? = nil
    public var role: Role = .primary
    public var isEnabled: Bool = true
    public var isLoading: Bool = false
    public var size: ControlSize = .large
    public var action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    public init(
        _ title: String,
        systemImage: String? = nil,
        role: Role = .primary,
        isEnabled: Bool = true,
        isLoading: Bool = false,
        size: ControlSize = .large,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: iconSize, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minWidth: size == .large ? 140 : 90)
            .background(background)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(isHovered && isEnabled ? 0.22 : 0.0),
                                  lineWidth: 1)
            )
            .shadow(
                color: shadowColor.opacity(isEnabled ? (isHovered ? 0.55 : 0.32) : 0),
                radius: isHovered ? 16 : 10,
                x: 0, y: 6
            )
            .scaleEffect(isPressed && isEnabled ? 0.975 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.45)
            .animation(Theme.Animation.quick, value: isHovered)
            .animation(Theme.Animation.quick, value: isPressed)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isEnabled ? .isButton : [])
    }

    private func perform() {
        guard isEnabled, !isLoading else { return }
        action()
    }

    // MARK: - Style tokens

    private var background: AnyShapeStyle {
        let gradient: LinearGradient
        switch role {
        case .primary:
            gradient = Theme.Gradients.accent
        case .destructive:
            gradient = LinearGradient(
                colors: [Theme.Colors.danger, Color(hex: 0xFF8A5C)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .success:
            gradient = Theme.Gradients.success
        }
        return AnyShapeStyle(gradient)
    }

    private var shadowColor: Color {
        switch role {
        case .primary: return Theme.Colors.accent
        case .destructive: return Theme.Colors.danger
        case .success: return Theme.Colors.success
        }
    }

    private var radius: CGFloat {
        switch size {
        case .large: return 12
        case .regular: return 10
        case .small, .mini: return 8
        case .extraLarge: return 14
        @unknown default: return 10
        }
    }

    private var fontSize: CGFloat {
        switch size {
        case .large: return 15
        case .regular: return 13
        case .small, .mini: return 12
        case .extraLarge: return 17
        @unknown default: return 13
        }
    }

    private var iconSize: CGFloat {
        switch size {
        case .large: return 15
        case .regular: return 13
        case .small, .mini: return 11
        case .extraLarge: return 17
        @unknown default: return 13
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .large: return 22
        case .regular: return 16
        case .small, .mini: return 12
        case .extraLarge: return 28
        @unknown default: return 16
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .large: return 12
        case .regular: return 9
        case .small, .mini: return 6
        case .extraLarge: return 15
        @unknown default: return 9
        }
    }
}

// MARK: - Secondary (ghost) button

/// A quieter button for secondary actions ("Cancel", "Show Details").
public struct GhostButton: View {
    public let title: String
    public var systemImage: String? = nil
    public var isEnabled: Bool = true
    public var role: ButtonRole? = nil
    public var action: () -> Void

    @State private var isHovered = false

    public init(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: { if isEnabled { action() } }) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Theme.Colors.selection : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.Colors.separator, lineWidth: 1)
            )
            .foregroundStyle(isEnabled ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
            .animation(Theme.Animation.quick, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Previews

#Preview {
    VStack(spacing: 16) {
        GradientButton(L10n.string("Scan"), systemImage: "sparkles", action: {})
        GradientButton(L10n.string("Clean 4.2 GB"), systemImage: "trash.fill", role: .destructive, action: {})
        GradientButton(L10n.string("Done"), systemImage: "checkmark", role: .success, action: {})
        GradientButton(L10n.string("Disabled"), isEnabled: false, action: {})
        GradientButton(L10n.string("Loading"), isLoading: true, action: {})
        GhostButton(L10n.string("Cancel"), systemImage: "xmark", role: .cancel, action: {})
    }
    .padding(24)
    .background(Theme.Colors.background)
}
