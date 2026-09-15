//
//  OnboardingSheet.swift
//  CleanMac
//
//  First-launch sheet. Walks the user through granting Full Disk Access
//  before letting them into the main UI. Polls PermissionCenter every 2s
//  so the sheet dismisses automatically once the switch is flipped in
//  System Settings.
//

import SwiftUI

public struct OnboardingSheet: View {
    @ObservedObject public var permissions: PermissionCenter
    @ObservedObject public var settings: SettingsStore
    public var onDismiss: () -> Void

    @State private var page: Page = .welcome

    public enum Page: Int, CaseIterable {
        case welcome
        case fullDiskAccess
        case done
    }

    public init(
        permissions: PermissionCenter,
        settings: SettingsStore,
        onDismiss: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.settings = settings
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Colors.separator)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            Divider().background(Theme.Colors.separator)
            footer
        }
        .frame(width: 560, height: 460)
        .themedBackground()
        .onAppear {
            // If FDA is already granted (returning user wiped the flag),
            // skip straight to Done.
            if permissions.fullDiskAccessGranted, page == .fullDiskAccess {
                page = .done
            }
        }
        .onChange(of: permissions.fullDiskAccessGranted) { _, granted in
            if granted && page == .fullDiskAccess {
                withAnimation(Theme.Animation.standard) { page = .done }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(Page.allCases, id: \.rawValue) { p in
                Circle()
                    .fill(p.rawValue <= page.rawValue ? Theme.Colors.accent : Theme.Colors.surfaceElevated)
                    .frame(width: 8, height: 8)
            }
            Spacer()
            Text(L10n.string("Welcome to CleanMac"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome: welcomePage
        case .fullDiskAccess: fullDiskAccessPage
        case .done: donePage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.Gradients.accent)
                    .frame(width: 96, height: 96)
                    .blur(radius: 0.5)
                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Theme.Colors.accent.opacity(0.55), radius: 24, y: 8)

            Text(L10n.string("A cleaner Mac in one click."))
                .font(Theme.Typography.heroNumber)
                .foregroundStyle(Theme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text(L10n.string("CleanMac scans caches, logs, unused language files, and forgotten large files — then moves everything you approve to the Trash so it can be undone."))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    private var fullDiskAccessPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.Colors.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Grant Full Disk Access"))
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(L10n.string("Required to scan system caches and other apps' containers."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                step(number: 1, text: L10n.string("Click the button below to open System Settings."))
                step(number: 2, text: L10n.string("Toggle the switch next to CleanMac in the Full Disk Access list."))
                step(number: 3, text: L10n.string("Return to this window — it will detect the change automatically."))
            }
            .padding(.leading, 4)

            HStack(spacing: 10) {
                statusPill(
                    granted: permissions.fullDiskAccessGranted,
                    grantedLabel: L10n.string("Full Disk Access granted"),
                    pendingLabel: L10n.string("Waiting for permission…")
                )
                Spacer()
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                GhostButton(L10n.string("Skip for now"), role: .cancel) {
                    // Skipping is allowed; the app will run in "reduced mode"
                    // and only surface items in the user's own home folder.
                    settings.hasCompletedOnboarding = true
                    onDismiss()
                }
                Spacer()
                GradientButton(L10n.string("Open System Settings"), systemImage: "gearshape.fill") {
                    permissions.openSystemSettings(for: .fullDiskAccess)
                    // Poll so we notice the moment the user flips the switch.
                    permissions.startPolling(interval: 2.0) {
                        permissions.fullDiskAccessGranted
                    }
                }
            }
        }
    }

    private var donePage: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Theme.Gradients.success)
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Theme.Colors.success.opacity(0.5), radius: 20, y: 6)

            Text(L10n.string("You're all set."))
                .font(Theme.Typography.heroNumber)
                .foregroundStyle(Theme.Colors.textPrimary)

            Text(L10n.string("Run your first Smart Scan to see how much space you can reclaim."))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                GradientButton(L10n.string("Get Started"), systemImage: "arrow.right") {
                    settings.hasCompletedOnboarding = true
                    permissions.stopPolling()
                    onDismiss()
                }
            }
        }
    }

    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // `verbatim:` matters here: a bare `Text("\(number)")` is a string
            // *interpolation literal*, which SwiftUI reads as a
            // LocalizedStringKey and would look up as a junk "%lld" entry.
            // The step index is data, not copy.
            Text(verbatim: "\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.Colors.accent))
            Text(verbatim: text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private func statusPill(granted: Bool, grantedLabel: String, pendingLabel: String) -> some View {
        HStack(spacing: 6) {
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.success)
                Text(grantedLabel)
                    .foregroundStyle(Theme.Colors.textPrimary)
            } else {
                ProgressView().controlSize(.small)
                Text(pendingLabel)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .font(Theme.Typography.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.Colors.surfaceElevated))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            GhostButton(L10n.string("Back"), systemImage: "chevron.left", isEnabled: page != .welcome) {
                withAnimation(Theme.Animation.standard) {
                    switch page {
                    case .welcome: break
                    case .fullDiskAccess: page = .welcome
                    case .done: page = .fullDiskAccess
                    }
                }
            }
            Spacer()
            if page == .welcome {
                GradientButton(L10n.string("Continue"), systemImage: "arrow.right") {
                    withAnimation(Theme.Animation.standard) {
                        page = permissions.fullDiskAccessGranted ? .done : .fullDiskAccess
                    }
                }
            } else if page == .fullDiskAccess && permissions.fullDiskAccessGranted {
                GradientButton(L10n.string("Continue"), systemImage: "arrow.right") {
                    withAnimation(Theme.Animation.standard) { page = .done }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Preview

#Preview(L10n.string("Welcome")) {
    OnboardingSheet(
        permissions: PermissionCenter(),
        settings: SettingsStore(),
        onDismiss: {}
    )
}
