#!/usr/bin/env bash
#
# build.sh — generate the Xcode project and build CleanMac.
#
# Usage:
#   bash scripts/build.sh                 # Debug, ad-hoc signed. No certificate needed.
#   bash scripts/build.sh --release       # Release, signed with Developer ID.
#   bash scripts/build.sh --test          # run CleanMacTests
#   bash scripts/build.sh --doctor        # print what this machine can sign with
#   bash scripts/build.sh --open          # generate the project and open it in Xcode
#
# Every command above is spelled `bash scripts/...` because the executable bit
# is not guaranteed to survive a fresh clone; `chmod +x scripts/*.sh` once if you
# prefer to invoke them directly.
#
# The signing team is auto-detected from the keychain (spec §1) and passed to
# xcodebuild on the command line, so `project.yml` never has to be hand-edited
# and never has to be committed with a team id in it.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The repo root is the directory holding project.yml — not CleanMac/, which is
# the sources folder. Resolving it here means the script works from anywhere.
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/detect-team.sh
source "${SCRIPT_DIR}/detect-team.sh"

SCHEME="CleanMac"
PROJECT="${SCHEME}.xcodeproj"
BUILD_DIR="${REPO_ROOT}/build"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------

ensure_project() {
    [ -f project.yml ] || die "project.yml not found in ${REPO_ROOT}"

    if [ ! -d "${PROJECT}" ]; then
        command -v xcodegen >/dev/null ||
            die "XcodeGen not installed and ${PROJECT} does not exist. Run: brew install xcodegen"
        log "Generating ${PROJECT} from project.yml"
        xcodegen generate
    else
        log "Using existing ${PROJECT}"
    fi
}

# Debug signs ad-hoc, so it must work on a machine with no certificates at all —
# that is the local-development path the plan's Assumptions describe. A team id
# is still passed when one happens to be present, because it costs nothing and
# keeps provisioning consistent for people who do have one.
resolve_team_for_debug() {
    TEAM_ID="${TEAM_ID:-$(cleanmac_team_id)}"
    if [ -n "$TEAM_ID" ]; then
        log "Team (auto-detected): ${TEAM_ID}"
    else
        log "No Developer ID identity found — Debug builds sign ad-hoc, which is fine."
    fi
}

# Release is the distributable configuration: it must be signed with a real
# Developer ID Application identity, so a missing one is fatal rather than
# something that quietly produces an unsigned artifact.
resolve_team_for_release() {
    TEAM_ID="${TEAM_ID:-$(cleanmac_team_id)}"
    [ -n "$TEAM_ID" ] || die "No Developer ID identity to sign a release with.

$(cleanmac_report)

Override with: TEAM_ID=XXXXXXXXXX bash scripts/build.sh --release
For local runs use the ad-hoc Debug build: bash scripts/build.sh"

    SIGNING_IDENTITY="$(cleanmac_signing_identity)"
    log "Team (auto-detected): ${TEAM_ID}"
    log "Signing identity:     ${SIGNING_IDENTITY}"
}

build() {
    local configuration="$1"
    log "Building ${SCHEME} (${configuration})"
    mkdir -p "$BUILD_DIR"

    # DEVELOPMENT_TEAM is passed explicitly so it overrides the deliberately
    # empty value in project.yml. CODE_SIGN_IDENTITY comes from the per-config
    # settings there: ad-hoc for Debug, "Developer ID Application" for Release.
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$configuration" \
        -destination 'platform=macOS' \
        -derivedDataPath "${BUILD_DIR}/DerivedData" \
        DEVELOPMENT_TEAM="${TEAM_ID}" \
        build

    local app="${BUILD_DIR}/DerivedData/Build/Products/${configuration}/${SCHEME}.app"
    [ -d "$app" ] || die "Build reported success but ${app} is missing"
    log "Built: ${app}"
    printf '%s\n' "$app"
}

run_tests() {
    log "Running ${SCHEME}Tests"

    # Hardened Runtime enforces library validation: the host process will only
    # dlopen a bundle signed by the same team. With a real Developer ID team,
    # the app and the xctest bundle share that team, so injection works and
    # Hardened Runtime stays on. But an ad-hoc local run (no certificate) gives
    # the app and the test bundle *different* per-cdhash ad-hoc identities, and
    # the host then refuses to load the test bundle ("different Team IDs"). For
    # that case only, disable Hardened Runtime for the test invocation so the
    # ad-hoc bundle can be injected. This is a command-line override on the test
    # run alone -- it does not edit CleanMac.entitlements or project.yml, so the
    # Release/distribution build keeps Hardened Runtime and library validation.
    local hardened_override=()
    if [ -z "${TEAM_ID:-}" ]; then
        log "No signing team -> disabling Hardened Runtime for the test run so the ad-hoc xctest bundle can inject."
        hardened_override=(ENABLE_HARDENED_RUNTIME=NO)
    fi

    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination 'platform=macOS' \
        -derivedDataPath "${BUILD_DIR}/DerivedData" \
        DEVELOPMENT_TEAM="${TEAM_ID:-}" \
        "${hardened_override[@]}"
}

usage() {
    # Print the leading comment block, minus the shebang. Stopping at the first
    # non-comment line is what keeps `set -euo pipefail` out of the help text —
    # a hardcoded line range drifts every time the header is edited.
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
        "${BASH_SOURCE[0]}"
}

# ---------------------------------------------------------------------------

main() {
    case "${1:-}" in
        --doctor|-d)
            log "Signing capability of this machine"
            cleanmac_report || true
            return 0
            ;;
        --help|-h)
            usage
            return 0
            ;;
        --open)
            ensure_project
            log "Opening ${PROJECT}"
            open "$PROJECT"
            return 0
            ;;
        --release|-r)
            ensure_project
            resolve_team_for_release
            build Release
            return 0
            ;;
        --test|-t)
            ensure_project
            resolve_team_for_debug
            run_tests
            return 0
            ;;
        "")
            ensure_project
            resolve_team_for_debug
            build Debug
            return 0
            ;;
        *)
            die "Unknown option: ${1}. Try --help"
            ;;
    esac
}

main "$@"
