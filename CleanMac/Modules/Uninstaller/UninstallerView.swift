//
//  UninstallerView.swift
//  CleanMac
//
//  Two-pane Uninstaller UI. Left: searchable list of installed apps with
//  icon, name, version, size, and a "running" badge. Right: the selected
//  app's bundle + every discovered leftover grouped by category with
//  checkboxes, and an Uninstall CTA in the footer.
//

import SwiftUI
import AppKit

public struct UninstallerView: View {
    @ObservedObject public var viewModel: UninstallerViewModel
    @State private var showConfirmSheet = false
    @State private var showResultSheet = false

    public init(viewModel: UninstallerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Colors.separator)
            content
            Divider().background(Theme.Colors.separator)
            footer
        }
        .themedBackground()
        .sheet(isPresented: $showConfirmSheet) { confirmSheet }
        .sheet(isPresented: $showResultSheet) { resultSheet }
        .onAppear {
            if viewModel.apps.isEmpty && viewModel.phase == .idle {
                viewModel.loadApps()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Uninstaller"))
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(headerSubtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
            headerActions
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var headerSubtitle: String {
        switch viewModel.phase {
        case .idle:
            return viewModel.apps.isEmpty
                ? L10n.string("Loading installed apps…")
                : L10n.string("%@ apps installed", "\(viewModel.apps.count)")
        case .loadingApps: return L10n.string("Loading installed apps…")
        case .scanningLeftovers:
            let name = viewModel.selectedApp?.presentationName ?? ""
            return name.isEmpty ? L10n.string("Scanning for leftovers…") : L10n.string("Scanning leftovers for %@…", "\(name)")
        case .reviewing:
            guard let app = viewModel.selectedApp else { return L10n.string("Select an app") }
            // Hoisted out of the interpolation: a multi-line expression inside
            // `\( )` is not valid Swift.
            let leftoverText = L10n.plural(
                "%@ leftover item",
                "%@ leftover items",
                viewModel.leftovers.count
            )
            return L10n.string(
                "%1$@ · %2$@",
                app.presentationName,
                leftoverText
            )
        case .quitting: return L10n.string("Quitting application…")
        case .cleaning:
            return L10n.string(
                "Moving %@ items to Trash…", 
                "\(viewModel.cleanProgress.itemsTotal)"
            )
        case .completed(let m):
            return L10n.string(
                "Freed %@ across %@ items.", 
                "\(ByteCount.format(m.bytesReclaimed))", 
                "\(m.itemCount)"
            )
        case .failed(let msg): return msg
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        switch viewModel.phase {
        case .loadingApps, .scanningLeftovers:
            ProgressView().controlSize(.small).tint(Theme.Colors.accent)
        case .reviewing:
            GhostButton(L10n.string("Select All"), systemImage: "checkmark.circle") { viewModel.selectAll() }
            GhostButton(L10n.string("Deselect"), systemImage: "circle") { viewModel.deselectAll() }
            GhostButton(L10n.string("Reload"), systemImage: "arrow.clockwise") { viewModel.loadApps() }
        case .completed:
            GhostButton(L10n.string("Done"), systemImage: "checkmark") { viewModel.reset() }
            GhostButton(L10n.string("Reload"), systemImage: "arrow.clockwise") { viewModel.loadApps() }
        default:
            GhostButton(L10n.string("Reload"), systemImage: "arrow.clockwise") { viewModel.loadApps() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .loadingApps:
            if viewModel.apps.isEmpty {
                loadingState
            } else {
                twoPane
            }
        case .scanningLeftovers:
            twoPane
        case .reviewing:
            twoPane
        case .quitting:
            quittingState
        case .cleaning:
            cleaningState
        case .completed(let manifest):
            completedState(manifest)
        case .failed(let message):
            failedState(message)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(Theme.Colors.accent)
            Text(L10n.string("Loading installed apps…"))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var quittingState: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(Theme.Colors.warning)
            Text(L10n.string("Quitting application…"))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text(L10n.string("CleanMac sent a quit request and is waiting for the app to exit."))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cleaningState: some View {
        VStack(spacing: 20) {
            ScanProgressRing(
                progress: viewModel.cleanProgress.fractionComplete,
                primaryValue: ByteCount.compact(viewModel.cleanProgress.bytesFreed),
                primaryLabel: L10n.string("Moved to Trash"),
                secondaryText: viewModel.cleanProgress.currentPath,
                isAnimating: true
            )
            Text(L10n.string("%@ of %@ items", "\(viewModel.cleanProgress.itemsProcessed)", "\(viewModel.cleanProgress.itemsTotal)"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func completedState(_ manifest: CleanManifest) -> some View {
        VStack(spacing: 16) {
            ScanProgressRing(
                progress: 1.0,
                primaryValue: ByteCount.compact(manifest.bytesReclaimed),
                primaryLabel: L10n.string("Reclaimed"),
                secondaryText: L10n.string("%@ items moved to Trash", "\(manifest.itemCount)")
            )
            if !manifest.failures.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.warning)
                    Text(L10n.string("%@ items could not be moved.", "\(manifest.failures.count)"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.Colors.warning.opacity(0.15)))
            }
            HStack(spacing: 10) {
                GhostButton(L10n.string("View Details"), systemImage: "list.bullet") { showResultSheet = true }
                GradientButton(L10n.string("Done"), systemImage: "checkmark", role: .success) {
                    viewModel.reset()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.danger.opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Theme.Colors.danger)
            }
            Text(L10n.string("Uninstall failed"))
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            GradientButton(L10n.string("Back to Apps"), systemImage: "arrow.left") {
                viewModel.reset()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Two-pane layout

    private var twoPane: some View {
        HStack(alignment: .top, spacing: 0) {
            appListPane
            Divider().background(Theme.Colors.separator)
            detailPane
        }
    }

    // MARK: - Left pane: app list

    private var appListPane: some View {
        VStack(spacing: 0) {
            searchField
            Divider().background(Theme.Colors.separator)
            if viewModel.filteredApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text(L10n.string("No apps match"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: 2) {
                        ForEach(viewModel.filteredApps) { app in
                            AppRow(
                                app: app,
                                isSelected: viewModel.selectedAppID == app.id,
                                onTap: { viewModel.selectApp(app) }
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            Divider().background(Theme.Colors.separator)
            systemAppsToggle
        }
        .frame(width: 280)
        .background(Theme.Colors.backgroundAlt)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.textTertiary)
            TextField(L10n.string("Search apps"), text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textPrimary)
            if !viewModel.searchText.isEmpty {
                Button(action: { viewModel.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Colors.surface)
    }

    private var systemAppsToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.includeSystemApps },
            set: { newValue in
                viewModel.includeSystemApps = newValue
                viewModel.settings.uninstallIncludeSystemApps = newValue
            }
        )) {
            Text(L10n.string("Show system apps"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(Theme.Colors.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Right pane: detail

    @ViewBuilder
    private var detailPane: some View {
        if let app = viewModel.selectedApp {
            VStack(spacing: 0) {
                appDetailHeader(app)
                Divider().background(Theme.Colors.separator)
                if viewModel.phase == .scanningLeftovers {
                    scanningLeftoversState
                } else if viewModel.leftovers.isEmpty {
                    noLeftoversState
                } else {
                    leftoverList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "app.badge.trash")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text(L10n.string("Select an app"))
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(L10n.string("Choose an app from the list to see its leftover files."))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func appDetailHeader(_ app: AppBundleInfo) -> some View {
        HStack(spacing: 14) {
            AppIconView(path: app.path, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(app.presentationName)
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    if app.isRunning {
                        runningBadge
                    }
                    if app.isSystemApp {
                        systemBadge
                    }
                }
                HStack(spacing: 10) {
                    if !app.shortVersion.isEmpty {
                        metaLabel(L10n.string("Version"), app.shortVersion)
                    }
                    if !app.bundleIdentifier.isEmpty {
                        metaLabel(L10n.string("Bundle ID"), app.bundleIdentifier)
                    }
                    if app.size > 0 {
                        metaLabel(L10n.string("Size"), ByteCount.compact(app.size))
                    }
                }
                Text(app.path)
                    .pathStyle()
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if viewModel.totalLeftoverSize > 0 {
                    Text(ByteCount.format(viewModel.totalLeftoverSize))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(L10n.string("recoverable"))
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                Button(action: { viewModel.revealApp(app) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 10))
                        Text(L10n.string("Reveal"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var runningBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(Theme.Colors.success).frame(width: 6, height: 6)
            Text(L10n.string("Running"))
                .font(Theme.Typography.micro)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.Colors.success.opacity(0.18)))
        .foregroundStyle(Theme.Colors.success)
    }

    private var systemBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill").font(.system(size: 8))
            Text(L10n.string("System"))
                .font(Theme.Typography.micro)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.Colors.textTertiary.opacity(0.18)))
        .foregroundStyle(Theme.Colors.textSecondary)
    }

    private func metaLabel(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(value)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var scanningLeftoversState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(Theme.Colors.accent)
            Text(L10n.string("Scanning for leftover files…"))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noLeftoversState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Colors.success)
            Text(L10n.string("No leftovers found"))
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(L10n.string("This app hasn't left any files outside its bundle."))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leftoverList: some View {
        ScrollView(showsIndicators: true) {
            LazyVStack(spacing: 8) {
                if let warning = viewModel.quitWarning {
                    warningBanner(warning)
                }
                if let error = viewModel.errorMessage {
                    warningBanner(error, accent: Theme.Colors.danger)
                }
                ForEach(viewModel.groupedLeftovers, id: \.category) { group in
                    leftoverCategoryCard(category: group.category, items: group.items)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func warningBanner(_ text: String, accent: Color = Theme.Colors.warning) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(accent)
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(accent.opacity(0.35), lineWidth: 1)
        )
    }

    private func leftoverCategoryCard(category: RuleCategory, items: [ScanItem]) -> some View {
        let isExpanded = viewModel.expandedCategories.contains(category.rawValue)
        let selectableItems = items.filter { !$0.isReadOnly }
        let allSelected = !selectableItems.isEmpty
            && selectableItems.allSatisfy { viewModel.selectedIDs.contains($0.id) }
        let accent = items.first?.safety.tint ?? Theme.Colors.accent

        return CategoryRow(
            title: category.displayName,
            systemImage: category.symbolName,
            itemCount: items.count,
            sizeBytes: items.reduce(0) { $0 + $1.size },
            accentColor: accent,
            safety: items.map(\.safety).max(by: { safetyRank($0) < safetyRank($1) }),
            isSelected: Binding(
                get: { allSelected },
                set: { _ in viewModel.toggle(category: category, items: items) }
            ),
            isExpanded: Binding(
                get: { isExpanded },
                set: { newValue in
                    if newValue { viewModel.expandedCategories.insert(category.rawValue) }
                    else { viewModel.expandedCategories.remove(category.rawValue) }
                }
            )
        ) {
            AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items.prefix(200)) { item in
                        ScanItemRow(
                            item: item,
                            isSelected: Binding(
                                get: { viewModel.selectedIDs.contains(item.id) },
                                set: { _ in viewModel.toggle(item: item) }
                            ),
                            onReveal: { viewModel.reveal($0) }
                        )
                    }
                    if items.count > 200 {
                        Text(L10n.string("…and %@ more", "\(items.count - 200)"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .padding(.vertical, 6)
                    }
                }
            )
        }
    }

    private func safetyRank(_ level: SafetyLevel) -> Int {
        switch level {
        case .safe: return 0
        case .review: return 1
        case .dangerous: return 2
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("%@ selected", "\(viewModel.selectedItems.count)"))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(ByteCount.format(viewModel.selectedSize))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .monospacedDigit()
            }
            Spacer()
            if viewModel.phase == .reviewing, let app = viewModel.selectedApp {
                GradientButton(
                    app.isSystemApp ? L10n.string("System App") : L10n.string("Uninstall"),
                    systemImage: "trash.fill",
                    role: .destructive,
                    isEnabled: viewModel.canUninstall
                ) {
                    if viewModel.settings.confirmBeforeClean {
                        showConfirmSheet = true
                    } else {
                        Task { await viewModel.uninstall(confirmed: true) }
                    }
                }
            } else if case .completed = viewModel.phase {
                GradientButton(L10n.string("Done"), systemImage: "checkmark", role: .success) {
                    viewModel.reset()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.Colors.backgroundAlt)
    }

    // MARK: - Sheets

    private var confirmSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.Colors.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(
                        "Uninstall %@?",
                        viewModel.selectedApp?.presentationName ?? ""
                    ))
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(L10n.string("%@ items will be moved to Trash. You can restore them from History until you empty the Trash.", "\(viewModel.selectedItems.count)"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
            }
            if let warning = viewModel.quitWarning {
                warningBanner(warning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.selectedItems.prefix(50)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.textTertiary)
                            Text(item.name)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            SizeBadge(bytes: item.size)
                        }
                        .padding(.vertical, 3)
                    }
                    if viewModel.selectedItems.count > 50 {
                        Text(L10n.string("…and %@ more", "\(viewModel.selectedItems.count - 50)"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .padding(.top, 4)
                    }
                }
            }
            .frame(maxHeight: 240)
            HStack {
                Spacer()
                GhostButton(L10n.string("Cancel"), role: .cancel) { showConfirmSheet = false }
                GradientButton(L10n.string("Uninstall"), systemImage: "trash.fill", role: .destructive) {
                    showConfirmSheet = false
                    Task { await viewModel.uninstall(confirmed: true) }
                }
            }
        }
        .padding(20)
        .frame(width: 500, height: 460)
        .themedBackground()
    }

    private var resultSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let manifest = viewModel.lastManifest {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.Colors.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("Uninstalled"))
                            .font(Theme.Typography.sectionTitle)
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Text(L10n.string("Reclaimed %@ across %@ items.", "\(ByteCount.format(manifest.bytesReclaimed))", "\(manifest.itemCount)"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    Spacer()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(manifest.entries.prefix(100)) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.Colors.textTertiary)
                                Text((entry.originalPath as NSString).lastPathComponent)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                SizeBadge(bytes: entry.size)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            HStack {
                Spacer()
                GradientButton(L10n.string("Done"), systemImage: "checkmark", role: .success) {
                    showResultSheet = false
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .themedBackground()
    }
}

// MARK: - App row (left pane)

private struct AppRow: View {
    let app: AppBundleInfo
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                AppIconView(path: app.path, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.presentationName)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .lineLimit(1)
                        if app.isRunning {
                            Circle()
                                .fill(Theme.Colors.success)
                                .frame(width: 6, height: 6)
                        }
                    }
                    HStack(spacing: 6) {
                        if !app.shortVersion.isEmpty {
                            Text(app.shortVersion)
                                .font(Theme.Typography.micro)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                        if app.size > 0 {
                            Text(ByteCount.compact(app.size))
                                .font(Theme.Typography.micro)
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .monospacedDigit()
                        }
                    }
                }
                Spacer(minLength: 0)
                if app.isSystemApp {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Theme.Colors.accent.opacity(0.28))
                          : AnyShapeStyle(isHovered ? Theme.Colors.selection : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .padding(.horizontal, 8)
        .opacity(app.isSystemApp ? 0.7 : 1.0)
    }
}

// MARK: - App icon view

/// Loads an app's icon from NSWorkspace on the main actor. Falls back to a
/// generic SF Symbol while loading or when the icon can't be read.
private struct AppIconView: View {
    let path: String
    let size: CGFloat

    @State private var icon: NSImage? = nil

    var body: some View {
        ZStack {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Theme.Colors.surfaceElevated)
                    .frame(width: size, height: size)
                Image(systemName: "app")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .onAppear { loadIcon() }
        .onChange(of: path) { _, _ in
            icon = nil
            loadIcon()
        }
    }

    private func loadIcon() {
        guard icon == nil else { return }
        let p = path
        Task { @MainActor in
            self.icon = NSWorkspace.shared.icon(forFile: p)
        }
    }
}

// MARK: - Preview

#Preview {
    UninstallerView(
        viewModel: UninstallerViewModel(
            fileSystem: LiveFileSystem(),
            appScanner: InstalledAppScanner(),
            leftoverFinder: LeftoverFinder(
                fileSystem: LiveFileSystem(),
                scanner: ScannerEngine(fileSystem: LiveFileSystem()),
                ruleLoader: RuleLoader()
            ),
            cleaner: CleanerService(
                fileSystem: LiveFileSystem(),
                history: HistoryStore()
            ),
            settings: SettingsStore()
        )
    )
    .frame(width: 1000, height: 680)
}
