# Architecture

A deeper dive into the two pieces the rest of the app is built on: the **rule
pack format** and the **scanner engine**. The design goal throughout is that
cleaning behaviour is *data*, and that every destructive decision passes through
one narrow, testable safety gate.

```
YAML rule packs ──► RuleLoader ──► [Rule]
                                      │
                        ScannerEngine (actor)
                          │  PathMatcher   glob → regex, ~ / {var} expansion
                          │  FileSystem    enumeration + metadata
                          │  PathDenylist  ◄── every match is gated here
                          ▼
                       [ScanItem] ──► ViewModels ──► SwiftUI
                                      │
                          CleanerService ──► TrashMover ──► FileManager.trashItem
                                      │
                          CleanManifest ──► HistoryStore (JSON, undo)
```

---

## Rule packs

Cleaning logic lives in bundled YAML under `CleanMac/Resources/Rules/` so it can
be updated without shipping a new binary. Three packs ship:

| Pack | Stem | Purpose |
| --- | --- | --- |
| System junk | `system-junk` | caches, logs, Xcode data, trash bins, languages, snapshots |
| Uninstaller leftovers | `uninstaller-leftovers` | `{bundleId}` / `{appName}` templates |
| Large & Old defaults | `large-files-defaults` | search roots, skip paths, presets |

A pack decodes to `RulePack` (`name`, `version`, `rules`, `excludes`,
`defaults`); each entry to `Rule`.

### Rule fields

| Field | Meaning |
| --- | --- |
| `id` | Stable identifier. User packs override bundled rules **by id**. |
| `name`, `description` | User-facing copy. |
| `category` | One of the 16 `RuleCategory` constants; drives grouping and the sidebar icon. |
| `safety` | `safe` \| `review` \| `dangerous` → `isPreselected`. |
| `paths` | Globs to match. |
| `excludes` | Globs subtracted from `paths`. Pack-level `excludes` merge into every rule. |
| `strategy` | Optional specialised handler instead of plain globbing. |
| `modifiedWithinHours` | Skip entries touched more recently than this. |
| `keepLanguages` | For `strategy: languageFilter` — languages never to remove. |

A rule is actionable if it has `paths` **or** a `strategy`. Volume trashes, Time
Machine snapshots and broken login items are discovered at runtime, so they
legitimately ship with no paths at all; `Rule.isSpecialized` encodes that.

`RuleCategory` is a `RawRepresentable` struct rather than a closed enum, so a
user pack may introduce a category the binary has never seen. That is safe
because both renderers have a fallback: `symbolName` returns
`questionmark.folder` and `displayName` returns the capitalised raw value.
Decoding an unknown category therefore degrades to a generic-looking section
instead of failing to load the pack.

### Safety levels

`safe` items are pre-checked. `review` items are shown with a warning badge and
start unchecked — language files and iOS backups live here. `dangerous` items
(Maven repositories, Docker Desktop data, local snapshots) are hidden unless the
user enables them in Settings. Smart Scan's **Clean All** only ever takes the
union of `safe` items.

### Strategies

Four strategies bypass globbing because the target cannot be described by one:

- **`languageFilter`** — walks `.lproj` bundles and keeps `keepLanguages`.
  The token `active` resolves *at scan time* to the user's `AppleLanguages`.
  An absent or empty list means `[active]`, never `[]`: a rule that forgets the
  key must not become a rule that deletes every language the user reads.
  Comparison is case-insensitive and prefix-tolerant, because on-disk bundles
  are capitalised (`zh-Hans.lproj`) while `AppleLanguages` are not — a
  case-sensitive compare would offer the user's own language up for deletion.
  `Base` and `Root` are always kept; they hold the language-neutral resources
  every locale falls back to.
- **`trashBins`** — `~/.Trash` plus `/.Trashes/<uid>` on every mounted volume.
- **`brokenLoginItems`** — LaunchAgents/Daemons plists whose `Program` or
  `ProgramArguments[0]` points at a file that no longer exists.
- **`tmutilSnapshots`** — APFS local snapshots, reported read-only. Removing
  them needs root, so the app surfaces the exact `tmutil` command instead of
  pretending it can do the job.

### User overrides

`~/Library/Application Support/CleanMac/Rules/*.yaml` is merged with the bundled
pack of the same name; conflicts resolve by preferring the user rule with the
same `id`. Because `PathDenylist` runs *after* matching, a hostile or careless
user rule still cannot reach a protected path.

---

## Scanner engine

`ScannerEngine` is an `actor`. Its entry point streams progress while it works:

```swift
func scan(rules: [Rule], progress: AsyncStream<ScanProgress>.Continuation,
          concurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    async throws -> [ScanItem]
```

- **Parallelism.** Rules are walked in a `TaskGroup` bounded to half the active
  processor count (minimum 2). Halving rather than saturating keeps the UI
  responsive during a scan, which matters more than raw throughput here — the
  bottleneck is disk, not CPU.
- **Progress.** `ScanProgress(ruleId:, itemsFound:, bytesFound:, currentPath:)`
  is emitted on an `AsyncStream`, so views render live counts instead of waiting
  for the whole scan.
- **Cancellation.** Cooperative. `FileWalker` calls `try Task.checkCancellation()`
  inside the enumeration callback, which unwinds the *entire* walk rather than
  pruning one subtree, and the root loop checks `Task.isCancelled` before each
  root.

### Enumeration

`FileSystem.enumerate(root:includeHidden:followSymlinks:_:)` is the only place
the app walks a directory tree. Two invariants are enforced there, before the
visitor's return value is even consulted:

