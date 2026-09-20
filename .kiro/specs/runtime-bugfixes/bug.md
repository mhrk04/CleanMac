# Bugfix Requirements Document

## Introduction

CleanMac (a CleanMyMac-style macOS SwiftUI app) passes its full unit test suite
(225 tests, 0 failures) but exhibits three distinct defects only observable when
the app is launched and driven from Xcode. The gap exists because the failures
live in packaging/runtime layers that the current test suite does not exercise
the way the shipped app does: resource bundling, SF Symbol validity, and SwiftUI
view-update semantics.

This document analyzes each defect using the bug-condition methodology. Each bug
is captured as its own numbered section with its Current Behavior (defect),
Expected Behavior (correct), and Unchanged Behavior (regression prevention). The
bug condition `C(X)` identifies the inputs/conditions that trigger the defect,
and the property `P(result)` defines the correct behavior for those inputs.

Fixes are ordered by severity:

1. **Bug 1 — "Rules could not be loaded"** (functional, highest severity)
2. **Bug 2 — Invalid SF Symbol `app.badge.trash`** (cosmetic)
3. **Bug 3 — "Publishing changes from within view updates is not allowed"** (correctness warning on a hot render path)

### Environment & Constraints

- **Platform:** macOS 14, SwiftUI / AppKit / Foundation only. No third-party dependencies.
- **Project generation:** XcodeGen from `project.yml`. Resource/target changes require `xcodegen generate` + rebuild.
- **Build/test:** `bash scripts/build.sh --test` (xcodebuild).
- **Commits:** Conventional Commits, GPG-signed; format enforced by `.githooks/commit-msg`.
- **Regression bar:** all 225 existing tests must remain green after every fix.

---

## Bug 1 — "Rules could not be loaded"

### Introduction

At launch the app displays the bootstrap warning alert **"Rules could not be
loaded"**. Large & Old Files silently falls back to built-in defaults, and the
System Junk and Uninstaller rule packs fail entirely because their YAML never
loads. The user is presented with a broken first-run experience and degraded
functionality across three modules.

### Bug Analysis

#### Current Behavior (Defect)

1.1 WHEN the app launches and bootstrap attempts to load the bundled rule packs THEN the system shows the "Rules could not be loaded" warning alert (`RootView.warningBinding` driven by `environment.bootstrapWarning`).

1.2 WHEN `RuleLoader.loadBundled(named:)` is called for `system-junk`, `uninstaller-leftovers`, or `large-files-defaults` THEN the system throws `RuleLoadError.missingResource` because both `bundle.url(forResource:withExtension:"yaml", subdirectory:"Rules")` and the flat fallback `bundle.url(forResource:withExtension:"yaml")` return `nil`.

1.3 WHEN Large & Old Files reads its configuration THEN the system falls back to built-in default values instead of the values in `large-files-defaults.yaml`.

1.4 WHEN any code path resolves the string catalog THEN `Localizable.xcstrings` is also absent from `CleanMac.app/Contents/Resources/` (that directory contains only `Assets.car`).

#### Expected Behavior (Correct)

2.1 WHEN the app launches under normal conditions THEN the system SHALL load all three bundled rule packs successfully and SHALL NOT show the "Rules could not be loaded" warning.

2.2 WHEN `RuleLoader.loadBundled(named:)` is called for each name in `RulePackName.allBundled` THEN the system SHALL resolve the resource URL from the app bundle and return a decoded `RulePack` without throwing.

2.3 WHEN Large & Old Files reads its configuration THEN the system SHALL use the values from `large-files-defaults.yaml` rather than built-in fallbacks.

2.4 WHEN the built app bundle is inspected THEN `Contents/Resources/` SHALL contain the three YAML packs (`system-junk.yaml`, `uninstaller-leftovers.yaml`, `large-files-defaults.yaml`) resolvable the same way the app resolves them, and SHALL contain `Localizable.xcstrings`.

#### Unchanged Behavior (Regression Prevention)

3.1 WHEN a user-supplied rule pack exists in `~/Library/Application Support/CleanMac/Rules/` THEN the system SHALL CONTINUE TO load and merge it over the bundled pack (`loadMerged`, `merge`) exactly as before.

3.2 WHEN a bundled pack is genuinely missing or malformed THEN the system SHALL CONTINUE TO surface `RuleLoadError.missingResource` / `RuleLoadError.malformed` as it does today.

