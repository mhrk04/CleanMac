//
//  FullDiskAccessProbe.swift
//  CleanMac
//
//  macOS has no direct "isFullDiskAccessGranted" API. The conventional probe
//  is to attempt to read a TCC-protected file and inspect the failure:
//
//    - If reading succeeds OR fails with a non-permission error, FDA is
//      granted.
//    - If reading fails with EPERM (Operation not permitted), FDA is missing.
//
//  We probe the user's TCC database, which is protected in exactly the way
//  we care about.
//

import Foundation
// `kAXTrustedCheckOptionPrompt` is an `extern CFStringRef`, i.e. shared mutable
// state, so the concurrency checker refuses to let a `Sendable` type read it.
// The symbol is a compile-time constant in ApplicationServices; `@preconcurrency`
// is the sanctioned way to opt this one reference out of the check.
@preconcurrency import ApplicationServices

public struct FullDiskAccessProbe: Sendable {

    public init() {}

    /// Paths that require Full Disk Access to read. Any one succeeding is
    /// enough to conclude FDA is granted.
    public static let probePaths: [String] = [
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Safari/CloudTabs.db"),
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Mail"),
        "/Library/Application Support/com.apple.TCC/TCC.db"
    ]

    /// Return true if FDA appears to be granted.
    public func isGranted() -> Bool {
        for path in Self.probePaths {
            switch probe(path: path) {
            case .readable, .existsButUnreadableForOtherReason:
                return true
            case .permissionDenied, .doesNotExist:
                continue
            }
        }
        return false
    }

    public enum ProbeResult: Sendable, Equatable {
        case readable
        case existsButUnreadableForOtherReason
        case permissionDenied
        case doesNotExist
    }

    /// Ask the kernel whether *this process* may read `path`.
    ///
    /// Deliberately bypasses the `FileSystem` protocol and uses `FileManager`
    /// plus raw POSIX `open()`/`errno`. The thing being measured is the real
    /// TCC decision for this process, so routing it through an injected double
    /// would report the double's permissions instead of the user's — the probe
    /// would be measuring nothing. This is the one dependency in the app that
    /// cannot be mocked, and it is why `PermissionCenter` is exercised by
    /// observing behaviour rather than by unit test.
    public func probe(path: String) -> ProbeResult {
        // First, existence check via a stat that does not require read
        // permission on the file itself.
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if attrs == nil {
            // Could be missing OR could be permission denied at the parent
            // directory. Try opening the file directly to disambiguate.
            let fd = open(path, O_RDONLY | O_NONBLOCK)
            if fd >= 0 {
                close(fd)
                return .readable
            }
            let errnoCode = errno
            if errnoCode == EPERM || errnoCode == EACCES {
                return .permissionDenied
            }
            if errnoCode == ENOENT {
                return .doesNotExist
            }
            return .existsButUnreadableForOtherReason
        }

        // Attributes readable — attempt an actual open to confirm.
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd >= 0 {
            close(fd)
            return .readable
        }
        let errnoCode = errno
        if errnoCode == EPERM || errnoCode == EACCES {
            // Attributes worked but open failed — this is the TCC signature
            // for "we can see the file exists but you don't have FDA".
            return .permissionDenied
        }
        return .existsButUnreadableForOtherReason
    }
}

// MARK: - Accessibility permission probe

public struct AccessibilityProbe: Sendable {
    public init() {}

    /// Whether the app has been granted Accessibility permission. Uses the
    /// ApplicationServices API which is the canonical way to check.
    public func isGranted(prompt: Bool = false) -> Bool {
        // AXIsProcessTrustedWithOptions is exposed through ApplicationServices.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(options)
    }
}
