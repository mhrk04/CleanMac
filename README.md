# CleanMac

A native macOS 14+ cleaning utility in SwiftUI. A rule-driven, trash-first,
CleanMyMac-style tool covering four core modules:

- **Smart Scan** — one-click aggregator that runs everything below in parallel.
- **System Junk** — caches, logs, language files, Xcode derived data, Trash bins,
  Mail downloads, iOS device backups.
- **Uninstaller** — remove an app plus all of its leftovers across
  `~/Library`, `/Library`, containers, group containers, launch agents/daemons,
  HTTPStorages, saved state.
- **Large & Old Files** — find big files you haven't opened in months.

Design principles:

1. **Rule-driven** — cleaning logic lives in YAML rule packs, not hardcoded paths.
   Ship updated rules without shipping a new binary.
2. **Trash-first** — nothing is permanently deleted. Every clean operation writes
   a `CleanManifest` to disk so it can be undone from History.
3. **Safety denylist** — SIP-protected paths, running application bundles, and
   recently-written caches are hard-refused after rule matching. Even a bad rule
   cannot touch them.
4. **No third-party dependencies** — Swift stdlib, SwiftUI, AppKit, Foundation
   only. Includes a tiny hand-rolled YAML subset parser.

---

## Requirements

- macOS 14 Sonoma or later (target and host).
- Xcode 15.4+ (Xcode 16+ recommended).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — used to generate the
  `.xcodeproj` from `project.yml`.
- An Apple Developer account with **Developer ID Application** signing
  certificate for distribution. Local development works with ad-hoc signing.

## Getting started

All commands run from the **repository root** — that is where `project.yml`
lives. `CleanMac/` is the sources folder, not the project folder.

The helper scripts are invoked through `bash` below so they work on a fresh
clone regardless of the executable bit. To call them directly instead, run
`chmod +x scripts/*.sh` once.

First-time setup on a fresh clone wires up the git hooks and commit signing —
these live in `.git/config`, which git cannot version, so they are set per
clone by a small idempotent script:

```bash
make setup        # or: bash scripts/setup.sh
```

This points `core.hooksPath` at `.githooks/` (so the Conventional Commits
message hook runs), sets `.gitmessage` as the commit template, and enables
GPG signing when a secret key is present. It is safe to run more than once.

```bash
# 1. Install XcodeGen (one time)
brew install xcodegen

# 2. See what this machine can sign with
bash scripts/build.sh --doctor

# 3. Generate the project and build (Debug, ad-hoc signed)
bash scripts/build.sh

# 4. Or generate the project and open it in Xcode
bash scripts/build.sh --open
```

`scripts/build.sh` runs `xcodegen generate` on first use, then builds. The
signing team is **auto-detected** from the keychain
(`security find-identity -v -p codesigning`) and passed to `xcodebuild`, so
`project.yml` is never hand-edited and never committed with a team id in it.

In Xcode, select the `CleanMac` scheme and press **Cmd+R**.

> First launch will show an onboarding sheet asking for **Full Disk Access**.
> Without it, the scanner can only see your own files, not system caches or
> other apps' containers.

### Running the tests

```bash
bash scripts/build.sh --test      # XCTest suite via xcodebuild
```

## Distribution (Developer ID)

One command runs the whole pipeline — archive, sign, notarize, staple, and
verify with Gatekeeper:

```bash
bash scripts/notarize.sh --check   # verify prerequisites only (fast)
bash scripts/notarize.sh           # archive -> sign -> notarize -> staple -> spctl
```

Both scripts share the same team/identity detection
([`scripts/detect-team.sh`](scripts/detect-team.sh)), so a release can never be
signed with a different identity than a local build resolved. `--check` fails
fast with an actionable message when full Xcode, a Developer ID certificate, or
a notarytool profile is missing.

See [`docs/notarization.md`](docs/notarization.md) for the underlying steps,
expected `codesign`/`spctl` output, and troubleshooting.

## Repository layout

```
.
├── project.yml              # XcodeGen spec (the .xcodeproj is generated, gitignored)
├── CleanMac/                # App target sources
│   ├── App/                 # @main, AppDelegate, DI container
│   ├── Core/                # Scanner, Rules, Cleaner, Safety, FileSystem,
│   │                        #   Permissions, Persistence, Localization
│   ├── Modules/             # One folder per feature module
│   ├── UI/                  # Theme, reusable components, sidebar, settings
│   ├── Resources/           # Assets.xcassets, rule packs, Localizable.xcstrings
│   └── Supporting/          # Info.plist, entitlements
├── CleanMacTests/           # XCTest unit tests + MockFileSystem
├── scripts/                 # build.sh, notarize.sh, detect-team.sh
├── docs/                    # ARCHITECTURE.md, notarization.md
└── README.md
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for a deeper dive into the
scanner engine, the rule pack format, and the safety denylist.

## Contributing

After cloning, run `make setup` once (see Getting started).

Commits follow [Conventional Commits](https://www.conventionalcommits.org):
`type(scope): subject`, where `type` is one of `feat`, `fix`, `docs`, `style`,
`refactor`, `perf`, `test`, `build`, `ci`, `chore`, or `revert`. The
`.githooks/commit-msg` hook rejects any subject that does not match, and
`.gitmessage` is preloaded as the commit template to guide the format.

All commits are **GPG-signed** (`commit.gpgsign` is enabled by `make setup`
when a key is available), so the history stays verifiable on GitHub. To sign
you need a GPG key registered with your GitHub account; without one, disable
signing locally with `git config commit.gpgsign false`.

Common tasks are exposed through the `Makefile` — run `make` (or `make help`)
to list them: `setup`, `project`, `build`, `release`, `test`, `doctor`,
`notarize`.

## License

Provided as-is for educational and personal use. CleanMyMac is a trademark of
MacPaw Inc.; this project is not affiliated with, endorsed by, or derived from
MacPaw's product.
