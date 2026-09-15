//
//  SizeCalculator.swift
//  CleanMac
//
//  Recursive size computation with cycle detection.
//

import Foundation

public struct SizeCalculator: Sendable {

    private let fs: FileSystem

    public init(fileSystem: FileSystem) {
        self.fs = fileSystem
    }

    /// Sum of allocated bytes for `path` and, if it is a directory, all of its
    /// descendants. Symbolic links are counted once as their own entry and
    /// never followed, which prevents cycles.
    ///
    /// Any read errors on descendants are silently skipped — a partially
    /// readable directory still reports the size of the part we could see.
    public func size(of path: String) -> Int64 {
        guard let rootMeta = try? fs.metadata(at: path) else { return 0 }

        if !rootMeta.isDirectory {
            return rootMeta.allocatedSize > 0 ? rootMeta.allocatedSize : rootMeta.contentSize
        }

        var total: Int64 = 0
        // Cycle guard. Keys are the exact path strings built while descending,
        // which are unique per node because symbolic links are never followed.
        // Running them through `NSString.standardizingPath` instead would be
        // actively harmful: it silently truncates at PATH_MAX (1024 bytes), so
        // two distinct deep directories collapse onto one key and real data is
        // skipped without any error.
        var visited = Set<String>()
        visited.insert(path)

        // Manual stack rather than recursion — deeply nested directories would
        // otherwise blow the Swift stack.
        var stack: [String] = [path]
        while let dir = stack.popLast() {
            guard let children = try? fs.contentsOfDirectory(dir) else { continue }
            for child in children {
                let childPath = (dir as NSString).appendingPathComponent(child)
                if visited.contains(childPath) { continue }
                visited.insert(childPath)

                guard let meta = try? fs.metadata(at: childPath) else { continue }
                if meta.isSymbolicLink {
                    total += meta.allocatedSize > 0 ? meta.allocatedSize : 64
                    continue
                }
                if meta.isDirectory {
                    stack.append(childPath)
                } else {
                    total += meta.allocatedSize > 0 ? meta.allocatedSize : meta.contentSize
                }
            }
        }
        return total
    }

    /// Batch version: returns sizes keyed by input path.
    public func sizes(of paths: [String]) -> [String: Int64] {
        var out: [String: Int64] = [:]
        out.reserveCapacity(paths.count)
        for p in paths { out[p] = size(of: p) }
        return out
    }
}

// MARK: - Byte formatting

public enum ByteCount {
    /// Format bytes with adaptive units (B, KB, MB, GB, TB). Uses binary units
    /// (1 KB = 1024 B) which matches what Finder displays for file sizes on
    /// macOS 11+ when "Calculate all sizes in decimal" is off.
    public static func format(_ bytes: Int64, includeUnits: Bool = true) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.includesUnit = includeUnits
        f.includesActualByteCount = false
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }

    /// Compact format for tight UI (e.g. sidebar badges): "1.2 GB" not "1.20 GB".
    public static func compact(_ bytes: Int64) -> String {
        let abs = bytes < 0 ? -bytes : bytes
        let units: [(Int64, String)] = [
            (1 << 40, "TB"),
            (1 << 30, "GB"),
            (1 << 20, "MB"),
            (1 << 10, "KB")
        ]
        for (divisor, unit) in units where abs >= divisor {
            let value = Double(bytes) / Double(divisor)
            let str = value >= 100
                ? String(format: "%.0f", value)
                : (value >= 10 ? String(format: "%.1f", value) : String(format: "%.2f", value))
            return "\(str) \(unit)"
        }
        return "\(bytes) B"
    }
}
