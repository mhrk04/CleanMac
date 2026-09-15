#!/usr/bin/env bash
#
# setup.sh -- one-time contributor bootstrap for a fresh clone.
#
# Git cannot version .git/config, so the repo's local hooks path and the
# commit-message template have to be wired up per clone. This script does that
# and is idempotent -- safe to run again any time.
#
# Usage:
#   bash scripts/setup.sh        # or: make setup
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# 1. Conventional-commit hook (committed under .githooks/).
git config core.hooksPath .githooks
log "hooks path -> .githooks (commit-msg enforces Conventional Commits)"

# 2. Commit-message template.
git config commit.template .gitmessage
log "commit template -> .gitmessage"

# 3. GPG signing. Only enabled here if the machine actually has a secret key,
#    so a contributor without one is not blocked from committing. Detection is
#    best-effort: use the git-configured key if set, else the first secret key.
if command -v gpg >/dev/null 2>&1; then
    signingkey="$(git config --get user.signingkey || true)"
    if [ -z "$signingkey" ]; then
        signingkey="$(gpg --list-secret-keys --keyid-format=long 2>/dev/null \
            | awk '/^sec/ { split($2, a, "/"); print a[2]; exit }')"
    fi
    if [ -n "$signingkey" ]; then
        git config user.signingkey "$signingkey"
        git config commit.gpgsign true
        git config gpg.program "$(command -v gpg)"
        log "GPG signing enabled with key ${signingkey}"
    else
        log "no GPG secret key found -- commit signing left off."
        log "  create one, then: git config user.signingkey <KEYID> && git config commit.gpgsign true"
    fi
else
    log "gpg not installed -- commit signing left off (brew install gnupg)."
fi

log "setup complete."
