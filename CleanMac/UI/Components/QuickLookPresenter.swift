//
//  QuickLookPresenter.swift
//  CleanMac
//
//  Bridges the "Quick Look" row action to AppKit's `QLPreviewPanel`.
//
//  `NSWorkspace.open(_:)` is *not* Quick Look — it launches the file in its
//  default editor. From a disk-cleaning UI that is exactly the wrong behaviour:
//  the user asked to glance at a 4 GB video to decide whether to trash it, not
//  to open it in a video editor. `QLPreviewPanel` previews in place, read-only,
//  and can page through several files at once.
//

import AppKit
// QuickLookUI predates Swift concurrency and does not annotate `QLPreviewItem`
// as `Sendable`. The item never crosses an isolation boundary here — it is
// handed straight back to the panel on the main thread — so `@preconcurrency`
// is the correct way to keep this warning-free under strict concurrency.
@preconcurrency import QuickLookUI

@MainActor
public final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    public static let shared = QuickLookPresenter()

    private var urls: [URL] = []

    private override init() {
        super.init()
    }

    /// Preview `urls` in the shared Quick Look panel, replacing any current
    /// contents.
    ///
    /// Silently does nothing when the list is empty or the panel is unavailable
    /// (it can be `nil` before any window has become key). Quick Look is a
    /// convenience, never a critical path, so it must not throw at the caller.
    public func preview(_ urls: [URL]) {
        let previewable = urls.filter { $0.isFileURL }
        guard !previewable.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = previewable
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Convenience for the common single-file case.
    public func preview(_ url: URL) {
        preview([url])
    }

    /// Dismiss the panel if it is on screen.
    public func dismiss() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
        urls = []
    }

    /// Whether the panel is currently showing.
    public var isPresenting: Bool {
        QLPreviewPanel.shared()?.isVisible ?? false
    }

    // MARK: - QLPreviewPanelDataSource
    //
    // The protocol itself is not main-actor annotated, but Quick Look only ever
    // calls these on the main thread while the panel is up, so hopping through
    // `assumeIsolated` is both correct and cheaper than a Task round-trip.

    nonisolated public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated public func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            guard urls.indices.contains(index) else { return nil }
            return urls[index] as NSURL
        }
    }
}
