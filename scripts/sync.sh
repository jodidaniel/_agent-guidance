#!/usr/bin/env bash
set -euo pipefail
#
# sync.sh — Sync the managed AGENTS.md to every repo in the organization.
#
# Discovers repos dynamically via `gh repo list`. For each repo the script:
#   1. Reads the repo's .agents-sync.yml (sections to include)
#   2. Builds the managed portion via build-agents-md.sh
#   3. Preserves any content below "## Repo-specific additions"
#   4. Opens (or updates) a PR if the managed content has changed
#
# Requirements: gh (GitHub CLI, authenticated), yq, git
# Usage:        ./scripts/sync.sh [--dry-run]
#
# Environment:
#   GITHUB_REPOSITORY_OWNER — org/user to scan (auto-set in GitHub Actions)
#   SYNC_SELF_REPO          — this repo's name, excluded from sync (default: _agent-guidance)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build-agents-md.sh"
MARKER="## Repo-specific additions"
BRANCH_NAME="agents-md-sync/update"
DRY_RUN=false
WORK_DIR=$(mktemp -d)
SELF_REPO="${SYNC_SELF_REPO:-_agent-guidance}"

# Resolve the org/user name: prefer env var, fall back to git remote.
if [[ -n "${GITHUB_REPOSITORY_OWNER:-}" ]]; then
    ORG="$GITHUB_REPOSITORY_OWNER"
else
    ORG=$(git remote get-url origin | sed -E 's#.*/([^/]+)/[^/]+\.git$#\1#; s#.*/([^/]+)/[^/]+$#\1#')
fi

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

trap 'rm -rf "$WORK_DIR"' EXIT

# ── Helpers ────────────────────────────────────────────────────────────────

log()  { echo "  $*"; }
fail() { echo "  ERROR: $*"; }

FAIL_COUNT=0
OK_COUNT=0
SKIP_COUNT=0

read_sections_from_yaml() {
    yq -r '.sections // [] | .[]' 2>/dev/null || true
}

# ── Discover repos ─────────────────────────────────────────────────────────

echo "Scanning repos for: $ORG (excluding $SELF_REPO)"
echo ""

# Capture repo list via command substitution so failures propagate under set -e.
# Process substitution <(...) silently swallows errors, which would cause the
# script to report success while doing nothing.
repo_list_raw=$(
    gh repo list "$ORG" \
        --no-archived \
        --source \
        --json nameWithOwner \
        --limit 1000 \
        --jq '.[].nameWithOwner'
)

mapfile -t REPOS < <(echo "$repo_list_raw" | grep -v "/${SELF_REPO}$" | sort)

if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "No repos found in $ORG — nothing to sync."
    exit 0
fi

echo "Found ${#REPOS[@]} repo(s):"
printf '  %s\n' "${REPOS[@]}"
echo ""

# ── Main loop ──────────────────────────────────────────────────────────────