- **Packages are opaque.** `.skipsPackageDescendants` only bites when
  `FileManager` performs the recursion itself, and this method drives its own
  stack one level at a time (so a visitor can prune dynamically). Packages are
  therefore pruned explicitly using `.isPackageKey` — a junk rule sees one
  `.app`, not the thousands of files inside it.
- **Symlinks are never resolved.** Following one could carry the walk outside
  the scanned root and surface paths the denylist never agreed to consider, so
  `followSymlinks` is accepted for API symmetry and deliberately not acted on.

Resource keys are requested up front — `.totalFileAllocatedSizeKey`,
`.contentAccessDateKey`, `.isRegularFileKey` and friends — so each entry costs
one syscall rather than one per attribute.

`FileWalker` layers the caller-facing filters on top: skip patterns, bundle
extensions, minimum size, age, allowed extensions, and a result cap. Age uses
`contentAccessDate` ("last opened") with `modificationDate` as fallback, and an
entry with *no* timestamps is skipped rather than assumed old. Size, age and
extension filters apply to regular files only; directories always pass so their
children can be judged individually.

---

## Safety layer

`PathDenylist.decide(...)` is the last line of defence and runs **after** rule
matching. It returns `.allowed` or `.denied(reason:)` with one of seven reasons:
`systemProtected`, `runningApplication`, `activeCache`, `homeRoot`,
`protectedUserDirectory`, `volumeMountPoint`, `ownBundle`.

Three tables drive it:

- **`alwaysDeniedPrefixes`** — `/System`, `/usr`, `/bin`, `/sbin`, `/var/db`,
  `/var/folders/zz`, `/Library/Apple`, `/Library/Documentation`,
  `/Library/Fonts`, `/Applications/Utilities`, `/cores`, `/etc`, plus the dyld
  and SystemPolicy subtrees. This is the hardcoded SIP list; querying
  `csrutil status` would not be sufficient.
- **`alwaysDeniedExact`** — `/`, the home directory, `~/Library`, `/Library`,
  `/private`, `/var`, `/tmp`, `/Volumes`, `/Applications`. Denied *only* on
  exact equality, because denying everything beneath them would deny the whole
  machine.
- **`protectedUserDirectories`** — Desktop, Documents, Downloads, media folders,
  iCloud Drive, Keychains, Accounts, the Mail store, Messages, iOS backups.

Every entry is written in the canonical form produced by
`PathMatcher.standardize`, so `/private/var/db` needs no entry of its own — it
standardises to `/var/db`. Two prefixes that would otherwise deny legitimate
work (`/Library` for system caches and diagnostic reports, `/var` for the
QuickLook and font caches) are re-opened by an explicit **rule-id allowlist**
rather than by loosening the table.

Additional gates: paths inside a currently running application's bundle are
refused (`NSWorkspace.shared.runningApplications`, snapshotted once per scan);
mount points directly under `/Volumes` are refused while files *inside* a
mounted volume remain ordinary; CleanMac's own bundle is refused; and entries
modified within a rule's `modifiedWithinHours` window are refused as active
caches.

---

## Cleaner

Deletion is **trash-first**. `TrashMover` moves items via
`FileManager.trashItem(at:resultingItemURL:)` — never `removeItem` — and retries
once on transient IO failure. `CleanerService.clean(items:)` groups the work,
records every move in a `CleanManifest` (original path, trash URL, size, rule
id), and collects failures into `manifest.failures` instead of throwing, so one
locked file cannot abort a clean or crash the app.

`HistoryStore` writes each manifest as JSON under
`~/Library/Application Support/CleanMac/History/<timestamp>.json` and provides
`save(_:)`, `all()`, `restore(_:)` and `totalReclaimed()`. `restore(_:)` moves
items back from the Trash — best-effort, since it cannot succeed once the Trash
has been emptied. History is capped at `maxEntries` (200 by default), evicting
the oldest; the cap is enforced on write, so a store that only ever saves still
prunes rather than growing without bound.

---

## Cross-cutting conventions

- **Everything touching the disk goes through the `FileSystem` protocol**, so
  tests run against `MockFileSystem` and never hit real files. The protocol
  covers traversal (`enumerate`, `contentsOfDirectory`, `metadata`), the trash
  round trip (`trash`, `restore`), volumes, and content/directory mutation
  (`readData`, `writeData`, `createDirectory`, `removeItem`) — the last four
  exist because `HistoryStore` persists manifest JSON and would otherwise have
  reached for `FileManager` directly, writing into the developer's real history
  folder even under a mock.

  Two exceptions are deliberate and documented at the call site:
  `FullDiskAccessProbe` measures the kernel's actual TCC decision for this
  process, which a double would falsify, and `HistoryViewModel`'s
  "reveal in Finder" hands a real path to `NSWorkspace`. `HistoryStoreTests`
  asserts the boundary holds by running the whole store against
  `MockFileSystem` under `/mockhome`, a path that cannot exist on a real volume.
- **Concurrency.** ViewModels are `@MainActor ObservableObject`; the scanner,
  cleaner and history store are actors. The target builds with
  `-strict-concurrency=complete`.
- **Localization.** Natural keys: the English text *is* the key, looked up
  through the `L10n` facade over `String(localized:)`. `L10n` takes `String...`
  rather than `CVarArg...` variadics on purpose — `%@` with a Swift `Int` is a
  segfault that produces no compile error, and a `String`-only API turns that
  entire class of bug into one. `Localizable.xcstrings` is generated from the
  call sites by `.verify/genstrings.py --write`; `LocalizationTests` asserts
  source/catalog parity so the two cannot drift.
