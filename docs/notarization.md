# Notarization & Distribution (Milestone 9)

CleanMac ships **outside the Mac App Store**, signed with a *Developer ID
Application* certificate, with the Hardened Runtime enabled and a stapled
notarization ticket. This document is the full procedure.

Everything below is automated by [`scripts/notarize.sh`](../scripts/notarize.sh):

```bash
bash scripts/notarize.sh --check     # verify prerequisites only
bash scripts/notarize.sh             # archive -> sign -> notarize -> staple -> verify
```

The scripts are invoked through `bash` so they work on a fresh clone regardless
of the executable bit; `chmod +x scripts/*.sh` once if you prefer to call them
directly.

The script aborts with an actionable message if any prerequisite is missing, so
`--check` is the fastest way to find out what your machine still needs.

[`scripts/build.sh --doctor`](../scripts/build.sh) prints the same assessment in
more detail and is the better starting point when you have never signed a Mac
app on this machine before.

---

## Prerequisites

| Requirement | Check |
| --- | --- |
| Full Xcode (not just Command Line Tools) | `xcode-select -p` must *not* end in `CommandLineTools` |
| XcodeGen | `command -v xcodegen` — install with `brew install xcodegen` |
| Developer ID Application certificate | `security find-identity -v -p codesigning` |
| Apple Developer Program membership | required for notarization; $99/yr |
| Stored notarytool credential profile | `xcrun notarytool history --keychain-profile <name>` |

### Team ID auto-detection

Per the plan, the team is **auto-detected** rather than hardcoded, so the same
checkout builds on any signed-in machine without editing `project.yml`.

The detection lives in one place —
[`scripts/detect-team.sh`](../scripts/detect-team.sh) — which both `build.sh`
and `notarize.sh` source. Sharing it is what stops a local build and a release
from ever resolving to different identities. Run it directly to see what it
finds:

```bash
bash scripts/detect-team.sh              # the team id, or nothing
bash scripts/detect-team.sh --identity   # the full identity string
bash scripts/detect-team.sh --report     # human-readable, with the fix for each gap
```

Internally it parses the team out of the codesigning identity list:

```bash
security find-identity -v -p codesigning \
  | sed -n 's/.*"Developer ID Application: .* (\([A-Z0-9]*\))".*/\1/p' \
  | head -1
```

Given:

```
  1) 0123456789ABCDEF... "Developer ID Application: Acme Inc (TEAMID123)"
  2) FEDCBA9876543210... "Apple Development: dev@example.com (OTHERTEAM9)"
  3) AAAABBBBCCCCDDDD... "Developer ID Installer: Acme Inc (TEAMID123)"
```

this yields `TEAMID123`. Note the literal `)` before the closing quote — the
team id is parenthesised, and omitting that paren from the pattern silently
matches nothing. Two other details are easy to get wrong and are handled there:
only a `Developer ID Application` identity counts (`Apple Development` and
`Developer ID Installer` lines must not match), and the `sed` runs on macOS's
BSD `sed`, so GNU-only constructs such as `\?` cannot be used.

Override with `TEAM_ID=XXXXXXXXXX bash scripts/notarize.sh` if you hold several
Developer ID identities.

### Store notarytool credentials once

```bash
xcrun notarytool store-credentials "cleanmac-notary" \
    --apple-id you@example.com \
    --team-id TEAMID123 \
    --password <app-specific-password>
```

Use a different profile name via `NOTARY_PROFILE=acme scripts/notarize.sh`.

---

## The steps

### 1. Generate the project

```bash
xcodegen generate
```

`CleanMac.xcodeproj` is gitignored — it is a build artifact of `project.yml`.

### 2. Archive

```bash
xcodebuild -project CleanMac.xcodeproj \
    -scheme CleanMac -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath build/CleanMac.xcarchive \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    archive
```

`project.yml` already sets `ENABLE_HARDENED_RUNTIME: YES` and
`OTHER_CODE_SIGN_FLAGS: "--timestamp --options runtime"` for the Release
configuration. Do not override either — both are mandatory for notarization.

