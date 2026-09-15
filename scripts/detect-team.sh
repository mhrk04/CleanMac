#!/usr/bin/env bash
#
# detect-team.sh — the single source of truth for spec §1's requirement that
# the signing team be *auto-detected* from the keychain rather than hardcoded.
#
# Sourced by build.sh and notarize.sh so the two can never disagree about which
# identity a release is signed with. Also runnable directly:
#
#   bash scripts/detect-team.sh              # prints the team id, or nothing
#   bash scripts/detect-team.sh --identity   # prints the full identity string
#   bash scripts/detect-team.sh --report     # human-readable summary
#   bash scripts/detect-team.sh --xcode      # "yes" when full Xcode is active
#
# Exit status when run directly: 0 if a Developer ID identity was found, 1 if
# not (for `--report` too, so a script can branch on the answer after printing
# it). `--xcode` and `--count` exit 0 regardless.
#
# Spelled `bash scripts/...` because the executable bit is not guaranteed to
# survive a fresh clone; `chmod +x scripts/*.sh` once to invoke them directly.

# The identity list looks like:
#
#   1) 0123456789ABCDEF0123... "Developer ID Application: Acme Inc (TEAMID123)"
#   2) FEDCBA9876543210ABC... "Apple Development: dev@example.com (OTHERTEAM9)"
#   3) AAAABBBBCCCCDDDD123... "Developer ID Installer: Acme Inc (TEAMID123)"
#
# Only line 1 is a valid signing identity for a distributable .app. Note the
# literal `)` before the closing quote: the team id is parenthesised, so the
# pattern must be `(\(TEAM\))"`. Dropping that paren matches nothing and fails
# silently, which is why this lives in one tested place.

# Full identity string, e.g. "Developer ID Application: Acme Inc (TEAMID123)".
# Preferring the whole string over the bare name keeps machines that hold
# several Developer ID certificates (an expired one, say) unambiguous.
cleanmac_signing_identity() {
    security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' |
        head -1
}

# The team id from the parenthesised suffix of that identity, e.g. TEAMID123.
cleanmac_team_id() {
    security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/.*"Developer ID Application: .* (\([A-Z0-9]*\))".*/\1/p' |
        head -1
}

# How many codesigning identities of any kind the keychain holds. Used only for
# diagnostics: "0 valid identities" means no certificate at all, while a nonzero
# count with no Developer ID match means the wrong certificate type is installed
# — two different problems with two different fixes.
#
# No `\?` here: that is a GNU sed extension, and macOS ships BSD sed, where it
# is a literal question mark that silently matches nothing.
cleanmac_identity_count() {
    security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/^[[:space:]]*\([0-9][0-9]*\) valid identities.*/\1/p' |
        head -1
}

# True when the active developer dir is Command Line Tools rather than a full
# Xcode. CLT ships xcodebuild but cannot archive or export a signed app, and it
# produces the most confusing downstream errors of any misconfiguration here.
cleanmac_has_full_xcode() {
    local dev_dir
    dev_dir="$(xcode-select -p 2>/dev/null || true)"
    [ -n "$dev_dir" ] || return 1
    case "$dev_dir" in
        *CommandLineTools*) return 1 ;;
        *) return 0 ;;
    esac
}

cleanmac_dev_dir() {
    xcode-select -p 2>/dev/null || echo "(none)"
}

# Explain, concretely, what this machine is missing. Written for a human who has
# never signed a Mac app before: every branch names the command that fixes it.
cleanmac_report() {
    local team identity count
    team="$(cleanmac_team_id)"
    identity="$(cleanmac_signing_identity)"
    count="$(cleanmac_identity_count)"

    if cleanmac_has_full_xcode; then
        echo "Xcode:              $(cleanmac_dev_dir) (full Xcode)"
    else
        echo "Xcode:              $(cleanmac_dev_dir) (Command Line Tools only)"
        echo "                    full Xcode is required to archive and notarize:"
        echo "                    sudo xcode-select -s /Applications/Xcode.app"
    fi

    if [ -n "$identity" ]; then
        echo "Signing identity:   ${identity}"
        echo "Team ID:            ${team:-<unparsed>}"
    else
        echo "Signing identity:   none"
        echo "Codesigning identities in keychain: ${count:-0}"
        if [ "${count:-0}" = "0" ]; then
            echo "                    No certificate at all. Create one in Xcode ->"
            echo "                    Settings -> Accounts -> Manage Certificates."
        else
            echo "                    Certificates exist but none is a"
            echo "                    'Developer ID Application' identity, which is the"
            echo "                    only type that can sign a distributable .app."
        fi
        echo "                    Local Debug builds still work: they sign ad-hoc."
    fi

    [ -n "$identity" ]
}

# Only run the report when executed directly, not when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        --identity) cleanmac_signing_identity ;;
        --report)   cleanmac_report ;;
        --count)    cleanmac_identity_count ;;
        --xcode)    cleanmac_has_full_xcode && echo yes || echo no ;;
        "")
            team="$(cleanmac_team_id)"
            [ -n "$team" ] && printf '%s\n' "$team"
            # Exit non-zero when nothing was found so callers can branch.
            [ -n "$team" ]
            ;;
        *)
            echo "usage: $(basename "$0") [--identity|--report|--count|--xcode]" >&2
            exit 2
            ;;
    esac
fi