3.3 WHEN the YAML parser decodes a well-formed pack THEN the system SHALL CONTINUE TO produce identical `RulePack` values (rules, excludes, defaults, pack-excludes application).

### Deriving the Bug Condition

```pascal
FUNCTION isBugCondition(X)
  INPUT: X of type RulePackName          // one of RulePackName.allBundled
  OUTPUT: boolean

  // Bug fires when a declared bundled pack cannot be resolved from the
  // built app bundle even though it is declared as a resource in project.yml.
  RETURN X IN RulePackName.allBundled
         AND Bundle.main.url(forResource: X, withExtension: "yaml",
                             subdirectory: "Rules") = nil
         AND Bundle.main.url(forResource: X, withExtension: "yaml") = nil
END FUNCTION
```

```pascal
// Property: Fix Checking - Bundled packs load from the built app bundle
FOR ALL X WHERE X IN RulePackName.allBundled DO
  pack <- RuleLoader(bundle: appBundle).loadBundled(named: X)   // F'
  ASSERT does_not_throw(pack) AND pack.rules_or_defaults_present
END FOR
```

```pascal
// Property: Preservation - User overrides & malformed handling unchanged
FOR ALL X WHERE NOT isBugCondition(X) DO
  ASSERT F(X) = F'(X)   // merge, malformed/missing error surfacing identical
END FOR
```

- **F** — the current build where `Contents/Resources/` holds only `Assets.car`.
- **F'** — the build after the resource packaging is corrected.

---

## Bug 2 — Invalid SF Symbol `app.badge.trash`

### Introduction

The Uninstaller module icon is rendered with the SF Symbol name
`app.badge.trash`, which does not exist in the macOS 14 system symbol set. The
console logs `No symbol named 'app.badge.trash' found in system symbol set` and
the icon renders as a blank/fallback glyph in the sidebar, the Uninstaller
empty state, the module card, and history rows.

### Bug Analysis

#### Current Behavior (Defect)

1.1 WHEN the app references the Uninstaller module icon via `Image(systemName: "app.badge.trash")` or `systemImage: "app.badge.trash"` THEN the system logs `No symbol named 'app.badge.trash' found in system symbol set` and renders a blank/fallback glyph.

1.2 WHEN the symbol name `app.badge.trash` is passed to `NSImage(systemSymbolName:accessibilityDescription:)` THEN the system returns `nil` on macOS 14.

The invalid name appears in four sites:
- `CleanMac/UI/Sidebar/SidebarView.swift` — `case .uninstaller: return "app.badge.trash"`
- `CleanMac/Modules/Uninstaller/UninstallerView.swift` — empty-state `Image(systemName: "app.badge.trash")`
- `CleanMac/UI/Components/ModuleCard.swift` — preview `systemImage: "app.badge.trash"`
- `CleanMac/UI/History/HistoryView.swift` — `case "uninstaller": return "app.badge.trash"`

#### Expected Behavior (Correct)

2.1 WHEN the app references the Uninstaller module icon THEN the system SHALL use a valid macOS 14 SF Symbol (chosen from candidates `trash`, `trash.square.fill`, `xmark.bin.fill`, or `app.badge`) applied consistently across all four sites.

2.2 WHEN the chosen symbol name is passed to `NSImage(systemSymbolName:accessibilityDescription:)` THEN the system SHALL return a non-nil image and log no "No symbol named …" warning.

#### Unchanged Behavior (Regression Prevention)

3.1 WHEN any other module icon is rendered (`sparkles`, `externaldrive.badge.timemachine`, `doc.text.magnifyingglass`, `clock.arrow.circlepath`, `trash`, etc.) THEN the system SHALL CONTINUE TO resolve to its existing valid symbol.

3.2 WHEN the Uninstaller icon is displayed THEN the system SHALL CONTINUE TO apply the same styling (font size, color, layout) it does today — only the symbol name changes.

### Deriving the Bug Condition

```pascal
FUNCTION isBugCondition(X)
  INPUT: X of type String                // an SF Symbol name the app references
  OUTPUT: boolean

  RETURN app_references_symbol(X)
         AND NSImage(systemSymbolName: X, accessibilityDescription: nil) = nil
END FUNCTION
```

```pascal
// Property: Fix Checking - every referenced module-icon symbol is valid
FOR ALL X WHERE app_references_module_icon(X) DO
  ASSERT NSImage(systemSymbolName: X, accessibilityDescription: nil) != nil    // F'
END FOR
```

