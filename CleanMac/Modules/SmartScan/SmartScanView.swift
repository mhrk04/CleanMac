//
//  SmartScanView.swift
//  CleanMac
//
//  The landing page. Hero progress ring, three module cards summarising
//  each sub-scan, a review list of what was found, and one Clean CTA.
//

import SwiftUI
import AppKit

public struct SmartScanView: View {
    @ObservedObject public var viewModel: SmartScanViewModel
    /// Invoked when the user taps a module card to jump to that module.
    public var onOpenModule: ((SidebarItem) -> Void)?

    @State private var showConfirmSheet = false
    @State private var showResultSheet = false

    public init(
        viewModel: SmartScanViewModel,
        onOpenModule: ((SidebarItem) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenModule = onOpenModule
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Colors.separator)
            ScrollView {
                VStack(spacing: 24) {
                    heroCard
                    moduleCards
                    if viewModel.phase == .reviewing || viewModel.phase == .cleaning {
                        reviewSection
                    }
                    if viewModel.phase == .idle {
                        historySection
                    }
                }
                .padding(24)
            }
            Divider().background(Theme.Colors.separator)
            footer
        }
        .themedBackground()
        .sheet(isPresented: $showConfirmSheet) { confirmSheet }
        .sheet(isPresented: $showResultSheet) { resultSheet }
        .onAppear { viewModel.refreshHistoryStats() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Smart Scan"))
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
        case .idle: return L10n.string("One pass over junk, large files, and leftover app data.")
        case .scanning: return L10n.string("Scanning your Mac…")
        case .reviewing: return L10n.string("Review what was found, then clean it all at once.")
        case .cleaning: return L10n.string("Moving items to the Trash…")
        case .completed: return L10n.string("Scan finished.")
        case .failed: return L10n.string("The scan could not complete.")
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        switch viewModel.phase {
        case .scanning:
            GhostButton(L10n.string("Cancel"), systemImage: "xmark.circle") {
                viewModel.cancelScan()
            }
        case .reviewing:
            GhostButton(L10n.string("Rescan"), systemImage: "arrow.clockwise") {
                viewModel.startScan()
            }
        case .completed:
            GhostButton(L10n.string("Scan Again"), systemImage: "arrow.clockwise") {
                viewModel.startScan()
            }
        case .failed:
            GhostButton(L10n.string("Try Again"), systemImage: "arrow.clockwise") {
                viewModel.startScan()
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        HStack(spacing: 32) {
            ScanProgressRing(
                progress: heroProgress,
                primaryValue: viewModel.heroValue,
                primaryLabel: viewModel.heroLabel,
                secondaryText: nil,
                isAnimating: viewModel.phase == .scanning || viewModel.phase == .cleaning,
                diameter: Theme.Metrics.heroRingSize,
                lineWidth: 14
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(heroTitle)
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(viewModel.heroSubtitle)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(2)

                if viewModel.phase == .idle || viewModel.phase == .reviewing {
                    heroPrimaryButton
                        .padding(.top, 6)
                }

                if viewModel.phase == .reviewing && !viewModel.reviewItems.isEmpty {
                    Toggle(isOn: Binding(
                        get: { viewModel.includeReviewItems },
                        set: { viewModel.setIncludeReviewItems($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.plural(
                                "Include %@ item needing review",
                                "Include %@ items needing review",
                                viewModel.reviewItems.count
                            ))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                            Text(L10n.string("Large files and unusual leftovers stay unchecked by default."))
                                .font(Theme.Typography.micro)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.Colors.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .gradientCard()
    }

    private var heroProgress: Double {
        switch viewModel.phase {
        case .scanning: return viewModel.overallProgress
        case .cleaning: return viewModel.cleanProgress.fractionComplete
        case .completed: return 1
        case .failed: return 1
        default: return 0
        }
    }

    private var heroTitle: String {
        switch viewModel.phase {
        case .idle:
            return viewModel.lastScanDate == nil ? L10n.string("Your Mac, tidied") : L10n.string("Ready when you are")
        case .scanning: return L10n.string("Scanning")
        case .reviewing: return L10n.string("Here's what we found")
        case .cleaning: return L10n.string("Cleaning")
        case .completed: return L10n.string("All done")
        case .failed: return L10n.string("Scan failed")
        }
    }

    @ViewBuilder
    private var heroPrimaryButton: some View {
        if viewModel.phase == .idle {
            GradientButton(
                L10n.string("Scan"),
                systemImage: "sparkles",
                role: .primary,
                isEnabled: !viewModel.isBusy
            ) {
                viewModel.startScan()
            }
        } else {
            GradientButton(
                cleanButtonTitle,
                systemImage: "trash",
                role: .destructive,
                isEnabled: viewModel.canClean,
                isLoading: viewModel.phase == .cleaning
            ) {
                handleClean()
            }
        }
    }

    private var cleanButtonTitle: String {
        let count = viewModel.selectedItems.count
        guard count > 0 else { return L10n.string("Nothing selected") }
        return L10n.string(
            "%1$@ · %2$@",
            L10n.plural("Clean %@ item", "Clean %@ items", count),
            ByteCount.compact(viewModel.selectedSize)
        )
    }

    private func handleClean() {
        if viewModel.settings.confirmBeforeClean {
            showConfirmSheet = true
        } else {
            Task { await viewModel.clean(confirmed: true) }
        }
    }

    // MARK: - Module cards

    private var moduleCards: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240, maximum: .infinity), spacing: 16)],
            alignment: .leading,
            spacing: 16
        ) {
            moduleCard(for: viewModel.junkStatus, sidebar: .systemJunk)
            moduleCard(for: viewModel.largeStatus, sidebar: .largeAndOld)
            moduleCard(for: viewModel.orphanStatus, sidebar: .uninstaller)
        }
    }

    private func moduleCard(
        for status: SmartScanViewModel.ModuleStatus,
        sidebar: SidebarItem
    ) -> some View {
        let selected = viewModel.isModuleFullySelected(status.id)
        return ModuleCard(
            title: status.name,
            subtitle: status.stateLabel,
            systemImage: status.systemImage,
            accentColor: status.accent,
            sizeBytes: status.isComplete && status.sizeBytes > 0 ? status.sizeBytes : nil,
            itemCount: status.isComplete ? status.itemCount : nil,
            isEnabled: status.isComplete,
            isBusy: status.isRunning
        ) {
            if viewModel.hasResults {
                viewModel.toggleModule(status.id)
            } else {
                onOpenModule?(sidebar)
            }
        }
        .overlay(alignment: .topTrailing) {
            if status.isComplete && status.itemCount > 0 {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? status.accent : Theme.Colors.textTertiary)
                    .padding(10)
            }
        }
        .opacity(status.errorMessage == nil ? 1 : 0.85)
    }

    // MARK: - Review list

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.string("Details"))
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                if viewModel.safeItems.count > 0 {
                    GhostButton(L10n.string("Select safe items"), systemImage: "checkmark.shield") {
                        viewModel.selectAllSafe()
                    }
                }
                GhostButton(L10n.string("Deselect all"), systemImage: "square") {
                    viewModel.deselectAll()
                }
            }

