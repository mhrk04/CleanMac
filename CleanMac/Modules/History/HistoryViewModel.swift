//
//  HistoryViewModel.swift
//  CleanMac
//
//  Drives the History screen: lists every saved CleanManifest, exposes
//  totals, and coordinates restore + delete operations.
//

import Foundation
import SwiftUI
import Combine

@MainActor
public final class HistoryViewModel: ObservableObject {

    public enum Phase: Equatable {
        case loading
        case ready
        case restoring(CleanManifest)
        case failed(String)
    }

    // MARK: - Dependencies

    private let history: HistoryStore
    private let cleaner: CleanerService
    public let settings: SettingsStore

    // MARK: - Published state

    @Published public var phase: Phase = .loading
    @Published public private(set) var manifests: [CleanManifest] = []
    @Published public var selectedManifestID: UUID? = nil
    @Published public var searchText: String = ""
    @Published public var restoreProgress: CleanProgress = .idle
    @Published public var lastRestoreResult: CleanManifest? = nil
    @Published public var errorMessage: String? = nil
    @Published public var totalReclaimed: Int64 = 0

    private var loadTask: Task<Void, Never>?

    public init(
        history: HistoryStore,
        cleaner: CleanerService,
        settings: SettingsStore
    ) {
        self.history = history
        self.cleaner = cleaner
        self.settings = settings
    }

    // MARK: - Derived

    public var filteredManifests: [CleanManifest] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return manifests }
        return manifests.filter { manifest in
            manifest.displayLabel.lowercased().contains(trimmed)
                || manifest.source.lowercased().contains(trimmed)
                || manifest.entries.contains { $0.originalPath.lowercased().contains(trimmed) }
        }
    }

    public var selectedManifest: CleanManifest? {
        guard let id = selectedManifestID else { return nil }
        return manifests.first { $0.id == id }
    }

    public var cleanCount: Int { manifests.count }

    public var totalItems: Int { manifests.reduce(0) { $0 + $1.itemCount } }

    public var isRestoring: Bool {
        if case .restoring = phase { return true }
        return false
    }

    // MARK: - Loading

    public func load() {
        loadTask?.cancel()
        loadTask = Task { [history] in
            let all = await history.all()
            let total = await history.totalReclaimed()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.manifests = all.sorted { $0.finishedAt > $1.finishedAt }
                self.totalReclaimed = total
                if self.selectedManifestID == nil {
                    self.selectedManifestID = self.manifests.first?.id
                }
                self.phase = .ready
            }
        }
    }

    // MARK: - Actions

    public func select(_ manifest: CleanManifest) {
        selectedManifestID = manifest.id
    }

    /// Move every entry of `manifest` back from the Trash to its original path.
    @discardableResult
    public func restore(_ manifest: CleanManifest) async -> Bool {
        guard !isRestoring else { return false }
        errorMessage = nil
        phase = .restoring(manifest)
        restoreProgress = CleanProgress(
            itemsTotal: manifest.entries.count,
            itemsProcessed: 0,
            bytesFreed: 0
        )

        let result = await cleaner.restore(manifest: manifest) { [weak self] p in
            Task { @MainActor in self?.restoreProgress = p }
        }

        lastRestoreResult = result
        if result.failures.isEmpty {
            // The manifest is no longer restorable — drop it from History.
            try? await history.delete(id: manifest.id)
            settings.addBytesReclaimed(-result.bytesReclaimed)
        } else if result.entries.isEmpty {
            errorMessage = result.failures.first?.reason ?? L10n.string("Nothing could be restored.")
        } else {
            errorMessage = L10n.string(
                "%@ of %@ items could not be restored — the Trash may have been emptied.", 
                "\(result.failures.count)", 
                "\(manifest.entries.count)"
            )
        }

        load()
        return result.entries.isEmpty == false
    }

    public func delete(_ manifest: CleanManifest) {
        Task { [history] in
            try? await history.delete(id: manifest.id)
            await MainActor.run { [weak self] in
                if self?.selectedManifestID == manifest.id { self?.selectedManifestID = nil }
                self?.load()
            }
        }
    }

    public func deleteAll() {
        Task { [history] in
            try? await history.deleteAll()
            await MainActor.run { [weak self] in
                self?.selectedManifestID = nil
                self?.load()
            }
        }
    }

    /// Directory holding the manifest JSON files. Resolved statically so
    /// callers never have to await into the HistoryStore actor.
    public var storageDirectory: String { HistoryStore.defaultDirectory() }

    public func revealInFinder(_ manifest: CleanManifest) {
        let url = URL(fileURLWithPath: storageDirectory)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open the history folder in Finder, falling back to its parent when the
    /// folder has not been created yet (no clean has ever run).
    ///
    /// This is the one place that deliberately stays on `FileManager` rather
    /// than the `FileSystem` protocol: the answer is handed straight to
    /// `NSWorkspace`, which can only ever act on the *real* volume. Routing the
    /// existence check through an injected mock would make the two disagree and
    /// point Finder at a directory that is not there.
    public func revealStorageDirectory() {
        let path = storageDirectory
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
            ])
        }
    }

    public func dismissError() {
        errorMessage = nil
        lastRestoreResult = nil
    }
}
