//
//  LargeAndOldView.swift
//  CleanMac
//
//  Large & Old Files module UI. Two-pane layout: filter sidebar on the
//  left (search roots, size/age chips, presets), paginated file list on
//  the right with checkbox rows, size badges, and last-opened dates.
//

import SwiftUI
import AppKit

public struct LargeAndOldView: View {
    @ObservedObject public var viewModel: LargeAndOldViewModel
    @State private var showConfirmSheet = false
    @State private var showResultSheet = false
    @State private var customSizeMB: Int = 100

    public init(viewModel: LargeAndOldViewModel) {
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
                // Don't auto-scan: the user should choose folders first.
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Large & Old Files"))
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
            return L10n.string("Find big files you haven't opened in months.")
        case .scanning:
            let path = viewModel.progress.currentPath ?? ""
            return path.isEmpty ? L10n.string("Scanning…") : L10n.string("Scanning %@", "\(path)")
        case .reviewing:
            return L10n.string(
                "%@ files · %@ total", 
                "\(viewModel.items.count)", 
                "\(ByteCount.format(viewModel.totalSize))")
        case .cleaning:
            return L10n.string(
                "Moving %@ files to Trash…", 
                "\(viewModel.cleanProgress.itemsTotal)"
            )
        case .completed(let m):
            return L10n.string(
                "Freed %@ across %@ files.", 
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
            GhostButton(L10n.string("Select All"), systemImage: "checkmark.circle") { viewModel.selectAllVisible() }
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
            idleState
        case .scanning:
            scanningState
        case .reviewing:
            reviewLayout
        case .cleaning:
            cleaningState
        case .completed(let manifest):
            completedState(manifest)
        case .failed(let message):
            failedState(message)
        }
    }