```pascal
// Property: Preservation - previously-valid symbols still resolve
FOR ALL X WHERE NOT isBugCondition(X) DO
  ASSERT F(X) = F'(X)
END FOR
```

---

## Bug 3 — "Publishing changes from within view updates is not allowed"

### Introduction

During normal navigation and menu-bar toggling, SwiftUI logs
`Publishing changes from within view updates is not allowed, this will cause
undefined behavior`, repeatedly on a hot render path. A `@Published` /
`ObservableObject` value is being mutated synchronously during a view-update
pass. This is a correctness warning that signals undefined SwiftUI behavior even
though the UI often appears to work.

### Bug Analysis

#### Current Behavior (Defect)

1.1 WHEN the `MenuBarExtra(isInserted:)` binding setter in `CleanMac/App/CleanMacApp.swift` writes `settings.showMenuBarExtra = $0` during a view-update pass THEN `SettingsStore` fires `objectWillChange` (via its `PassthroughSubject` on the setter) while a body evaluation is in progress, and SwiftUI logs the "Publishing changes from within view updates" warning.

1.2 WHEN `moduleContent` / `selectionBinding` read (and any binding setter writes) `settings.selectedSidebarItem` during render THEN a mutation to the observed store can occur inside the view-update pass, triggering the same warning.

1.3 WHEN the user navigates between modules or toggles the menu bar extra THEN the warning fires repeatedly.

#### Expected Behavior (Correct)

2.1 WHEN the user navigates all modules THEN the system SHALL NOT log any "Publishing changes from within view updates" warning.

2.2 WHEN the user toggles the menu bar extra on/off THEN the system SHALL NOT log any "Publishing changes from within view updates" warning, and the menu bar item SHALL still appear/disappear correctly.

2.3 WHEN any observed-store state must change in response to UI THEN the system SHALL perform the write outside the view-update pass (in an action / `onChange` / async dispatch), not inside a computed binding or body evaluation that also runs during render.

#### Unchanged Behavior (Regression Prevention)

3.1 WHEN the menu bar extra is toggled THEN the system SHALL CONTINUE TO show/hide the menu bar item and persist `showMenuBarExtra` in `UserDefaults`.

3.2 WHEN the user selects a sidebar item THEN the system SHALL CONTINUE TO switch the detail pane and persist `selectedSidebarItem`.

3.3 WHEN asynchronous scan progress updates arrive THEN the system SHALL CONTINUE TO hop to `@MainActor` via `Task { @MainActor in }` as it does today (these are already correct and are not the cause).

### Deriving the Bug Condition

```pascal
FUNCTION isBugCondition(X)
  INPUT: X of type ViewUpdateEvent    // a navigation or menu-bar-toggle render pass
  OUTPUT: boolean

  // Fires when an observed ObservableObject is mutated synchronously while a
  // SwiftUI body/view-update pass is executing.
  RETURN observed_store_mutated_during(X)
         AND mutation_is_synchronous_within_view_update(X)
END FUNCTION
```

```pascal
// Property: Fix Checking - no publish-during-update on nav / toggle
FOR ALL X WHERE X IN {navigate_modules, toggle_menu_bar_extra} DO
  runtime_log <- run_app_and_perform(X)                          // F'
  ASSERT NOT contains(runtime_log,
    "Publishing changes from within view updates is not allowed")
END FOR
```

```pascal
// Property: Preservation - navigation & persistence behavior unchanged
FOR ALL X WHERE NOT isBugCondition(X) DO
  ASSERT F(X) = F'(X)   // selection switches, showMenuBarExtra persists
END FOR
```

> **Testability note:** This warning is emitted by SwiftUI at runtime and is
> hard to assert deterministically in a unit test. Verification is primarily
> runtime observation (launch, navigate every module, toggle the menu bar extra,
> confirm the warning no longer prints), supplemented by any feasible structural
> assertion (e.g. asserting that store mutations are not invoked from within
> computed-binding getters used during render).

---

## Root Cause Analysis

### Bug 1 — Rules could not be loaded

The bundled YAML rule packs and the string catalog are **not copied into the
built app bundle**. Inspecting `build/DerivedData/Build/Products/Debug/CleanMac.app/Contents/Resources/`
shows only `Assets.car` — no `Rules/` folder, no `.yaml` files, and no
`Localizable.xcstrings`.

