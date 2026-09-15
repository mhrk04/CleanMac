//
//  ScanProgress.swift
//  CleanMac
//
//  Progress events emitted by the ScannerEngine while a scan is running.
//  The UI subscribes via AsyncStream and animates live counters.
//

import Foundation

public struct ScanProgress: Sendable, Equatable {
    /// Rule currently being evaluated (nil during setup / teardown).
    public let ruleID: String?
    /// Human-readable name of the current rule.
    public let ruleName: String?
    /// Path being examined right now (for the "currently scanning…" label).
    public let currentPath: String?
    /// Cumulative items found across the whole scan so far.
    public let itemsFound: Int
    /// Cumulative bytes found across the whole scan so far.
    public let bytesFound: Int64
    /// Fraction complete, 0.0 ... 1.0. Estimated from rules processed /
    /// total rules; individual rules can vary wildly in cost.
    public let fractionComplete: Double
    /// True once the engine has finished (successfully or with an error).
    public let isFinished: Bool
    /// Human-readable status message, e.g. "Scanning caches…".
    public let statusMessage: String?

    public init(
        ruleID: String? = nil,
        ruleName: String? = nil,
        currentPath: String? = nil,
        itemsFound: Int = 0,
        bytesFound: Int64 = 0,
        fractionComplete: Double = 0,
        isFinished: Bool = false,
        statusMessage: String? = nil
    ) {
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.currentPath = currentPath
        self.itemsFound = itemsFound
        self.bytesFound = bytesFound
        self.fractionComplete = min(max(fractionComplete, 0), 1)
        self.isFinished = isFinished
        self.statusMessage = statusMessage
    }

    public static let idle = ScanProgress()
    public static let finished = ScanProgress(fractionComplete: 1, isFinished: true)
}

// MARK: - Clean progress (parallel type used by CleanerService)

public struct CleanProgress: Sendable, Equatable {
    public let itemsTotal: Int
    public let itemsProcessed: Int
    public let bytesFreed: Int64
    public let currentPath: String?
    public let isFinished: Bool
    public let failureCount: Int

    public init(
        itemsTotal: Int,
        itemsProcessed: Int,
        bytesFreed: Int64,
        currentPath: String? = nil,
        isFinished: Bool = false,
        failureCount: Int = 0
    ) {
        self.itemsTotal = itemsTotal
        self.itemsProcessed = itemsProcessed
        self.bytesFreed = bytesFreed
        self.currentPath = currentPath
        self.isFinished = isFinished
        self.failureCount = failureCount
    }

    public var fractionComplete: Double {
        guard itemsTotal > 0 else { return isFinished ? 1 : 0 }
        return min(max(Double(itemsProcessed) / Double(itemsTotal), 0), 1)
    }

    public static let idle = CleanProgress(itemsTotal: 0, itemsProcessed: 0, bytesFreed: 0)
}
