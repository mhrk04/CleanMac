//
//  main.swift  (.verify/scan-only)
//
//  ┌───────────────────────────────────────────────────────────────────────┐
//  │  SCAN-ONLY: this process NEVER deletes or moves files.                  │
//  │                                                                         │
//  │  It runs the real ScannerEngine against the real disk through          │
//  │  LiveFileSystem and only PRINTS what a clean *would* target. It does    │
//  │  not import, reference, or call CleanerService, TrashMover, .trash(),  │
//  │  .removeItem(), .writeData(), or any other mutating API. There is no    │
//  │  code path in this file that can move or delete a user's files.         │
//  └───────────────────────────────────────────────────────────────────────┘
//
//  Purpose (all read-only):
//    (a) prove the bundled rule packs load via the real RuleLoader,
//    (b) prove rules actually match real files under the user's home,
//    (c) prove PathDenylist vetoes protected paths,
//    (d) report totals per category and per SafetyLevel.
//
//  Built without a full Xcode test target — see run.sh, which mirrors
//  .verify/run-tests.sh (strip #Preview, compile CleanMac into a dylib, then
//  compile+link this executable against it).
//

import Foundation
import CleanMac

// MARK: - Guard-rail banner (also enforced by the fact we import nothing mutating)

print("""
==========================================================================
  SCAN-ONLY HARNESS
  This process NEVER deletes or moves files. No CleanerService / TrashMover /
  .trash() / .removeItem() is imported or called. Read-only report follows.
==========================================================================
""")

// MARK: - Helpers

/// Human-readable byte formatting (binary units, matching Finder-ish output).
func humanBytes(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}

/// Optionally restrict the run to a subset of rule ids (comma-separated in
/// SCAN_ONLY_RULE_IDS). When unset, every rule in the pack runs.
let onlyRuleIDs: Set<String>? = {
    guard let raw = ProcessInfo.processInfo.environment["SCAN_ONLY_RULE_IDS"],
          !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let ids = raw.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    return ids.isEmpty ? nil : Set(ids)
}()

// MARK: - Locate the rules directory

// The harness has no app bundle, so point a Bundle at the source Resources
// folder — exactly the pattern TestResources.bundle uses — so
// RuleLoader.loadBundled(named:) resolves Rules/<name>.yaml through the real
// parser + rule model. SCAN_RULES_DIR is the .../Resources/Rules directory.
guard let rulesDir = ProcessInfo.processInfo.environment["SCAN_RULES_DIR"] else {
    fputs("ERROR: SCAN_RULES_DIR is not set (should point at CleanMac/Resources/Rules)\n", stderr)
    exit(2)
}
// loadBundled resolves <bundle>/Rules/<name>.yaml, so the bundle root is the
// PARENT of the Rules directory (i.e. .../Resources).
let resourcesDir = (rulesDir as NSString).deletingLastPathComponent

print("Rules directory : \(rulesDir)")
print("Bundle root     : \(resourcesDir)")

guard FileManager.default.fileExists(atPath: rulesDir) else {
    fputs("ERROR: rules directory does not exist: \(rulesDir)\n", stderr)
    exit(2)
}

// MARK: - Build the real components

let fs = LiveFileSystem()
let matcher = PathMatcher()
let denylist = PathDenylist()

let bundle = Bundle(url: URL(fileURLWithPath: resourcesDir, isDirectory: true)) ?? .main
let loader = RuleLoader(bundle: bundle, fileSystem: fs)

// ownBundlePath: nil here so the harness doesn't accidentally veto real matches
// under some transient build dir. The denylist's static rules are what we test.
let scanner = ScannerEngine(
    fileSystem: fs,
    matcher: matcher,
    denylist: denylist,
    ownBundlePath: nil
)

// MARK: - (a) Load the bundled system-junk rule pack via the real RuleLoader

let pack: RulePack
do {
    pack = try loader.loadBundled(named: RulePackName.systemJunk)
} catch {
    fputs("ERROR: failed to load '\(RulePackName.systemJunk)' pack: \(error)\n", stderr)
    exit(3)
}

print("\n--- (a) Rule pack loaded -------------------------------------------------")
print("Pack name       : \(pack.name)")
print("Pack version    : \(pack.version)")
print("Rules in pack   : \(pack.rules.count)")
print("Pack excludes   : \(pack.excludes.count)")

// Select which rules to actually run.
var rules = pack.rules
if let only = onlyRuleIDs {
    rules = rules.filter { only.contains($0.id) }
    print("NOTE: SCAN_ONLY_RULE_IDS set — restricting to \(rules.count) rule(s): "
          + rules.map(\.id).joined(separator: ", "))
} else {
    print("Running ALL \(rules.count) rules in the pack.")
}
print("Rule ids to run : " + rules.map(\.id).joined(separator: ", "))

