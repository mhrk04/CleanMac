//
//  PathDenylist.swift
//  CleanMac
//
//  The last line of defence. Every path a rule matches passes through here
//  before it becomes a ScanItem. Even a malicious or badly written user rule
//  cannot trick the engine into touching SIP-protected files, running
//  application bundles, or the user's home root itself.
//

import Foundation
import AppKit

public struct PathDenylist: Sendable {

    public init() {}

    /// Prefixes that are always denied, regardless of context.
    /// Includes SIP-protected system locations and irreplaceable user data.
    ///
    /// Every entry is written in the canonical form produced by
    /// `PathMatcher.standardize` (no leading `/private`, no trailing slash) and
    /// must be a prefix that is *actually applied* — the volume root and the
    /// `/Volumes` container live in `alwaysDeniedExact` instead, because
    /// denying every path beneath them would deny the whole machine.
    public static let alwaysDeniedPrefixes: [String] = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/var/db",
        "/var/folders/zz",         // system-wide temp for root processes
        "/Library/Apple",
        "/Library/Documentation",
        "/Library/Fonts",
        "/Applications/Utilities",
        "/cores",
        "/etc",
        "/var/db/dyld",
        "/var/db/SystemPolicy"
    ]

    /// Paths that are denied only when they exactly equal one of these values
    /// (subpaths are fine to clean). Canonical form, as above — so `/private/var`
    /// needs no entry of its own: it standardises to `/var`.
    public static let alwaysDeniedExact: [String] = [
        "/",
        NSHomeDirectory(),
        (NSHomeDirectory() as NSString).appendingPathComponent("Library"),
        "/Library",
        "/private",
        "/var",
        "/tmp",
        "/Volumes",
        "/Applications"
    ]

    /// Mandatory active-cache window, in hours.
    ///
    /// A file inside a `Caches` folder that was written within this window may
    /// still be open by a live process, so it is never offered for cleaning —
    /// regardless of what the rule asked for. This is what makes the denylist a
    /// safety *layer* rather than a restatement of the rule pack: §4 runs after
    /// matching precisely so a badly written or user-supplied rule cannot reach
    /// it.
    public static let activeCacheWindowHours = 24

    /// User directories we never bulk-delete even if a rule says so.
    public static let protectedUserDirectories: [String] = [
        "~/Desktop",
        "~/Documents",
        "~/Downloads",
        "~/Movies",
        "~/Music",
        "~/Pictures",
        "~/Public",
        "~/Sites",
        "~/Library/Mobile Documents",   // iCloud Drive
        "~/Library/Keychains",
        "~/Library/Accounts",
        "~/Library/IdentityServices",
        "~/Library/Application Support/AddressBook",
        "~/Library/Application Support/MobileSync",   // iOS backups: rule may allow specific children
        "~/Library/Application Support/iCloud",
        "~/Library/Application Support/SyncServices",
        "~/Library/Mail",              // the whole Mail store
        "~/Library/Messages"
    ].map { PathMatcher().expand($0) }

    // MARK: - Decision

    public enum Decision: Sendable, Equatable {
        case allowed
        case denied(reason: DenyReason)
    }

    public enum DenyReason: String, Sendable, Equatable {
        case systemProtected = "System-protected location"
        case runningApplication = "Application is currently running"
        case activeCache = "Cache is being actively written"
        case homeRoot = "Home directory root"
        case protectedUserDirectory = "Protected user directory"
        case volumeMountPoint = "Volume mount point"
        case ownBundle = "CleanMac's own bundle"
    }

    /// Decide whether the engine is allowed to consider `path` for cleaning.
    ///
    /// - Parameters:
    ///   - path: absolute, standardised path.
    ///   - metadata: metadata for the entry (used for active-cache detection).
    ///   - rule: the rule that produced this match (used for exempt checks).
    ///   - runningAppBundlePaths: pre-computed set of currently running app
    ///     bundle paths. Passed in so we don't hit NSWorkspace on every check.
    public func decide(
        path: String,
        metadata: FileMetadata?,
        rule: Rule,
        runningAppBundlePaths: Set<String>,
        ownBundlePath: String?
    ) -> Decision {
        let std = PathMatcher().standardize(path)

        // Own bundle.
        if let own = ownBundlePath, std == own || std.hasPrefix(own + "/") {
            return .denied(reason: .ownBundle)
        }

        // Home directory root.
        if Self.alwaysDeniedExact.contains(std) {
            return .denied(reason: std == NSHomeDirectory() ? .homeRoot : .systemProtected)
        }

        // Volume mount points: any path *directly* under /Volumes is a mount
        // point and is refused. Files inside a mounted volume are ordinary
        // paths and may be cleaned.
        if std.hasPrefix("/Volumes/") {
            let remainder = std.dropFirst("/Volumes/".count)
            if !remainder.contains("/") {
                return .denied(reason: .volumeMountPoint)
            }
        }

        // Prefix denylist. Only reject if the *matched* path is inside these
        // trees AND the rule did not explicitly ask for a path under them.
        // We allow /Library/Caches (system caches rule) and /Library/Logs
        // (DiagnosticReports rule) explicitly by checking rule id allowlist.
        for prefix in Self.alwaysDeniedPrefixes {
            if std == prefix || std.hasPrefix(prefix + "/") {
                if !Self.ruleExemptedFromPrefix(ruleID: rule.id, prefix: prefix) {
                    return .denied(reason: .systemProtected)
                }
            }
        }

        // Protected user directories — same allowlist approach.
        for protected in Self.protectedUserDirectories {
            if std == protected || std.hasPrefix(protected + "/") {
                if !Self.ruleExemptedFromProtected(ruleID: rule.id, protected: protected) {
                    return .denied(reason: .protectedUserDirectory)
                }
            }
        }

        // Running application bundles: refuse anything inside them.
        for bundlePath in runningAppBundlePaths {
            if std == bundlePath || std.hasPrefix(bundlePath + "/") {
                return .denied(reason: .runningApplication)
            }
        }

        // Active caches. Two independent triggers, and the wider window wins:
        //
        // 1. The rule declared `modifiedWithinHours` (spec §2 expresses this as
        //    the "~/Library/Caches/**/modifiedWithin:24h" exclude).
        // 2. Unconditionally, any entry inside a `Caches` folder touched within
        //    `activeCacheWindowHours`.
        //
        // Trigger 2 cannot be opted out of. Without it the protection depends on
        // every cache rule remembering to set the window, and several legitimately
        // do not — a pack edit or a user-supplied rule would then be free to trash
        // a file a running process is mid-write on.
        if let meta = metadata, let mtime = meta.modificationDate {
            let ruleWindow = rule.modifiedWithinHours ?? 0
            let cacheWindow = Self.isInsideCachesFolder(std) ? Self.activeCacheWindowHours : 0
            let hours = max(ruleWindow, cacheWindow)
            if hours > 0 {
                let cutoff = Date().addingTimeInterval(-TimeInterval(hours) * 3600)
                if mtime > cutoff {
                    return .denied(reason: .activeCache)
                }
            }
        }

        return .allowed
    }

    /// True when any component of the standardised path is exactly `Caches`.
    ///
    /// Component-wise rather than a substring test so that a file merely named
    /// `Caches-old.zip` does not acquire the protection, and so that every real
    /// cache location is covered by one rule: `~/Library/Caches`,
    /// `/Library/Caches`, and the per-app copies under
    /// `~/Library/Containers/<id>/Data/Library/Caches`.
    static func isInsideCachesFolder(_ std: String) -> Bool {
        std.split(separator: "/").contains("Caches")
    }

    // MARK: - Allowlists

    /// Rules explicitly allowed to touch paths under normally-denied prefixes.
    /// The keys are prefix paths; the values are rule ids allowed under them.
    private static let prefixAllowlist: [String: Set<String>] = [
        "/Library": [
            "system-caches",
            "app-diagnostic-reports",
            // Uninstaller rules that legitimately live under /Library:
            "app-support", "preferences", "caches", "logs",
            "launch-agents-system", "launch-daemons-system",
            "privileged-helper", "receipts",
            "internet-plugins", "preference-panes"
        ],
        "/var": [
            "quicklook-cache",
            "font-cache"
        ]
    ]

    private static func ruleExemptedFromPrefix(ruleID: String, prefix: String) -> Bool {
        // Find the longest prefix key that is a prefix of `prefix` or vice versa.
        for (key, allowed) in prefixAllowlist {
            if prefix == key || prefix.hasPrefix(key + "/") || key.hasPrefix(prefix + "/") {
                if allowed.contains(ruleID) { return true }
            }
        }
        return false
    }

    /// Rules allowed inside protected user directories.
    private static let protectedAllowlist: [String: Set<String>] = [:]

    private static func ruleExemptedFromProtected(ruleID: String, protected: String) -> Bool {
        protectedAllowlist[protected]?.contains(ruleID) ?? false
    }

    // MARK: - Convenience

    /// Snapshot of every running application's bundle path. Called once per
    /// scan and passed to `decide`.
    @MainActor
    public static func currentRunningAppBundlePaths() -> Set<String> {
        var out = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let url = app.bundleURL {
                out.insert(url.path)
            }
            // Also treat the executable's directory as protected so helper
            // processes inside a bundle are covered.
            if let exec = app.executableURL {
                out.insert(exec.deletingLastPathComponent().path)
            }
        }
        return out
    }
}
