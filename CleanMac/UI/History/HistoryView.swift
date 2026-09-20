//
//  HistoryView.swift
//  CleanMac
//
//  Two-pane History screen. Left: every saved clean operation with date,
//  label, and reclaimed size. Right: the selected manifest's entries with
//  a Restore action that moves them back from the Trash.
//

import SwiftUI
import AppKit

public struct HistoryView: View {
    @ObservedObject public var viewModel: HistoryViewModel
    @State private var showRestoreConfirm = false
    @State private var showDeleteAllConfirm = false

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Colors.separator)
            content
        }
        .themedBackground()
        .sheet(isPresented: $showRestoreConfirm) { restoreConfirmSheet }
        .sheet(isPresented: $showDeleteAllConfirm) { deleteAllConfirmSheet }
        .onAppear { viewModel.load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("History"))
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
        if viewModel.manifests.isEmpty {
            return L10n.string("Nothing cleaned yet.")
        }
        // Both counts pluralise independently, so each clause is built on its
        // own and composed with positional placeholders, keeping the word
        // order translatable.
        let cleans = L10n.plural("%@ clean", "%@ cleans", viewModel.cleanCount)
        let items = L10n.plural("%@ item", "%@ items", viewModel.totalItems)
        return L10n.string(
            "%1$@ · %2$@ · %@ reclaimed",
            cleans,
            items,
            ByteCount.format(viewModel.totalReclaimed)
        )
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: 10) {
            searchField
            GhostButton(L10n.string("Reload"), systemImage: "arrow.clockwise") {
                viewModel.load()
            }
            GhostButton(L10n.string("Reveal Folder"), systemImage: "folder") {
                viewModel.revealStorageDirectory()
            }
            if !viewModel.manifests.isEmpty {
                GhostButton(L10n.string("Delete All"), systemImage: "trash", role: .destructive) {
                    showDeleteAllConfirm = true
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.textTertiary)
            TextField(L10n.string("Search history"), text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textPrimary)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 190)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.manifests.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                manifestList
                Divider().background(Theme.Colors.separator)
                detailPane
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(viewModel.searchText.isEmpty ? L10n.string("No cleanups yet") : L10n.string("No matches"))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(viewModel.searchText.isEmpty
                 ? L10n.string("Every clean you perform is logged here so you can put things back.")
                 : L10n.string("Try a different search term."))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var manifestList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(viewModel.filteredManifests) { manifest in
                    ManifestRow(
                        manifest: manifest,
                        isSelected: viewModel.selectedManifestID == manifest.id,
                        isRestoring: viewModel.isRestoring
                            && viewModel.selectedManifestID == manifest.id
                    ) {
                        viewModel.select(manifest)
                    }
                    .contextMenu {
                        Button(L10n.string("Restore…")) {
                            viewModel.select(manifest)
                            showRestoreConfirm = true
                        }
                        .disabled(viewModel.isRestoring)
                        Button(L10n.string("Delete Record"), role: .destructive) {
                            viewModel.delete(manifest)
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 300)
        .background(Theme.Colors.backgroundAlt)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let manifest = viewModel.selectedManifest {
            VStack(spacing: 0) {
                detailHeader(manifest)
                Divider().background(Theme.Colors.separator)
                if let message = viewModel.errorMessage {
                    errorBanner(message)
                }
                if viewModel.isRestoring {
                    restoreBanner
                }
                entryList(manifest)
                Divider().background(Theme.Colors.separator)
                detailFooter(manifest)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text(L10n.string("Select a cleanup to see what it removed"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ manifest: CleanManifest) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent(for: manifest).opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: symbol(for: manifest))
                    .font(.system(size: 19))
                    .foregroundStyle(accent(for: manifest))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(manifest.displayLabel)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(Self.dateFormatter.string(from: manifest.finishedAt))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                HStack(spacing: 10) {
                    metaChip(L10n.string("%@ items", "\(manifest.itemCount)"))
                    metaChip(ByteCount.format(manifest.bytesReclaimed))
                    if !manifest.failures.isEmpty {
                        metaChip(L10n.string("%@ skipped", "\(manifest.failures.count)"), color: Theme.Colors.warning)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func metaChip(_ text: String, color: Color = Theme.Colors.textSecondary) -> some View {
        Text(text)
            .font(Theme.Typography.micro)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func accent(for manifest: CleanManifest) -> Color {
        switch manifest.source {
        case "smart-scan": return Theme.Colors.accent
        case "system-junk": return Theme.Colors.accentSecondary
        case "uninstaller": return Theme.Colors.warning
        case "large-and-old": return Theme.Colors.info
        default: return Theme.Colors.success
        }
    }

    private func symbol(for manifest: CleanManifest) -> String {
        switch manifest.source {
        case "smart-scan": return "sparkles"
        case "system-junk": return "externaldrive.badge.timemachine"
        case "uninstaller": return "trash.square.fill"
        case "large-and-old": return "doc.text.magnifyingglass"
        default: return "trash"
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.warning)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                viewModel.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.Colors.warning.opacity(0.12))
    }

    private var restoreBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.string("Restoring %@ of %@…", "\(viewModel.restoreProgress.itemsProcessed)", "\(viewModel.restoreProgress.itemsTotal)"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
        }
        .padding(12)
        .background(Theme.Colors.accent.opacity(0.10))
    }

    private func entryList(_ manifest: CleanManifest) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !manifest.entries.isEmpty {
                    sectionLabel(L10n.string("Removed (%@)", "\(manifest.entries.count)"))
                    ForEach(manifest.entries) { entry in
                        EntryRow(entry: entry, tint: accent(for: manifest)) {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: entry.trashPath)
                            ])
                        }
                        Divider().background(Theme.Colors.separator)
                    }
                }
                if !manifest.failures.isEmpty {
                    sectionLabel(L10n.string("Skipped (%@)", "\(manifest.failures.count)"))
                    ForEach(manifest.failures) { failure in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.warning)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((failure.path as NSString).lastPathComponent)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                Text(failure.reason)
                                    .font(Theme.Typography.micro)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                                Text(failure.path)
                                    .pathStyle()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.Typography.micro)
            .foregroundStyle(Theme.Colors.textTertiary)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private func detailFooter(_ manifest: CleanManifest) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Restore puts everything back where it came from."))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(L10n.string("Only works while the items are still in the Trash."))
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer()
            GhostButton(L10n.string("Delete Record"), systemImage: "trash", role: .destructive) {
                viewModel.delete(manifest)
            }
            GradientButton(
                L10n.string("Restore"),
                systemImage: "arrow.uturn.backward",
                role: .primary,
                isEnabled: !manifest.entries.isEmpty && !viewModel.isRestoring,
                isLoading: viewModel.isRestoring,
                size: .regular
            ) {
                viewModel.select(manifest)
                showRestoreConfirm = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Sheets

    private var restoreConfirmSheet: some View {
        let manifest = viewModel.selectedManifest
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Colors.accent)
                Text(L10n.plural(
                    "Restore %@ item?",
                    "Restore %@ items?",
                    manifest?.itemCount ?? 0
                ))
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
            }

            Text(L10n.string("CleanMac will move each item from the Trash back to its original location. If you emptied the Trash since this clean, those items can't come back."))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

            HStack {
                Spacer()
                GhostButton(L10n.string("Cancel"), role: .cancel) { showRestoreConfirm = false }
                GradientButton(
                    L10n.string("Restore"),
                    systemImage: "arrow.uturn.backward",
                    role: .primary,
                    isEnabled: manifest != nil,
                    size: .regular
                ) {
                    showRestoreConfirm = false
                    if let manifest {
                        Task { await viewModel.restore(manifest) }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .themedBackground()
    }

    private var deleteAllConfirmSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Colors.danger)
                Text(L10n.string("Delete all history?"))
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
            }

            Text(L10n.string("This removes every cleanup record. Files already in the Trash stay there, but you will no longer be able to restore them from CleanMac."))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

            HStack {
                Spacer()
                GhostButton(L10n.string("Cancel"), role: .cancel) { showDeleteAllConfirm = false }
                GradientButton(L10n.string("Delete History"),
                    systemImage: "trash",
                    role: .destructive,
                    size: .regular
                ) {
                    showDeleteAllConfirm = false
                    viewModel.deleteAll()
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .themedBackground()
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Rows

private struct ManifestRow: View {
    let manifest: CleanManifest
    let isSelected: Bool
    let isRestoring: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(tint)
                    Text(manifest.displayLabel)
                        .font(Theme.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isRestoring {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(Self.relativeFormatter.localizedString(for: manifest.finishedAt, relativeTo: Date()))
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                HStack(spacing: 8) {
                    Text(ByteCount.compact(manifest.bytesReclaimed))
                        .font(Theme.Typography.micro)
                        .foregroundStyle(tint)
                    Text(L10n.string("·"))
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text(L10n.string("%@ items", "\(manifest.itemCount)"))
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                    .fill(isSelected ? Theme.Colors.selection : (isHovered ? Theme.Colors.surface : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var tint: Color {
        switch manifest.source {
        case "smart-scan": return Theme.Colors.accent
        case "system-junk": return Theme.Colors.accentSecondary
        case "uninstaller": return Theme.Colors.warning
        case "large-and-old": return Theme.Colors.info
        default: return Theme.Colors.success
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

private struct EntryRow: View {
    let entry: CleanManifest.Entry
    let tint: Color
    let onReveal: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.category == "application" ? "app.dashed" : "doc.fill")
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text((entry.originalPath as NSString).lastPathComponent)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                Text(entry.originalPath)
                    .pathStyle()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(ByteCount.compact(entry.size))
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.top, 2)

            if isHovered {
                Button(action: onReveal) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Reveal in Trash"))
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(isHovered ? Theme.Colors.surface.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