for repo_name in "${REPOS[@]}"; do
    echo "=== $repo_name ==="

    # ── Resolve sections from repo's .agents-sync.yml ──────────────────

    sections=()

    remote_yaml=$(gh api "repos/$repo_name/contents/.agents-sync.yml" \
        --jq '.content' 2>/dev/null || true)

    if [[ -n "$remote_yaml" ]]; then
        while IFS= read -r s; do
            [[ -n "$s" ]] && sections+=("$s")
        done < <(echo "$remote_yaml" | base64 -d | read_sections_from_yaml)
    fi

    log "Sections: ${sections[*]:-none}"

    # ── Build managed content ──────────────────────────────────────────

    managed_content=$("$BUILD_SCRIPT" "${sections[@]}")

    # ── Clone & prepare ────────────────────────────────────────────────

    repo_dir="$WORK_DIR/$(echo "$repo_name" | tr '/' '_')"
    if ! gh repo clone "$repo_name" "$repo_dir" -- --depth 1; then
        fail "clone failed for $repo_name"
        ((FAIL_COUNT++)) || true
        continue
    fi
    cd "$repo_dir"

    # Configure git identity for commits (not inherited in fresh clones)
    git config user.name "agents-md-sync[bot]"
    git config user.email "agents-md-sync[bot]@users.noreply.github.com"

    # Embed token in remote URL so git push can authenticate in CI (no TTY).
    # gh-repo-clone sets an HTTPS remote but does not persist credentials for
    # subsequent git operations, causing:
    #   fatal: could not read Username for 'https://github.com': No such device or address
    if [[ -n "${GH_TOKEN:-}" ]]; then
        git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${repo_name}.git"
    fi

    # ── Preserve repo-specific content ─────────────────────────────────

    repo_specific=""
    existing_prefix=""
    if [[ -f AGENTS.md ]]; then
        if grep -qF "$MARKER" AGENTS.md; then
            repo_specific=$(sed -n "/^${MARKER}/,\$p" AGENTS.md)
        else
            # Existing AGENTS.md without marker — preserve entire content above
            # the marker heading, with managed content added below it
            existing_prefix="$(cat AGENTS.md)"
        fi
    fi

    if [[ -z "$repo_specific" && -z "$existing_prefix" ]]; then
        repo_specific="$(printf '%s\n\n%s\n' \
            "$MARKER" \
            "<!-- Add your repo-specific agent guidance below this line -->")"
    fi

    # ── Assemble ───────────────────────────────────────────────────────

    if [[ -n "$existing_prefix" ]]; then
        # No-marker case: existing content on top, marker, then managed content
        new_agents_md="$(printf '%s\n\n%s\n\n%s' "$existing_prefix" "$MARKER" "$managed_content")"
    else
        new_agents_md="$(printf '%s%s\n' "$managed_content" "$repo_specific")"
    fi

    # ── Diff check ─────────────────────────────────────────────────────

    if [[ -f AGENTS.md ]] && diff -q <(echo "$new_agents_md") AGENTS.md &>/dev/null; then
        log "Up to date — skipping."
        ((SKIP_COUNT++)) || true
        cd "$REPO_ROOT"
        continue
    fi

    if $DRY_RUN; then
        log "[DRY RUN] Would update AGENTS.md"
        ((SKIP_COUNT++)) || true
        cd "$REPO_ROOT"
        continue
    fi

    # ── Branch, commit, push ───────────────────────────────────────────

    git checkout -b "$BRANCH_NAME" 2>/dev/null || git checkout "$BRANCH_NAME" 2>/dev/null || {
        fail "could not create branch in $repo_name"
        ((FAIL_COUNT++)) || true
        cd "$REPO_ROOT"; continue
    }

    echo "$new_agents_md" > AGENTS.md
    git add AGENTS.md
    git commit -m "chore: sync AGENTS.md from _agent-guidance

Sections: ${sections[*]:-none}
Managed content updated by the central _agent-guidance repository." || {
        log "Nothing to commit."
        ((SKIP_COUNT++)) || true
        cd "$REPO_ROOT"; continue
    }

    if ! git push -u origin "$BRANCH_NAME"; then
        fail "push failed for $repo_name"
        ((FAIL_COUNT++)) || true
        cd "$REPO_ROOT"; continue
    fi

    # ── Open or update PR ──────────────────────────────────────────────

    existing_pr=$(gh pr list --head "$BRANCH_NAME" --json number \
        --jq '.[0].number // empty' 2>/dev/null || true)

    if [[ -n "$existing_pr" ]]; then
        log "PR #$existing_pr already exists — branch updated."
        ((OK_COUNT++)) || true
    else
        if gh pr create \
            --title "chore: sync AGENTS.md from _agent-guidance" \
            --body "$(cat <<EOF
Automated sync of the managed portion of \`AGENTS.md\` from the central
[\`_agent-guidance\`](https://github.com/${ORG}/${SELF_REPO}) repository.

**Sections included:** ${sections[*]:-none}

Content below \`## Repo-specific additions\` has been preserved.
EOF
)"; then
            log "PR created."
            ((OK_COUNT++)) || true
        else
            fail "PR creation failed for $repo_name"
            ((FAIL_COUNT++)) || true
        fi
    fi

    cd "$REPO_ROOT"
done

echo ""
echo "=== Sync complete: $OK_COUNT synced, $SKIP_COUNT skipped, $FAIL_COUNT failed ==="

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
