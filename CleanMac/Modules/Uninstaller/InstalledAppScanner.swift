//
//  InstalledAppScanner.swift
//  CleanMac
//
//  Enumerates every installed .app bundle the Uninstaller module should show.
//  Combines on-disk scans of the standard Applications folders with the live
//  NSWorkspace running-application list so background-only apps (menu bar
//  items, helpers) still surface.
//

import Foundation
import AppKit
import Carbon

public struct InstalledAppScanner: Sendable {

    private let fs: FileSystem
    private let loader: AppBundleInfoLoader
    private let sizeCalculator: SizeCalculator

    public init(fileSystem: FileSystem = LiveFileSystem()) {
        self.fs = fileSystem
        self.loader = AppBundleInfoLoader(fileSystem: fileSystem)
        self.sizeCalculator = SizeCalculator(fileSystem: fileSystem)
    }

    /// Folders searched for .app bundles, in priority order.
    public static let searchFolders: [String] = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities"
    ]

    /// Scan every known location and return a de-duplicated list of bundles.
    ///
    /// - Parameters:
    ///   - includeSystemApps: when false, `/System/Applications*` entries are
    ///     still returned but flagged `isSystemApp = true` so the UI can grey
    ///     them out. When true they are treated like normal apps.
    ///   - computeSizes: when true, each bundle's size is computed (slow on
    ///     first scan; cache the result in the ViewModel).
    ///   - runningApps: snapshot of `NSWorkspace.shared.runningApplications`
    ///     taken on the main actor. Passed in so this struct stays Sendable.
    public func scan(
        includeSystemApps: Bool = true,
        computeSizes: Bool = true,
        runningApps: [RunningAppSnapshot] = []
    ) -> [AppBundleInfo] {
        var seen = Set<String>()
        var out: [AppBundleInfo] = []

        // 1. On-disk bundles from the standard folders.
        for folder in Self.searchFolders {
            guard fs.exists(folder),
                  let children = try? fs.contentsOfDirectory(folder) else { continue }
            for child in children where child.hasSuffix(".app") {
                let path = (folder as NSString).appendingPathComponent(child)
                let std = (path as NSString).standardizingPath
                guard !seen.contains(std) else { continue }
                seen.insert(std)

                if !includeSystemApps, AppBundleInfoLoader.isSystemPath(std) { continue }

                if var info = loader.load(at: std, computeSize: computeSizes) {
                    info = annotateRunning(info, runningApps: runningApps)
                    out.append(info)
                }
            }
        }

        // 2. Running apps that aren't in the standard folders (background
        //    agents, apps launched from DMGs, etc.).
        for running in runningApps {
            guard let bundlePath = running.bundlePath else { continue }
            let std = (bundlePath as NSString).standardizingPath
            guard !seen.contains(std) else { continue }
            guard std.hasSuffix(".app") else { continue }
            seen.insert(std)

            if var info = loader.load(at: std, computeSize: computeSizes) {
                info = annotateRunning(info, runningApps: runningApps)
                out.append(info)
            }
        }

        // Sort: user apps first, then by name.
        return out.sorted { a, b in
            let aRank = locationRank(a.location)
            let bRank = locationRank(b.location)
            if aRank != bRank { return aRank < bRank }
            return a.presentationName.localizedStandardCompare(b.presentationName) == .orderedAscending
        }
    }

    private func locationRank(_ location: AppLocation) -> Int {
        switch location {
        case .applications: return 0
        case .userApplications: return 1
        case .other: return 2
        case .systemApplications: return 3
        case .systemUtilities: return 4
        }
    }

    private func annotateRunning(_ info: AppBundleInfo, runningApps: [RunningAppSnapshot]) -> AppBundleInfo {
        var pids: [Int32] = []
        for running in runningApps {
            if let bid = running.bundleIdentifier, bid == info.bundleIdentifier, !bid.isEmpty {
                pids.append(running.processIdentifier)
            } else if let exec = running.executablePath,
                      exec.hasPrefix(info.path + "/") {
                pids.append(running.processIdentifier)
            }
        }
        guard !pids.isEmpty else { return info }
        return AppBundleInfo(
            path: info.path,
            bundleIdentifier: info.bundleIdentifier,
            name: info.name,
            displayName: info.displayName,
            executableName: info.executableName,
            shortVersion: info.shortVersion,
            buildVersion: info.buildVersion,
            minimumSystemVersion: info.minimumSystemVersion,
            location: info.location,
            isSystemApp: info.isSystemApp,
            isRunning: true,
            runningPIDs: pids,
            size: info.size
        )
    }
}

// MARK: - Running app snapshot

/// A Sendable snapshot of `NSRunningApplication`. Taken on the main actor and
/// passed into the scanner so the scanner itself stays off AppKit.
public struct RunningAppSnapshot: Sendable, Equatable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let bundlePath: String?
    public let executablePath: String?
    public let localizedName: String?
    public let isActive: Bool
    public let isHidden: Bool

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        bundlePath: String?,
        executablePath: String?,
        localizedName: String?,
        isActive: Bool,
        isHidden: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.localizedName = localizedName
        self.isActive = isActive
        self.isHidden = isHidden
    }
}

