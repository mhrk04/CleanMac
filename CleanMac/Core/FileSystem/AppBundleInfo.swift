//
//  AppBundleInfo.swift
//  CleanMac
//
//  Reads the Info.plist of an installed .app bundle and exposes the fields
//  the Uninstaller module needs. Also determines whether the app is currently
//  running and provides its icon.
//

import Foundation
import AppKit

public struct AppBundleInfo: Identifiable, Hashable, Sendable {
    public var id: String { path }

    /// Absolute path to the .app bundle.
    public let path: String
    /// CFBundleIdentifier, or "unknown.<basename>" if the plist is missing.
    public let bundleIdentifier: String
    /// CFBundleName (falling back to CFBundleDisplayName, then filename).
    public let name: String
    /// CFBundleDisplayName, when different from CFBundleName.
    public let displayName: String?
    /// CFBundleExecutable.
    public let executableName: String
    /// CFBundleShortVersionString (e.g. "15.2.1").
    public let shortVersion: String
    /// CFBundleVersion (build number).
    public let buildVersion: String
    /// LSMinimumSystemVersion.
    public let minimumSystemVersion: String?
    /// Where the app lives: /Applications, ~/Applications, /System/Applications,
    /// /System/Applications/Utilities, or a custom path.
    public let location: AppLocation
    /// Whether the bundle is under a SIP-protected system path (read-only).
    public let isSystemApp: Bool
    /// Whether the app is currently running (any process with this bundle id).
    public let isRunning: Bool
    /// PIDs of running instances.
    public let runningPIDs: [Int32]
    /// Total allocated size of the bundle, in bytes. Computed lazily.
    public let size: Int64

    public init(
        path: String,
        bundleIdentifier: String,
        name: String,
        displayName: String?,
        executableName: String,
        shortVersion: String,
        buildVersion: String,
        minimumSystemVersion: String?,
        location: AppLocation,
        isSystemApp: Bool,
        isRunning: Bool,
        runningPIDs: [Int32],
        size: Int64
    ) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.displayName = displayName
        self.executableName = executableName
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.minimumSystemVersion = minimumSystemVersion
        self.location = location
        self.isSystemApp = isSystemApp
        self.isRunning = isRunning
        self.runningPIDs = runningPIDs
        self.size = size
    }

    /// The name shown in the UI. Prefers displayName over name over filename.
    public var presentationName: String {
        if let d = displayName, !d.isEmpty, d != name { return d }
        if !name.isEmpty { return name }
        return (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    /// Icon loaded from AppKit. Not stored on the struct because NSImage is
    /// not Sendable; call this from the main actor when rendering.
    @MainActor
    public func icon() -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }
}

public enum AppLocation: String, Sendable, CaseIterable, Hashable {
    case applications = "/Applications"
    case userApplications = "~/Applications"
    case systemApplications = "/System/Applications"
    case systemUtilities = "/System/Applications/Utilities"
    case other

    /// Human-readable name of the location, for section headers in the
    /// Uninstaller list. Not to be confused with `rawValue`, which is the real
    /// on-disk directory and must never be translated.
    public var label: String {
        switch self {
        case .applications: return L10n.string("Applications")
        case .userApplications: return L10n.string("My Applications")
        case .systemApplications: return L10n.string("System Applications")
        case .systemUtilities: return L10n.string("Utilities")
        case .other: return L10n.string("Other")
        }
    }
}

// MARK: - Loader

public struct AppBundleInfoLoader: Sendable {

    private let fs: FileSystem
    private let sizeCalculator: SizeCalculator

    public init(fileSystem: FileSystem) {
        self.fs = fileSystem
        self.sizeCalculator = SizeCalculator(fileSystem: fileSystem)
    }

    /// Load the bundle at `path`. Returns nil if the path is not a readable
    /// .app bundle (missing Info.plist, permission denied, etc.).
    public func load(at path: String, computeSize: Bool = true) -> AppBundleInfo? {
        let infoPlist = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOfFile: infoPlist) as? [String: Any] else {
            // Fall back to a minimal record so the UI can still show the row.
            return AppBundleInfo(
                path: path,
                bundleIdentifier: "unknown." + ((path as NSString).lastPathComponent),
                name: (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""),
                displayName: nil,
                executableName: "",
                shortVersion: "",
                buildVersion: "",
                minimumSystemVersion: nil,
                location: Self.classify(path: path),
                isSystemApp: Self.isSystemPath(path),
                isRunning: false,
                runningPIDs: [],
                size: computeSize ? sizeCalculator.size(of: path) : 0
            )
        }

        let bundleId = (plist["CFBundleIdentifier"] as? String) ?? ""
        let name = (plist["CFBundleName"] as? String) ?? ""
        let displayName = plist["CFBundleDisplayName"] as? String
        let exec = (plist["CFBundleExecutable"] as? String) ?? ""
        let shortVersion = (plist["CFBundleShortVersionString"] as? String) ?? ""
        let buildVersion = (plist["CFBundleVersion"] as? String) ?? ""
        let minSys = plist["LSMinimumSystemVersion"] as? String

        let (running, pids) = Self.runningProcesses(bundleId: bundleId, exec: exec)

        return AppBundleInfo(
            path: path,
            bundleIdentifier: bundleId,
            name: name,
            displayName: displayName,
            executableName: exec,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            minimumSystemVersion: minSys,
            location: Self.classify(path: path),
            isSystemApp: Self.isSystemPath(path),
            isRunning: running,
            runningPIDs: pids,
            size: computeSize ? sizeCalculator.size(of: path) : 0
        )
    }

    // MARK: - Classification

    public static func classify(path: String) -> AppLocation {
        let std = (path as NSString).standardizingPath
        if std.hasPrefix("/System/Applications/Utilities/") { return .systemUtilities }
        if std.hasPrefix("/System/Applications/") { return .systemApplications }
        if std.hasPrefix("/Applications/") { return .applications }
        if std.hasPrefix(NSHomeDirectory() + "/Applications/") { return .userApplications }
        return .other
    }

    public static func isSystemPath(_ path: String) -> Bool {
        let std = (path as NSString).standardizingPath
        return std.hasPrefix("/System/") || std.hasPrefix("/usr/") || std.hasPrefix("/bin/")
    }

    // MARK: - Running processes

    /// Ask NSRunningApplication about every process with this bundle id.
    /// Falls back to matching executable name for daemons that don't declare
    /// a bundle id.
    private static func runningProcesses(bundleId: String, exec: String) -> (Bool, [Int32]) {
        var pids: [Int32] = []
        if !bundleId.isEmpty {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            pids.append(contentsOf: apps.map { $0.processIdentifier })
        }
        // Include frontmost + background apps that share an executable name —
        // catches helper processes launched from inside the .app bundle.
        if pids.isEmpty, !exec.isEmpty {
            let all = NSWorkspace.shared.runningApplications
            for app in all where app.executableURL?.lastPathComponent == exec {
                pids.append(app.processIdentifier)
            }
        }
        return (!pids.isEmpty, pids)
    }
}