### 3. Export the signed app

`build/ExportOptions.plist`:

```xml
<dict>
    <key>method</key>              <string>developer-id</string>
    <key>teamID</key>              <string>TEAMID123</string>
    <key>signingStyle</key>        <string>manual</string>
    <key>signingCertificate</key>  <string>Developer ID Application</string>
    <key>destination</key>         <string>export</string>
</dict>
```

```bash
xcodebuild -exportArchive \
    -archivePath build/CleanMac.xcarchive \
    -exportOptionsPlist build/ExportOptions.plist \
    -exportPath build/export
```

### 4. Verify the signature *before* uploading

Uploading takes minutes, so check the two things that most often cause a
rejection first:

```bash
codesign --verify --deep --strict --verbose=2 build/export/CleanMac.app

# Hardened Runtime must appear in the flags:
codesign -dv --verbose=4 build/export/CleanMac.app 2>&1 | grep '^flags='
#   expect: flags=0x10000(runtime)

# A secure timestamp must be present:
codesign -dvv build/export/CleanMac.app 2>&1 | grep '^Timestamp='
```

### 5. Package and submit

Use `ditto`, not `zip`: the archive must preserve resource forks and the
bundle's symlink structure or the notary service cannot validate it.

```bash
ditto -c -k --keepParent build/export/CleanMac.app build/CleanMac-notary.zip

xcrun notarytool submit build/CleanMac-notary.zip \
    --keychain-profile cleanmac-notary --wait
```

Expect `status: Accepted`. On `Invalid`, retrieve the per-file report:

```bash
xcrun notarytool log <submission-id> --keychain-profile cleanmac-notary
```

### 6. Staple the ticket

```bash
xcrun stapler staple build/export/CleanMac.app
xcrun stapler validate build/export/CleanMac.app
```

Stapling embeds the ticket in the bundle so Gatekeeper clears the app **offline**
— without it, first launch requires a network round trip to Apple.

### 7. Gatekeeper assessment

```bash
spctl -a -vvv -t exec build/export/CleanMac.app
```

Expected output:

```
build/export/CleanMac.app: accepted
source=Notarized Developer ID
```

Anything other than `accepted` / `source=Notarized Developer ID` means the
artifact is not distributable.

---

## Troubleshooting

**`Full Xcode required (found /Library/Developer/CommandLineTools)`**
Command Line Tools ship `xcodebuild` but cannot archive or export a signed app.

```bash
sudo xcode-select -s /Applications/Xcode.app
```

**`0 valid identities found`**
No Developer ID Application certificate is installed. Create one in Xcode →
Settings → Accounts → Manage Certificates, or download it from
developer.apple.com. Without it the app can still be built locally with ad-hoc
signing (the Debug configuration does exactly this) but cannot be distributed.

**`The binary is not signed with a valid Developer ID certificate`**
The export used the wrong identity. Check `signingCertificate` in
`ExportOptions.plist` and that `CODE_SIGN_IDENTITY` was not overridden.

**`The binary is not signed with the Hardened Runtime`**
`ENABLE_HARDENED_RUNTIME` was turned off, or `--options runtime` was dropped
from `OTHER_CODE_SIGN_FLAGS`.

**`ERR_SUBMISSION_TIMESTAMP / The signature does not include a secure timestamp`**
Signing happened without network access. A secure timestamp requires reaching
Apple's timestamp server at signing time.

---

## What cannot be verified on a machine without credentials

Archiving, submitting to the notary service, and stapling all require full Xcode
plus a paid Developer ID identity. On a machine with only Command Line Tools and
no certificates, `bash scripts/notarize.sh --check` fails fast with the reason —
it does not silently produce an unsigned artifact that looks like a release.
`bash scripts/build.sh --doctor` prints the same assessment with the fix for
each gap. The Debug configuration still builds and runs locally with ad-hoc
signing, exactly as the plan's Assumptions describe.
