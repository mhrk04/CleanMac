# CleanMac — Security & Production-Readiness Report

CleanMac is an **unsandboxed** macOS application that requests **Full Disk Access (FDA)** and **deletes files** on the user's system. That risk profile — not network endpoints or remote services — defines its threat model. This report treats CleanMac as a **reference implementation** rather than a shipped commercial product, and evaluates it on the terms that matter for a high-privilege, file-deleting desktop utility.

*Report date: as of this review.*

---

## 1. Executive Summary

**Verdict: FUNCTIONAL MVP — NOT YET READY FOR PUBLIC BINARY DISTRIBUTION.**

- **231 tests pass** (full XCTest suite).
- **Real-disk scan-only test passed**: 466 items / 18.32 GB detected on a live machine; the denylist vetoed all protected paths.
- **No critical security findings** in the reviewed code paths.
- **Ship-blockers:**
  - (a) No notarization / code-signing certificate.
  - (b) No professional AppSec audit.
  - (c) Real-machine delete/restore round-trip not yet exercised (only mocked).

CleanMac demonstrates genuinely good safety engineering (trash-first deletion, a layered path denylist, and an undo log). What stands between it and a trustworthy public binary is distribution signing and a real-machine destructive-path validation — not a fundamental design flaw.

---

## 2. Real-Machine Test Results (read-only scan)

A **strictly read-only** scan-only harness (`.verify/scan-only/`) was run against the live machine. The harness **never called any delete or trash API** — it exercised only the scanning and classification path.

**Setup**
- Loaded the `system-junk` pack via the **real `RuleLoader`** — **29 rules**.
- Scanned the live disk using the real scanner engine.

**Scan totals: 466 items, 18.32 GB**

| Category | Items | Size |
|---|---:|---:|
| Caches | 340 | 10.49 GB |
| Developer | 47 | 7.44 GB |
| Logs | 63 | 385.6 MB |
| Other | 16 | 250 KB |

**By safety level**

| Safety level | Items | Size |
|---|---:|---:|
| Safe | 456 | 14.52 GB |
| Review | 10 | 3.79 GB |
| Dangerous | 0 | 0 |

**Top rules by size**

| Rule | Items / Size |
|---|---|
| user-caches | 214 / 10.37 GB |
| pnpm-store | 3.79 GB |
| npm-cache | 1.88 GB |
| pip-cache | — |
| xcode-derived-data | — |

**Denylist spot-check — ALL PASS** (every protected path returned `.denied`):

| Path | Result |
|---|---|
| Home root (`~`) | `.denied` |
| `~/Documents` | `.denied` |
| `~/Library` | `.denied` |
| `/System/Library/Caches` | `.denied` |
| `/usr/bin` | `.denied` |
| `/System` | `.denied` |
| `/bin` | `.denied` |
| `/etc` | `.denied` |
| `/` | `.denied` |

**Automated suite: 231 XCTest cases pass.**

### What is STILL untested

- An **actual clean** (move-to-Trash) on real files on the live machine.
- A **restore round-trip** from the undo log / History on the live machine.

These paths are currently exercised only with mocks. **Recommendation:** before trusting CleanMac on a real machine, manually run a clean on a couple of **safe** cache items, confirm they land in `~/.Trash`, then restore them from History. This is free and should be done next.

---

## 3. Threat Model (STRIDE-style, tailored)

The dominant risk for CleanMac is **destruction of user data**, not remote compromise. The table maps the relevant STRIDE categories to how the code addresses each.

