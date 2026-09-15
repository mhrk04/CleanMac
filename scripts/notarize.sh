#!/usr/bin/env bash
#
# notarize.sh — Milestone 9: archive, sign with Developer ID, notarize,
# staple, and verify.
#
# Usage:
#   bash scripts/notarize.sh                    # full run
#   bash scripts/notarize.sh --check            # verify prerequisites only
#   NOTARY_PROFILE=acme bash scripts/notarize.sh
#
# Spelled `bash scripts/...` because the executable bit is not guaranteed to
# survive a fresh clone; `chmod +x scripts/*.sh` once to invoke them directly.
#
# Requires full Xcode (not just Command Line Tools), a "Developer ID
# Application" certificate in the login keychain, and a stored notarytool
# credential profile. Nothing here needs to run as root.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Team/identity detection lives in one place, shared with build.sh, so a release
# can never be signed with a different identity than a local build resolved.
# shellcheck source=scripts/detect-team.sh
source "${SCRIPT_DIR}/detect-team.sh"

SCHEME="CleanMac"
CONFIGURATION="Release"
BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/${SCHEME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
APP_NAME="${SCHEME}.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-cleanmac-notary}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

check_prerequisites() {
    log "Checking prerequisites"

    # xcodebuild exists under Command Line Tools too, but archiving and
    # exporting a signed .app needs the full Xcode toolchain. `xcode-select -p`
    # pointing at CommandLineTools is the failure mode that produces the most
    # confusing downstream errors, so it is called out explicitly.
    cleanmac_has_full_xcode ||
        die "Full Xcode required (found $(cleanmac_dev_dir)). Run: sudo xcode-select -s /Applications/Xcode.app"

    command -v xcodebuild >/dev/null || die "xcodebuild not found"
    command -v xcrun      >/dev/null || die "xcrun not found"

    # Spec §1: the team is auto-detected from the codesigning identities
    # rather than hardcoded, so the same checkout builds on any signed-in
    # machine without editing project.yml.
    TEAM_ID="${TEAM_ID:-$(cleanmac_team_id)}"
    [ -n "$TEAM_ID" ] || die "No Team ID; pass TEAM_ID=XXXXXXXXXX explicitly"

    SIGNING_IDENTITY="$(cleanmac_signing_identity)"
    [ -n "$SIGNING_IDENTITY" ] || die "No 'Developer ID Application' identity in the keychain"

    log "Team:              ${TEAM_ID}"
    log "Signing identity:  ${SIGNING_IDENTITY}"
    log "Notary profile:    ${NOTARY_PROFILE}"

    # A missing profile is fatal at submit time, minutes into an upload, so
    # probe it up front. `history` is a cheap authenticated call.
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
        die "notarytool profile '${NOTARY_PROFILE}' is not usable. Store one with:
  xcrun notarytool store-credentials '${NOTARY_PROFILE}' \\
      --apple-id you@example.com --team-id ${TEAM_ID} --password <app-specific-password>"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

generate_project() {
    if [ ! -f "${SCHEME}.xcodeproj/project.pbxproj" ]; then
        command -v xcodegen >/dev/null ||
            die "XcodeGen not installed. Run: brew install xcodegen"
        log "Generating ${SCHEME}.xcodeproj"
        xcodegen generate
    fi
}

write_export_options() {
    log "Writing ${EXPORT_OPTIONS}"
    mkdir -p "$BUILD_DIR"
    cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST
}

archive() {
    log "Archiving (${CONFIGURATION})"
    rm -rf "$ARCHIVE_PATH"
    xcodebuild -project "${SCHEME}.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE_PATH" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="Developer ID Application" \
        archive
    [ -d "$ARCHIVE_PATH" ] || die "Archive was not produced at ${ARCHIVE_PATH}"
}

export_archive() {
    log "Exporting signed app"
    rm -rf "$EXPORT_PATH"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$EXPORT_PATH"
    [ -d "${EXPORT_PATH}/${APP_NAME}" ] || die "No ${APP_NAME} in ${EXPORT_PATH}"
}

# ---------------------------------------------------------------------------
# Verify, notarize, staple
# ---------------------------------------------------------------------------

verify_signature() {
    local app="${EXPORT_PATH}/${APP_NAME}"
    log "Verifying signature and hardened runtime"

    codesign --verify --deep --strict --verbose=2 "$app"

    # Hardened Runtime is mandatory for notarization. It shows up as the
    # `runtime` flag in the CodeDirectory flags; its absence is the single most
    # common reason an otherwise valid signature is rejected by the notary.
    local flags
    flags="$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^flags=\(.*\)/\1/p')"
    case "$flags" in
        *runtime*) log "Hardened Runtime: enabled (${flags})" ;;
        *) die "Hardened Runtime missing (flags='${flags:-none}'). project.yml sets ENABLE_HARDENED_RUNTIME=YES and OTHER_CODE_SIGN_FLAGS='--timestamp --options runtime'; do not override them." ;;
    esac

    # A secure timestamp is equally mandatory.
    codesign -dvv "$app" 2>&1 | grep -q "Timestamp=" ||
        die "No secure timestamp on the signature; notarization will be rejected."

    spctl --assess --type execute --verbose=4 "$app" || true
}

notarize_and_staple() {
    local app="${EXPORT_PATH}/${APP_NAME}"
    local zip="${BUILD_DIR}/${SCHEME}-notary.zip"

    # ditto, not `zip`: the archive must preserve resource forks and the bundle's
    # symlink structure or the notary service cannot validate it.
    log "Packaging for notarization"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"

    log "Submitting to the notary service (this can take several minutes)"
    xcrun notarytool submit "$zip" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    log "Stapling the ticket"
    xcrun stapler staple "$app"

    # Stapling is what lets Gatekeeper clear the app offline, so confirm the
    # ticket is actually attached rather than trusting the exit code.
    xcrun stapler validate "$app"
    rm -f "$zip"
}

gatekeeper_check() {
    local app="${EXPORT_PATH}/${APP_NAME}"
    log "Gatekeeper assessment (spec Milestone 9)"
    # Expected output ends with: "source=Notarized Developer ID"
    spctl -a -vvv -t exec "$app"
}

# ---------------------------------------------------------------------------

main() {
    if [ "${1:-}" = "--check" ]; then
        check_prerequisites
        log "All prerequisites satisfied"
        return 0
    fi

    check_prerequisites
    generate_project
    write_export_options
    archive
    export_archive
    verify_signature
    notarize_and_staple
    gatekeeper_check

    log "Done. Distributable app: ${EXPORT_PATH}/${APP_NAME}"
}

main "$@"
