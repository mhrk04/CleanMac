//
//  SystemJunkView.swift
//  CleanMac
//
//  System Junk module UI. Header with total reclaimable size, list of
//  rule-grouped categories with expandable item lists, and a footer bar
//  with selection total + Clean CTA.
//

import SwiftUI

public struct SystemJunkView: View {
    @ObservedObject public var viewModel: SystemJunkViewModel
    @State private var showConfirmSheet = false
    @State private var showResultSheet = false

    public init(viewModel: SystemJunkViewModel) {
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
            if viewModel.phase == .idle && viewModel.items.isEmpty {
                viewModel.startScan()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("System Junk"))
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
        case .idle: return L10n.string("Scan for caches, logs, and other reclaimable files.")
        case .scanning:
            let path = viewModel.progress.currentPath ?? ""
            return path.isEmpty ? L10n.string("Scanning…") : L10n.string("Scanning %@", "\(path)")
        case .reviewing:
            return L10n.string(
                "%@ items found across %@ categories.", 
                "\(viewModel.items.count)", 
                "\(viewModel.groupedItems().count)"
            )
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
        case .failed(let msg):
            return msg
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        switch viewModel.phase {
        case .scanning:
            GhostButton(L10n.string("Cancel"), systemImage: "xmark", role: .cancel) {
                viewModel.cancelScan()
            }
        case .reviewing:
            GhostButton(L10n.string("Select All"), systemImage: "checkmark.circle") { viewModel.selectAll() }
            GhostButton(L10n.string("Deselect"), systemImage: "circle") { viewModel.deselectAll() }
            GhostButton(L10n.string("Rescan"), systemImage: "arrow.clockwise") { viewModel.startScan() }
        case .completed:
            GhostButton(L10n.string("Done"), systemImage: "checkmark") { viewModel.reset() }
            GhostButton(L10n.string("Rescan"), systemImage: "arrow.clockwise") { viewModel.startScan() }
        default:
            GradientButton(L10n.string("Scan"), systemImage: "sparkles", size: .regular) {
                viewModel.startScan()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            emptyState(
                title: L10n.string("Ready to scan"),
                message: L10n.string("CleanMac will look through caches, logs, unused language files, developer artefacts, Trash bins, and more."),
                icon: "externaldrive.badge.timemachine",
                accent: Theme.Colors.accentSecondary
            )
        case .scanning:
            scanningState
        case .reviewing:
            reviewList
        case .cleaning:
            cleaningState
        case .completed(let manifest):
            completedState(manifest)
        case .failed(let message):
            emptyState(
                title: L10n.string("Scan failed"),
                message: message,
                icon: "exclamationmark.triangle",
                accent: Theme.Colors.danger
            )
        }
    }

    private var scanningState: some View {
        VStack(spacing: 20) {
            ScanProgressRing(
                progress: viewModel.progress.fractionComplete,
                primaryValue: ByteCount.compact(viewModel.progress.bytesFound),
                primaryLabel: L10n.string("%@ items found", "\(viewModel.progress.itemsFound)"),
                secondaryText: viewModel.progress.currentPath,
                isAnimating: true
            )
            Text(viewModel.progress.statusMessage ?? L10n.string("Scanning…"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
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
                    Text(L10n.plural(
                        "%@ item could not be moved.",
                        "%@ items could not be moved.",
                        manifest.failures.count
                    ))
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

    private var reviewList: some View {
        ScrollView(showsIndicators: true) {
            LazyVStack(spacing: 8) {
                let groups = viewModel.groupedItems()
                if groups.isEmpty {
                    emptyState(
                        title: L10n.string("Nothing to clean"),
                        message: L10n.string("No junk files matched your current rule set. Try again after using your Mac for a while."),
                        icon: "checkmark.seal",
                        accent: Theme.Colors.success
                    )
                } else {
                    ForEach(groups, id: \.rule.id) { group in
                        categoryCard(rule: group.rule, items: group.items)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func categoryCard(rule: Rule, items: [ScanItem]) -> some View {
        let isExpanded = viewModel.expandedCategories.contains(rule.id)
        let allSelected = !items.isEmpty && items.allSatisfy { viewModel.selectedIDs.contains($0.id) }
        return CategoryRow(
            title: rule.name,
            systemImage: rule.category.symbolName,
            itemCount: items.count,
            sizeBytes: items.reduce(0) { $0 + $1.size },
            accentColor: rule.safety.tint,
            safety: rule.safety,
            isSelected: Binding(
                get: { allSelected },
                set: { _ in viewModel.toggle(rule: rule, all: items) }
            ),
            isExpanded: Binding(
                get: { isExpanded },
                set: { newValue in
                    if newValue { viewModel.expandedCategories.insert(rule.id) }
                    else { viewModel.expandedCategories.remove(rule.id) }
                }
            ),
            annotation: rule.description
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

    private func emptyState(title: String, message: String, icon: String, accent: Color) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(accent)
            }
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if viewModel.phase == .reviewing {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("%@ items selected", "\(viewModel.selectedIDs.count)"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text(ByteCount.format(viewModel.selectedSize))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                Spacer()
                GradientButton(L10n.string("Clean %@", "\(ByteCount.compact(viewModel.selectedSize))"),
                    systemImage: "trash.fill",
                    role: .destructive,
                    isEnabled: viewModel.canClean
                ) {
                    showConfirmSheet = true
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(height: 68)
    }

    // MARK: - Sheets

    private var confirmSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warning)
                Text(L10n.string("Move these items to the Trash?"))
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
            Text(L10n.string("Everything goes to the Trash first, so you can restore it from History if something breaks."))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.selectedItems.prefix(50)) { item in
                        HStack {
                            Text(item.name)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Spacer()
                            SizeBadge(bytes: item.size)
                        }
                    }
                    if viewModel.selectedItems.count > 50 {
                        Text(L10n.string("…and %@ more", "\(viewModel.selectedItems.count - 50)"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack {
                Spacer()
                GhostButton(L10n.string("Cancel"), role: .cancel) { showConfirmSheet = false }
                GradientButton(L10n.string("Move to Trash"),
                    systemImage: "trash.fill",
                    role: .destructive
                ) {
                    showConfirmSheet = false
                    Task { await viewModel.clean(confirmed: true) }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.Colors.surface)
    }

    private var resultSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let manifest = viewModel.lastManifest {
                Text(manifest.displayLabel)
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                // A duration figure is data, not copy: it is formatted here so
                // the localization key stays free of numeric specifiers.
                let seconds = String(format: "%.1f", manifest.duration)
                Text(L10n.string(
                    "%@ items · %@ reclaimed · %@s",
                    "\(manifest.itemCount)",
                    ByteCount.format(manifest.bytesReclaimed),
                    seconds
                ))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                if !manifest.failures.isEmpty {
                    Divider().background(Theme.Colors.separator)
                    Text(L10n.string("Failures"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.warning)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(manifest.failures) { f in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((f.path as NSString).lastPathComponent)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                    Text(f.reason)
                                        .font(Theme.Typography.micro)
                                        .foregroundStyle(Theme.Colors.textTertiary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
                HStack {
                    Spacer()
                    GhostButton(L10n.string("Close")) { showResultSheet = false }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.Colors.surface)
    }
}