| Threat | Relevance | How the code addresses it |
|---|---|---|
| **Tampering / Destruction of user data** (the #1 risk) | High | Trash-first deletion (`FileManager.trashItem`, never `removeItem` on user files); `CleanManifest` undo log; `PathDenylist` veto at **both** scan time and clean time; `confirmBeforeClean` gate; `review`/`dangerous` safety levels are unchecked/hidden by default. |
| **Elevation via bad / user-supplied rules** | Medium | The denylist runs **after** rule matching, so a malicious user rule in `~/Library/Application Support/CleanMac/Rules/` still cannot reach `/System`, home root, or protected user dirs. User rule packs are **trusted local input**; there is **no remote rule fetching** (no OTA updates in the MVP), so there is no network-borne rule-injection surface. |
| **Information disclosure** | Low | **No network egress** in the app; no telemetry; nothing leaves the machine. |
| **Spoofing / Repudiation** | N/A | Single local-user app; no auth, no accounts. |

**Core risk to communicate:** the **unsandboxed + Full Disk Access** posture is inherently high-privilege. That is the central reason a professional audit matters before public distribution — the app is trusted to reach across the entire filesystem and delete.

---

## 4. Security Findings

No critical or high-severity code vulnerabilities were found in the reviewed paths. The findings below are the honest MEDIUM/LOW/INFO observations, each grounded in the code.

| Severity | Confidence | Area | Finding | Recommendation |
|---|---|---|---|---|
| **MEDIUM** | High | Design / inherent | App runs **without a sandbox** with **Full Disk Access** and deletes files across the system. | Professional AppSec review before public distribution; keep the denylist + trash-first invariants under test (they are). |
| **LOW** | High | Entitlements | `com.apple.security.automation.apple-events` is granted (needed to quit apps before uninstall). Correct and minimal, but it lets the app send Apple Events. | Acceptable for this use; keep scoped to the uninstall flow. |
| **LOW** | High | Uninstaller rules | Launch-agents/daemons and privileged-helper rules touch `/Library/LaunchDaemons` and `/Library/PrivilegedHelperTools`. These are `safety: review` (unchecked by default), which is correct. | Keep them at `review` level; never auto-select. |
| **INFO** | High | Entitlements | Hardened-runtime exceptions (`allow-jit`, `unsigned-executable-memory`, `disable-library-validation`, `allow-dyld-env-vars`) are **all false** — the right posture for notarization. Entitlements are otherwise minimal and correct. | No action. |
| **INFO** | High | Permissions probe | `FullDiskAccessProbe` uses a real POSIX `open()`/`errno` probe against TCC-protected paths and deliberately bypasses the `FileSystem` mock (documented, correct). | No action. |

**False-positive discipline applied:** DoS/resource-exhaustion and hardening-only items were excluded. Only concrete, code-grounded observations are reported here.

---

## 5. Rule-Pack Accuracy Audit

Rule paths were cross-checked against Apple's *File System Programming Guide* and other reputable sources. *Content was rephrased for compliance with licensing restrictions.*

| Path / Rule | Verdict | Notes |
|---|---|---|
| `~/Library/Caches/*` | **CONFIRMED SAFE** | Apple's guidance is that apps should never rely on the existence of cache files, and caches are recreatable. The rule also excludes Safari/AppStore/TCC/CloudKit/`bird` and skips files modified in the last 24h. |
| Xcode DerivedData, npm/pip/homebrew/yarn/pnpm caches | **CONFIRMED** | All regenerable by their respective tools. Xcode recreates its caches on next build (per Apple/community sources). |
| `~/Library/Saved Application State` | **CONFIRMED** | Window/resume state; safe to remove (only loses window restore). Correctly `safe`. |
| `~/Library/HTTPStorages`, `~/Library/WebKit` | **CONFIRMED (with UX note)** | Per-app web storage / cookie caches. Removal logs the user out of some sites but is non-destructive. Reasonable as `safe`. |
| `/var/db/receipts` (uninstaller `receipts` rule, `safety: review`) | **NUANCE** | Installer receipts are used by Software Update and `pkgutil`. Deleting receipts for an app being fully removed is fine, but blanket removal can affect future updates of *other* software. Correctly `review`. The rule scopes to the specific `{bundleId}` (`/var/db/receipts/{bundleId}.*`), which is the safe scoping. |
| `/Library/Caches/*` (`system-caches`, `safety: review`) | **NUANCE** | Requires admin; correct not to pre-check. |
| Mail Envelope Index (`review`) | **CONFIRMED** | Rebuilds on next launch but can take minutes; the description already warns. |

**Overall verdict:** the rule packs are accurate and conservatively classified. The `safe` / `review` / `dangerous` split matches real-world risk.

**Minor recommendations:**
- Add/confirm user-facing effect notes on `HTTPStorages` / `WebKit` (i.e., the user will need to re-login to some sites).
- Keep all `/Library`, launch-daemon, receipt, and backup rules at `review` or `dangerous` — never `safe`.

---

## 6. Shipping Without an Apple Developer ID (free options)

An honest look at the distribution options when you don't pay for the Apple Developer Program:

- **Recommended free path — open source / build-from-source.** Users clone the repo and run `bash scripts/build.sh`. Locally built apps run fine with ad-hoc signing: no cost, no Gatekeeper bypass needed, and users can inspect the code before running it — which matters a great deal for a file-deletion tool with Full Disk Access.
- **Alternative — ship an unsigned / ad-hoc `.app`.** It works, but every downloader hits Gatekeeper ("cannot verify developer") and must right-click → Open or run `xattr -dr com.apple.quarantine CleanMac.app`. In practice, most users won't bypass Gatekeeper for an unsigned cleaner. **Not recommended for a file-deletion tool.**
- **Free Apple ID (personal team) signing** exists, but certificates expire in 7 days and cannot notarize — useful only for local development, not distribution.
- **The paid ($99/yr) Apple Developer Program** is the *only* thing that unlocks a notarized, double-clickable `.app` that passes Gatekeeper cleanly. If you never pay, open-source / build-from-source is the way.

---

## 7. Go / No-Go Checklist to Reach "Shippable"

| Status | Item |
|---|---|
| ☐ | Real-machine clean + restore round-trip verified (do this next; free) |
| ☐ | Professional AppSec review of FDA / no-sandbox / delete paths (recommended before public binary) |
| ☐ | Decide distribution: open-source / build-from-source (free, recommended) **OR** paid Developer ID + notarization |
| ☐ | If paid: run `scripts/notarize.sh`, verify with `spctl -a -vvv` |
| ☐ | App icon finalized (verify `AppIcon` set is not placeholder) |
| ☐ | README with clear "this deletes files / grant FDA at your own risk" warning |
| ☑ | 231 automated tests pass (done) |
| ☑ | Read-only real scan (done) |
| ☑ | Rule-pack accuracy audit (done) |
| ☑ | Security review (done — this document) |

---

## 8. Bottom Line

CleanMac is a solid, well-tested MVP with genuinely good safety engineering — trash-first deletion, a layered denylist, and an undo log — validated on a real disk in scan-only mode (466 items / 18.32 GB, zero protected paths reachable). For **personal use or open-source distribution**, it is effectively ready once you complete a manual clean-and-restore round-trip on the live machine. For a **public signed binary**, you need notarization (paid) and ideally a professional audit, because an unsandboxed, Full-Disk-Access file-deleter is exactly the kind of tool that warrants one.

---

## Disclaimer

This is an **AI-assisted review**, not a substitute for a professional penetration test or an AppSec firm's audit. It is grounded in the code, tests, and web research available at review time, but it does not constitute a security guarantee. For production systems — particularly those handling sensitive data or running with elevated privileges — engage a qualified security firm for a formal assessment before public distribution.