@MainActor
public extension RunningAppSnapshot {
    /// Snapshot every running application. Cheap enough to call once per scan.
    static func captureAll() -> [RunningAppSnapshot] {
        NSWorkspace.shared.runningApplications.map { app in
            RunningAppSnapshot(
                processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                bundlePath: app.bundleURL?.path,
                executablePath: app.executableURL?.path,
                localizedName: app.localizedName,
                isActive: app.isActive,
                isHidden: app.isHidden
            )
        }
    }
}

// MARK: - Quit helper

/// Sends a quit Apple Event to a running app, waits up to `timeout` seconds
/// for it to exit, then falls back to `SIGTERM`. Returns true when the
/// process is gone.
@MainActor
public enum AppQuitter {

    public static func quit(
        pids: [Int32],
        timeout: TimeInterval = 5.0
    ) async -> Bool {
        guard !pids.isEmpty else { return true }

        // 1. Polite quit via Apple Event.
        for pid in pids {
            sendQuitEvent(pid: pid)
        }

        // 2. Wait for exit.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ !isRunning(pid: $0) }) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // 3. Forceful SIGTERM for stragglers.
        for pid in pids where isRunning(pid: pid) {
            kill(pid, SIGTERM)
        }

        // 4. Brief second wait.
        let secondDeadline = Date().addingTimeInterval(2.0)
        while Date() < secondDeadline {
            if pids.allSatisfy({ !isRunning(pid: $0) }) { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return pids.allSatisfy { !isRunning(pid: $0) }
    }

    private static func sendQuitEvent(pid: Int32) {
        // The polite path is a `kAEQuitApplication` Apple Event: the target
        // gets to run its own shutdown handling and save state. `terminate()`
        // is only a fallback for a process we cannot address by event.
        if sendAppleEventQuit(pid: pid) { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    /// `typeKernelSubprocess` — the descriptor type that addresses a process by
    /// PID. Declared in `AEDataModel.h` as `'kpid'`, but the Carbon overlay does
    /// not expose the symbol to Swift, so the FourCharCode is spelled out here.
    ///
    /// `nonisolated` because building a descriptor touches no main-actor state,
    /// and pinning it to the main actor would make it untestable from a plain
    /// XCTestCase method.
    nonisolated static let kernelSubprocessDescType: DescType = 0x6B70_6964

    /// A descriptor addressing the process `pid`.
    ///
    /// Built from `Data` rather than a borrowed pointer so nothing can outlive
    /// the scope the bytes came from. Optional because Foundation's
    /// `init(descriptorType:data:)` is failable. Internal rather than private
    /// so tests can assert the encoding without any process ever receiving an
    /// event.
    nonisolated static func makeProcessDescriptor(pid: Int32) -> NSAppleEventDescriptor? {
        var pidValue = pid
        let pidData = Data(bytes: &pidValue, count: MemoryLayout<pid_t>.size)
        return NSAppleEventDescriptor(
            descriptorType: kernelSubprocessDescType,
            data: pidData
        )
    }

    /// A `kAEQuitApplication` event addressed to `pid`, ready to send.
    ///
    /// Internal rather than private for the same reason: constructing the event
    /// is pure, and asserting on it is the only way to test the quit path
    /// without actually terminating a running application.
    nonisolated static func makeQuitEvent(pid: Int32) -> NSAppleEventDescriptor {
        // Each field gets its own binding: the four `AE*` constants arrive as
        // plain integers, and asking the compiler to convert all of them inside
        // one call exceeds its expression-type-checking budget.
        let eventClass = AEEventClass(kCoreEventClass)
        let eventID = AEEventID(kAEQuitApplication)
        let returnID = AEReturnID(kAutoGenerateReturnID)
        let transactionID = AETransactionID(kAnyTransactionID)
        return NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: eventID,
            // `targetDescriptor` is nullable, so a descriptor Foundation refused
            // to build degrades to "address nobody" rather than a crash — the
            // send then fails and the `terminate()` fallback takes over.
            targetDescriptor: makeProcessDescriptor(pid: pid),
            returnID: returnID,
            transactionID: transactionID
        )
    }

    /// Build and deliver `kAEQuitApplication` to `pid`.
    ///
    /// Returns true only when the event was actually sent, so the caller can
    /// tell "quit requested" from "cannot talk to this process" and fall back
    /// accordingly. Delivery is fire-and-forget (`kAENoReply`) — `quit(pids:)`
    /// already polls for process exit with its own deadline, so waiting on a
    /// reply here would only add a second, redundant timeout.
    private static func sendAppleEventQuit(pid: Int32) -> Bool {
        let event = makeQuitEvent(pid: pid)
        let sendOptions = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAENoReply))
        do {
            // With `noReply` the returned descriptor is always nil — a throw is
            // the only failure signal there is.
            _ = try event.sendEvent(options: sendOptions, timeout: 0)
            return true
        } catch {
            return false
        }
    }

    private static func isRunning(pid: Int32) -> Bool {
        // kill(pid, 0) returns 0 if the process exists and we can signal it.
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}