            if let manifestFailures = viewModel.lastManifest?.failures, !manifestFailures.isEmpty {
                failuresBanner(manifestFailures)
            }

            ForEach(viewModel.moduleStatuses) { status in
                if status.itemCount > 0 {
                    moduleDetail(status)
                }
            }
        }
    }

    private func moduleDetail(_ status: SmartScanViewModel.ModuleStatus) -> some View {
        let items = items(for: status.id)
        return VStack(alignment: .leading, spacing: 8) {
            CategoryRow(
                title: status.name,
                systemImage: status.systemImage,
                itemCount: items.count,
                sizeBytes: items.reduce(0) { $0 + $1.size },
                accentColor: status.accent,
                safety: dominantSafety(items),
                isSelected: Binding(
                    get: { viewModel.isModuleFullySelected(status.id) },
                    set: { _ in viewModel.toggleModule(status.id) }
                ),
                isExpanded: Binding(
                    get: { expandedModules.contains(status.id) },
                    set: { newValue in
                        if newValue { expandedModules.insert(status.id) }
                        else { expandedModules.remove(status.id) }
                    }
                ),
                annotation: status.stateLabel
            ) {
                AnyView(
                    VStack(spacing: 0) {
                        ForEach(items.prefix(rowLimit)) { item in
                            ScanItemRow(
                                item: item,
                                isSelected: Binding(
                                    get: { viewModel.selectedIDs.contains(item.id) },
                                    set: { _ in viewModel.toggle(item: item) }
                                ),
                                onReveal: { viewModel.reveal($0) }
                            )
                            Divider().background(Theme.Colors.separator)
                        }
                        if items.count > rowLimit {
                            Text(L10n.string("and %@ more — open the %@ module for the full list", "\(items.count - rowLimit)", "\(status.name)"))
                                .font(Theme.Typography.micro)
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                    }
                )
            }
        }
    }

    private let rowLimit = 50
    @State private var expandedModules: Set<String> = []

    private func items(for moduleID: String) -> [ScanItem] {
        switch moduleID {
        case "junk": return viewModel.junkItems
        case "large": return viewModel.largeItems
        case "orphans": return viewModel.orphanItems
        default: return []
        }
    }

    private func dominantSafety(_ items: [ScanItem]) -> SafetyLevel? {
        guard !items.isEmpty else { return nil }
        if items.contains(where: { $0.safety == .dangerous }) { return .dangerous }
        if items.contains(where: { $0.safety == .review }) { return .review }
        return .safe
    }

    private func failuresBanner(_ failures: [CleanManifest.Failure]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.plural(
                    "%@ item could not be removed",
                    "%@ items could not be removed",
                    failures.count
                ))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(failures.prefix(3).map(\.reason).joined(separator: " · "))
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.Colors.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
    }

    // MARK: - History summary (idle state)

    private var historySection: some View {
        HStack(spacing: 16) {
            statTile(
                title: L10n.string("Total reclaimed"),
                value: ByteCount.format(viewModel.totalReclaimedAllTime),
                systemImage: "arrow.down.circle.fill",
                accent: Theme.Colors.success
            )
            statTile(
                title: L10n.string("Cleans performed"),
                value: "\(viewModel.cleanCountAllTime)",
                systemImage: "checkmark.seal.fill",
                accent: Theme.Colors.accent
            )
            statTile(
                title: L10n.string("Last clean"),
                value: lastCleanLabel,
                systemImage: "clock.fill",
                accent: Theme.Colors.info
            )
        }
    }

    private var lastCleanLabel: String {
        guard let d = viewModel.lastCleanDate else { return L10n.string("Never") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func statTile(title: String, value: String, systemImage: String, accent: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text(value)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .card()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(footerPrimary)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(footerSecondary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
            switch viewModel.phase {
            case .scanning:
                GhostButton(L10n.string("Cancel"), systemImage: "xmark.circle", role: .cancel) {
                    viewModel.cancelScan()
                }
            case .completed:
                GradientButton(L10n.string("View Details"),
                    systemImage: "list.bullet",
                    role: .primary,
                    size: .regular
                ) {
                    showResultSheet = true
                }
                GradientButton(
                    L10n.string("Done"),
                    systemImage: "checkmark",
                    role: .success,
                    size: .regular
                ) {
                    viewModel.reset()
                }
            default:
                GradientButton(
                    cleanButtonTitle,
                    systemImage: "trash",
                    role: .destructive,
                    isEnabled: viewModel.canClean,
                    isLoading: viewModel.phase == .cleaning,
                    size: .regular
                ) {
                    handleClean()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var footerPrimary: String {
        switch viewModel.phase {
        case .idle:
            return viewModel.lastScanDate == nil
                ? L10n.string("No scan yet")
                : L10n.string("Scan complete")
        case .scanning:
            // `%%` is a literal percent sign; a bare trailing `%` would be an
            // unterminated conversion specifier.
            return L10n.string("Scanning — %@%%", "\(Int(viewModel.overallProgress * 100))")
        case .reviewing:
            let count = viewModel.selectedItems.count
            return count == 0
                ? L10n.string("Nothing selected")
                : L10n.plural("%@ item selected", "%@ items selected", count)
        case .cleaning:
            return L10n.string(
                "%@ of %@ processed", 
                "\(viewModel.cleanProgress.itemsProcessed)", 
                "\(viewModel.cleanProgress.itemsTotal)"
            )
        case .completed(let m):
            return L10n.string("%@ moved to the Trash", "\(ByteCount.format(m.bytesReclaimed))")
        case .failed:
            return L10n.string("Scan failed")
        }
    }

    private var footerSecondary: String {
        switch viewModel.phase {
        case .reviewing:
            return viewModel.selectedItems.isEmpty
                ? L10n.string("Pick items above, then clean them.")
                : L10n.string("%@ will be moved to the Trash — recoverable at any time.", "\(ByteCount.format(viewModel.selectedSize))")
        case .cleaning:
            return viewModel.cleanProgress.currentPath ?? L10n.string("Working…")
        case .completed(let m):
            return m.failures.isEmpty
                ? L10n.string("Everything succeeded. You can restore it from History.")
                : L10n.plural(
                    "%@ item was protected and skipped.",
                    "%@ items were protected and skipped.",
                    m.failures.count
                )
        case .failed(let message):
            return message
        case .scanning:
            return viewModel.progress.currentPath ?? viewModel.progress.statusMessage ?? L10n.string("Reading your disk…")
        case .idle:
            return L10n.string("Safe items are pre-selected. Anything that needs a human decision is left unchecked.")
        }
    }

    // MARK: - Sheets

    private var confirmSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Colors.warning)
                Text(L10n.plural(
                    "Move %@ item to the Trash?",
                    "Move %@ items to the Trash?",
                    viewModel.selectedItems.count
                ))
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
            }

            Text(L10n.string("%@ will be freed. Everything goes to the Trash first, so you can restore it from History if something breaks.", "\(ByteCount.format(viewModel.selectedSize))"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.selectedItems.prefix(50)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.category.symbolName)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .frame(width: 16)
                            Text(item.name)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(ByteCount.compact(item.size))
                                .font(Theme.Typography.micro)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        Text(item.displayPath)
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if viewModel.selectedItems.count > 50 {
                        Text(L10n.string("…and %@ more", "\(viewModel.selectedItems.count - 50)"))
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
            }
            .frame(maxHeight: 260)
            .padding(12)
            .background(Theme.Colors.background.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))

            HStack {
                Spacer()
                GhostButton(L10n.string("Cancel"), role: .cancel) { showConfirmSheet = false }
                GradientButton(L10n.string("Move to Trash"),
                    systemImage: "trash",
                    role: .destructive,
                    size: .regular
                ) {
                    showConfirmSheet = false
                    Task { await viewModel.clean(confirmed: true) }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .themedBackground()
    }

    private var resultSheet: some View {
        let manifest = viewModel.lastManifest
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.Colors.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Scan complete"))
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(manifest == nil ? L10n.string("Nothing was removed.") : L10n.string("%@ reclaimed across %@ items.", "\(ByteCount.format(manifest?.bytesReclaimed ?? 0))", "\(manifest?.entries.count ?? 0)"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
            }

            if let manifest, !manifest.entries.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(manifest.entries.prefix(100)) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Colors.textTertiary)
                                Text((entry.originalPath as NSString).lastPathComponent)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text(ByteCount.compact(entry.size))
                                    .font(Theme.Typography.micro)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
                .padding(12)
                .background(Theme.Colors.background.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
            }

            HStack {
                Spacer()
                GhostButton(L10n.string("Close"), role: .cancel) { showResultSheet = false }
                GradientButton(L10n.string("Open History"),
                    systemImage: "clock.arrow.circlepath",
                    role: .primary,
                    size: .regular
                ) {
                    showResultSheet = false
                    onOpenModule?(.history)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .themedBackground()
    }
}