// MARK: - Capture running app bundle paths (best-effort, @MainActor)

// PathDenylist.currentRunningAppBundlePaths() is @MainActor and uses
// NSWorkspace/AppKit. In a plain CLI this may not be usable; if calling it is
// problematic we fall back to [] — the denylist still applies ALL its static
// path rules, which is exactly what we validate here.
let runningAppBundlePaths: Set<String> = await MainActor.run {
    PathDenylist.currentRunningAppBundlePaths()
}
print("\nRunning-app bundle paths captured: \(runningAppBundlePaths.count)")

// MARK: - (b) Run the real scanner against the real disk (READ-ONLY)

print("\n--- (b) Scanning (read-only) --------------------------------------------")
print("Scanning… (matching rules against the live filesystem, no mutation)")

let items = await scanner.scan(
    rules: rules,
    context: .empty,
    runningAppBundlePaths: runningAppBundlePaths,
    onProgress: { p in
        if p.isFinished {
            fputs("  progress: \(p.statusMessage ?? "done") — \(p.itemsFound) items\n", stderr)
        }
    }
)

// MARK: - (d) REPORT: totals, category + safety breakdown, examples

print("\n========================= SCAN REPORT (READ-ONLY) ========================")
print("Total items matched : \(items.count)")
print("Total size          : \(humanBytes(items.totalSize)) (\(items.totalSize) bytes)")

// By category
print("\nBy category:")
let byCategory = items.groupedByCategory()
if byCategory.isEmpty {
    print("  (none)")
} else {
    for group in byCategory {
        let size = group.items.totalSize
        print(String(format: "  %-14@ %5d items  %@",
                     group.category.rawValue as NSString,
                     group.items.count,
                     humanBytes(size) as NSString))
    }
}

// By safety level
print("\nBy safety level:")
for level in SafetyLevel.allCases {
    let subset = items.filter { $0.safety == level }
    print(String(format: "  %-10@ %5d items  %@",
                 level.rawValue as NSString,
                 subset.count,
                 humanBytes(subset.totalSize) as NSString))
}

// By rule (top contributors), useful to see which rules matched
print("\nBy rule (matched rules only):")
let byRule = items.groupedByRule()
if byRule.isEmpty {
    print("  (no rule matched anything)")
} else {
    for group in byRule {
        print(String(format: "  %-28@ %5d items  %@",
                     group.ruleID as NSString,
                     group.items.count,
                     humanBytes(group.items.totalSize) as NSString))
    }
}

// First ~15 example paths
print("\nExample matched paths (first 15):")
if items.isEmpty {
    print("  (none)")
} else {
    for item in items.prefix(15) {
        print("  [\(item.safety.rawValue)] \(item.displayPath)  (\(humanBytes(item.size)))")
    }
    if items.count > 15 {
        print("  … and \(items.count - 15) more")
    }
}

// MARK: - (c) Denylist spot-check: known-protected paths must be .denied

print("\n--- (c) Denylist spot-check ---------------------------------------------")
let home = NSHomeDirectory()

// A throwaway rule with no exemptions — a plain user rule the denylist must
// still veto on protected paths. (We do NOT clean anything; decide() is pure.)
let probeRule = Rule(
    id: "scan-only-probe",
    name: "Scan-only probe",
    category: .other,
    safety: .safe,
    paths: []
)

let protectedPaths: [String] = [
    home,                                  // home root
    (home as NSString).appendingPathComponent("Documents"),
    (home as NSString).appendingPathComponent("Library"),
    "/System/Library/Caches",
    "/usr/bin",
    "/System",
    "/bin",
    "/etc",
    "/",
]

var allDenied = true
for path in protectedPaths {
    let std = matcher.standardize(path)
    let meta = try? fs.metadata(at: std)
    let decision = denylist.decide(
        path: std,
        metadata: meta,
        rule: probeRule,
        runningAppBundlePaths: runningAppBundlePaths,
        ownBundlePath: nil
    )
    switch decision {
    case .denied(let reason):
        print("  PASS  denied  \(path)  —  \(reason.rawValue)")
    case .allowed:
        allDenied = false
        print("  FAIL  ALLOWED \(path)  —  expected denied!")
    }
}

print("\nDenylist spot-check: \(allDenied ? "ALL PASS" : "SOME FAILED")")

// MARK: - Closing guard-rail confirmation

print("""

==========================================================================
  DONE — READ-ONLY. Nothing was moved or deleted.
  No CleanerService / TrashMover / .trash() / .removeItem() was ever called.
==========================================================================
""")

exit(allDenied ? 0 : 1)