    private var idleState: some View {
        HStack(alignment: .top, spacing: 0) {
            filterSidebar
            Divider().background(Theme.Colors.separator)
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Theme.Colors.info.opacity(0.15))
                        .frame(width: 76, height: 76)
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Theme.Colors.info)
                }
                Text(L10n.string("Choose folders, then scan"))
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(L10n.string("Pick the folders to search and the size / age filters. CleanMac will list every regular file that matches, biggest first."))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                GradientButton(L10n.string("Start Scan"), systemImage: "sparkles") {
                    viewModel.startScan()
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }

    private var scanningState: some View {
        VStack(spacing: 20) {
            ScanProgressRing(
                progress: viewModel.progress.fractionComplete,
                primaryValue: ByteCount.compact(viewModel.progress.bytesFound),
                primaryLabel: L10n.string("%@ files found", "\(viewModel.progress.itemsFound)"),
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
            Text(L10n.string("%@ of %@ files", "\(viewModel.cleanProgress.itemsProcessed)", "\(viewModel.cleanProgress.itemsTotal)"))
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
                secondaryText: L10n.string("%@ files moved to Trash", "\(manifest.itemCount)")
            )
            if !manifest.failures.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.warning)
                    Text(L10n.string("%@ files could not be moved.", "\(manifest.failures.count)"))
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
            Text(L10n.string("Scan failed"))
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            GradientButton(L10n.string("Try Again"), systemImage: "arrow.clockwise") {
                viewModel.startScan()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Review layout (two-pane)

    private var reviewLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            filterSidebar
            Divider().background(Theme.Colors.separator)
            fileList
        }
    }

    // MARK: - Filter sidebar

    private var filterSidebar: some View {
        ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeader(L10n.string("Folders"))
                folderList
                addFolderButton

                Divider().background(Theme.Colors.separator).padding(.vertical, 4)

                sectionHeader(L10n.string("Minimum size"))
                sizeChips

                Divider().background(Theme.Colors.separator).padding(.vertical, 4)

                sectionHeader(L10n.string("Not opened in"))
                ageChips

                if !viewModel.config.presets.isEmpty {
                    Divider().background(Theme.Colors.separator).padding(.vertical, 4)
                    sectionHeader(L10n.string("Presets"))
                    presetList
                }

                Divider().background(Theme.Colors.separator).padding(.vertical, 4)

                sectionHeader(L10n.string("Sort"))
                sortPicker

                Toggle(isOn: Binding(
                    get: { viewModel.settings.largeFileIncludeLibrary },
                    set: { viewModel.settings.largeFileIncludeLibrary = $0 }
                )) {
                    Text(L10n.string("Include ~/Library"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.Colors.accent)
            }
            .padding(16)
        }
        .frame(width: 240)
        .background(Theme.Colors.backgroundAlt)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Colors.textTertiary)
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.searchRoots.isEmpty {
                Text(L10n.string("No folders selected"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            } else {
                ForEach(viewModel.searchRoots, id: \.self) { root in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.accentSecondary)
                        Text(displayRoot(root))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button(action: { viewModel.removeSearchRoot(root) }) {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("Remove folder"))
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.Colors.surface)
                    )
                }
            }
        }
    }

    private func displayRoot(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private var addFolderButton: some View {
        Button(action: pickFolder) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                Text(L10n.string("Add Folder…"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.Colors.accent)
        }
        .buttonStyle(.plain)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = L10n.string("Choose folders to scan for large & old files")
        panel.prompt = L10n.string("Add")
        if panel.runModal() == .OK {
            for url in panel.urls {
                viewModel.addSearchRoot(url.path)
            }
        }
    }

    private var sizeChips: some View {
        FlowLayout(spacing: 6) {
            ForEach([50, 100, 500, 1024, 5120], id: \.self) { mb in
                chip(
                    // Unit suffixes are localized too: French renders a
                    // gigabyte as "Go" and a megabyte as "Mo", so hardcoding
                    // the symbol would break those locales.
                    label: mb >= 1024
                        ? L10n.string("%@ GB", "\(mb / 1024)")
                        : L10n.string("%@ MB", "\(mb)"),
                    isSelected: viewModel.sizeThresholdMB == mb,
                    action: { viewModel.setSizeThreshold(mb) }
                )
            }
            chip(
                label: L10n.string("Custom"),
                isSelected: ![50, 100, 500, 1024, 5120].contains(viewModel.sizeThresholdMB),
                action: { showCustomSizePrompt() }
            )
        }
    }

    private var ageChips: some View {
        FlowLayout(spacing: 6) {
            ForEach([30, 90, 180, 365, 730], id: \.self) { days in
                chip(
                    label: days >= 365
                        ? L10n.string("%@ yr", "\(days / 365)")
                        : L10n.string("%@ d", "\(days)"),
                    isSelected: viewModel.ageDays == days,
                    action: { viewModel.setAgeDays(days) }
                )
            }
            chip(
                label: L10n.string("Any"),
                isSelected: viewModel.ageDays == 0,
                action: { viewModel.setAgeDays(0) }
            )
        }
    }

    private func chip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Theme.Colors.accent.opacity(0.28) : Theme.Colors.surface)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? Theme.Colors.accent : Theme.Colors.separator, lineWidth: 1)
                )
                .foregroundStyle(isSelected ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func showCustomSizePrompt() {
        // Inline alert would be nicer; for MVP we cycle to 250 MB.
        viewModel.setSizeThreshold(250)
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(viewModel.config.presets) { preset in
                Button(action: {
                    viewModel.applyPreset(viewModel.activePreset?.id == preset.id ? nil : preset)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.activePreset?.id == preset.id
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(viewModel.activePreset?.id == preset.id
                                             ? Theme.Colors.accent : Theme.Colors.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            if !preset.extensions.isEmpty {
                                Text(preset.extensions.joined(separator: ", "))
                                    .font(Theme.Typography.micro)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.Colors.surface)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sortPicker: some View {
        HStack(spacing: 8) {
            // Deliberately label-less (`.labelsHidden()` below): the empty
            // string is an absent label, not copy, so it must not become a
            // localization key.
            Picker("", selection: Binding(
                get: { viewModel.sortKey },
                set: { viewModel.sortKey = $0 }
            )) {
                ForEach(LargeAndOldViewModel.SortKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.Colors.textPrimary)

            Button(action: { viewModel.sortAscending.toggle() }) {
                Image(systemName: viewModel.sortAscending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Colors.surface))
            }
            .buttonStyle(.plain)
            .help(viewModel.sortAscending ? L10n.string("Ascending") : L10n.string("Descending"))
        }
    }

    // MARK: - File list

    private var fileList: some View {
        VStack(spacing: 0) {
            if viewModel.visibleItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text(L10n.string("No files match your filters"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text(L10n.string("Try lowering the size threshold or widening the age window."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.visibleItems) { item in
                            LargeFileRow(
                                item: item,
                                isSelected: Binding(
                                    get: { viewModel.selectedIDs.contains(item.id) },
                                    set: { _ in viewModel.toggle(item: item) }
                                ),
                                onReveal: { viewModel.reveal($0) },
                                onQuickLook: { viewModel.quickLook($0) }
                            )
                            Divider().background(Theme.Colors.separator).padding(.leading, 44)
                        }
                        if viewModel.visibleCount < viewModel.items.count {
                            Button(action: { viewModel.loadMore() }) {
                                Text(L10n.string("Load %@ more", "\(min(100, viewModel.items.count - viewModel.visibleCount))"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.Colors.accent)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            switch viewModel.phase {
            case .reviewing:
                GradientButton(L10n.string("Move to Trash"),
                    systemImage: "trash.fill",
                    role: .destructive,
                    isEnabled: viewModel.canClean
                ) {
                    if viewModel.settings.confirmBeforeClean {
                        showConfirmSheet = true
                    } else {
                        Task { await viewModel.clean(confirmed: true) }
                    }
                }
            case .completed:
                GradientButton(L10n.string("Done"), systemImage: "checkmark", role: .success) {
                    viewModel.reset()
                }
            default:
                EmptyView()
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
                    .foregroundStyle(Theme.Colors.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Move %@ files to Trash?", "\(viewModel.selectedItems.count)"))
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(L10n.string("You can restore them from the Trash or from History until you empty it."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.selectedItems.prefix(50)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill")
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
                GradientButton(L10n.string("Move to Trash"), systemImage: "trash.fill", role: .destructive) {
                    showConfirmSheet = false
                    Task { await viewModel.clean(confirmed: true) }
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
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
                        Text(L10n.string("Moved %@ files to Trash", "\(manifest.itemCount)"))
                            .font(Theme.Typography.sectionTitle)
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Text(L10n.string("Reclaimed %@", "\(ByteCount.format(manifest.bytesReclaimed))"))
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
                if !manifest.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string("%@ could not be moved:", "\(manifest.failures.count)"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.warning)
                        ForEach(manifest.failures.prefix(5)) { f in
                            Text(L10n.string(
                                "• %@ — %@",
                                (f.path as NSString).lastPathComponent,
                                f.reason
                            ))
                                .font(Theme.Typography.micro)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                }
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

// MARK: - Large file row

private struct LargeFileRow: View {
    let item: ScanItem
    @Binding var isSelected: Bool
    var onReveal: ((ScanItem) -> Void)? = nil
    var onQuickLook: ((ScanItem) -> Void)? = nil

    @State private var isHovered = false
    @State private var icon: NSImage? = nil

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { isSelected.toggle() }) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Theme.Colors.accent : Theme.Colors.textTertiary)
            }
            .buttonStyle(.plain)

            ZStack {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .frame(width: 28, height: 28)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.displayPath)
                    .pathStyle()
            }
            Spacer(minLength: 0)

            if let date = item.contentAccessDate ?? item.modificationDate {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text(L10n.string("opened"))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.textTertiary.opacity(0.7))
                }
                .frame(width: 86, alignment: .trailing)
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
        .padding(.vertical, 7)
        .padding(.horizontal, 14)
        .background(
            Rectangle().fill(isHovered ? Theme.Colors.selection : Color.clear)
        )
        .onHover { isHovered = $0 }
        .onAppear { loadIcon() }
        .contextMenu {
            if let onQuickLook {
                Button(L10n.string("Quick Look")) { onQuickLook(item) }
            }
            if let onReveal {
                Button(L10n.string("Reveal in Finder")) { onReveal(item) }
            }
            Button(L10n.string("Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
            Divider()
            Button(L10n.string("Move to Trash"), role: .destructive) {
                isSelected = true
            }
        }
    }

    private func loadIcon() {
        guard icon == nil else { return }
        let path = item.path
        Task { @MainActor in
            self.icon = NSWorkspace.shared.icon(forFile: path)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - Simple flow layout for chips

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Preview

#Preview {
    LargeAndOldView(
        viewModel: LargeAndOldViewModel(
            fileSystem: LiveFileSystem(),
            cleaner: CleanerService(
                fileSystem: LiveFileSystem(),
                history: HistoryStore()
            ),
            settings: SettingsStore(),
            config: .empty
        )
    )
    .frame(width: 1000, height: 680)
}