`project.yml` declares them as resources:

```yaml
resources:
  - path: CleanMac/Resources/Rules
    buildPhase: resources
    type: folder
    optional: false
  - path: CleanMac/Resources/Localizable.xcstrings
    buildPhase: resources
    optional: false
```

…and excludes them from the compiled `sources` so they are only picked up via
the resource declaration:

```yaml
sources:
  - path: CleanMac
    excludes:
      - "Resources/Rules/**"
      - "Resources/Localizable.xcstrings"
```

Despite this, the products directory does not contain them. `RuleLoader.loadBundled(named:)`
first tries `bundle.url(forResource: name, withExtension: "yaml", subdirectory: "Rules")`,
then falls back to a flat `bundle.url(forResource: name, withExtension: "yaml")`;
both return `nil`, so it throws `RuleLoadError.missingResource`. Bootstrap
catches that and sets `environment.bootstrapWarning`, which drives the alert.

The defect is in **resource packaging**, not in the loader logic:

- The `type: folder` (blue folder reference) is expected to land at
  `Contents/Resources/Rules/<name>.yaml` — matching the loader's
  `subdirectory: "Rules"` lookup. If XcodeGen emits a group/`type` that does not
  produce a real "Copy Bundle Resources" phase entry (or produces a flattened
  layout that mismatches the `subdirectory` expectation), the files never ship.
- The `Localizable.xcstrings` resource is missing for the same class of reason.

The fix must be verified against the loader's exact resolution path (folder
subdirectory first, flat second). Any change to `project.yml` requires
`xcodegen generate` followed by a rebuild before re-testing.

### Bug 2 — Invalid SF Symbol `app.badge.trash`

`app.badge.trash` is **not a valid SF Symbol on macOS 14**. `NSImage(systemSymbolName:accessibilityDescription:)`
returns `nil` for it and AppKit logs `No symbol named 'app.badge.trash' found in
system symbol set`. The same invalid literal was duplicated across four call
sites (sidebar icon mapping, Uninstaller empty state, module-card preview, and
history icon mapping), so the blank glyph appears everywhere the Uninstaller
icon is shown. The root cause is simply an incorrect symbol name — no valid
composite symbol combines `app` + `badge` + `trash` on this OS version.

### Bug 3 — Publishing changes from within view updates

A `@Published`/`ObservableObject`-backed value is mutated **synchronously during
a SwiftUI view-update pass**. `SettingsStore` fires `objectWillChange` on every
setter — its `showMenuBarExtra` setter runs `defaults.set(...); publisher.send()`,
and `publisher` is wired to `objectWillChange.send()` in `init`:

```swift
private let publisher = PassthroughSubject<Void, Never>()
changeCancellable = publisher.sink { [weak self] in self?.objectWillChange.send() }
...
public var showMenuBarExtra: Bool {
    get { defaults.bool(forKey: Keys.showMenuBarExtra) }
    set { defaults.set(newValue, forKey: Keys.showMenuBarExtra); publisher.send() }
}
```

The likely trigger is the `MenuBarExtra(isInserted:)` binding in
`CleanMacApp.swift`, whose setter writes `settings.showMenuBarExtra = $0`. When
SwiftUI evaluates that binding during a scene/view-update pass, the setter's
`publisher.send()` fires `objectWillChange` while an update is in flight — the
exact condition SwiftUI warns about. The sidebar `selectionBinding` /
`moduleContent`, which both read and write `settings.selectedSidebarItem` around
render, is a secondary candidate for the same pattern. Asynchronous scan
progress is already dispatched via `Task { @MainActor in }`, so it is ruled out.

---

## Verification / Exploration Test Strategy

The strategy is two-phase per the bug-condition methodology: first surface
counterexamples on the **unfixed** build/code (exploration), then verify the fix
holds and existing behavior is preserved.

> **Reminder:** write and run these exploration tests BEFORE implementing any
> fix, and run them against the UNFIXED build so the failure confirms the bug.

### Bug 1 — Bundled resources present & loadable

- **Exploration (must FAIL on unfixed build):** a test that resolves each pack
  in `RulePackName.allBundled` from the app bundle the same way the app does —
  `Bundle(for:).url(forResource:withExtension:"yaml", subdirectory:"Rules")`
  with the flat fallback — and asserts `RuleLoader(bundle:).loadBundled(named:)`
  returns without throwing for all three. On the unfixed build the resources are
  absent → `RuleLoadError.missingResource` → test fails.
- **Fix checking (PASSES after fix):** same test passes once packaging is
  corrected and the bundle is rebuilt.
- **Preservation:** existing `RuleLoaderTests` (user-override merge, malformed
  handling, decode fidelity) continue to pass unchanged.
- **Note:** because the resource lives in the built product, the test must load
  from the test host's bundle (`Bundle(for: SomeTestClass.self)` /
  `Bundle.main` under the test host), and the fix requires `xcodegen generate` +
  rebuild before the test can go green.

### Bug 2 — All referenced module-icon symbols are valid

- **Exploration (must FAIL on unfixed code):** a test asserting
  `NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil` for
  every SF Symbol name the app references for module icons. On unfixed code the
  assertion fails for `app.badge.trash`.
- **Fix checking (PASSES after fix):** after replacing the name with a valid
  macOS 14 symbol at all four sites, every referenced name resolves non-nil.
- **Preservation:** the same test also covers the other module symbols
  (`sparkles`, `externaldrive.badge.timemachine`, `doc.text.magnifyingglass`,
  `clock.arrow.circlepath`, `trash`), guarding against future invalid names.

### Bug 3 — No publish-during-view-update warning

- **Primary verification is runtime observation:** launch the app, navigate
  through every module, and toggle the menu bar extra on/off; confirm the
  console no longer prints `Publishing changes from within view updates is not
  allowed`. This bug is hard to assert deterministically in a unit test because
  the warning is emitted by SwiftUI's runtime during a view-update pass.
- **Feasible structural assertion (best-effort):** verify that observed-store
  mutations are not performed from within computed-binding getters used during
  render (e.g. the `isInserted` get should be read-only; the write path should
  be an action / `onChange` / async dispatch). Any refactor should keep the
  binding get pure.
- **Preservation:** confirm the menu bar item still appears/disappears and
  `showMenuBarExtra` still persists; confirm sidebar selection still switches
  the detail pane and persists `selectedSidebarItem`.

---

## Fix Approach

Fixes are applied in severity order. Each keeps the existing 225 tests green and
uses only SwiftUI / AppKit / Foundation. Commits follow Conventional Commits and
are GPG-signed (enforced by `.githooks/commit-msg`).

### Fix 1 (first) — Package bundled rule packs & string catalog

- Correct the resource declaration in `project.yml` so the three YAML packs land
  at `Contents/Resources/Rules/<name>.yaml` (matching `loadBundled`'s
  `subdirectory: "Rules"` lookup) and `Localizable.xcstrings` lands in
  `Contents/Resources/`. Evaluate whether the `type: folder` reference is being
  honored as a real Copy-Bundle-Resources entry; if the folder-reference layout
  does not reach the product, switch to explicitly listing the resource files
  (or an approach that guarantees the `Rules/` subdirectory is preserved),
  keeping the loader's subdirectory-then-flat resolution intact.
- Run `xcodegen generate`, rebuild, and re-inspect
  `CleanMac.app/Contents/Resources/` to confirm the `Rules/` folder, the three
  `.yaml` files, and `Localizable.xcstrings` are present.
- No change to `RuleLoader` logic is expected; the loader already handles both
  subdirectory and flat layouts.

### Fix 2 — Replace invalid SF Symbol

- Choose one valid macOS 14 symbol (from `trash`, `trash.square.fill`,
  `xmark.bin.fill`, or `app.badge`) and apply it consistently to all four sites:
  `SidebarView.swift`, `UninstallerView.swift`, `ModuleCard.swift`, and
  `HistoryView.swift`. Keep surrounding styling untouched.

### Fix 3 — Move store mutations out of the view-update pass

- Ensure no `ObservableObject` write happens during body evaluation. For the
  `MenuBarExtra(isInserted:)` binding, keep the `get` pure and route the `set`
  so the mutation is deferred out of the view-update pass (e.g. via an action /
  `onChange`, or an async dispatch) rather than firing `objectWillChange`
  synchronously inside a binding invoked during render. Apply the same treatment
  to the sidebar `selectionBinding`/`moduleContent` write path if it exhibits
  the pattern. Verify by runtime observation that the warning no longer prints
  during navigation and menu-bar toggling, and that toggle/selection behavior
  and persistence are unchanged.
