#!/usr/bin/env bash
set -euo pipefail
#
# sync.sh — Sync the managed AGENTS.md to every repo listed in repos.yml.
#
# For each repo the script:
#   1. Reads the repo's .agents-sync.yml (or falls back to defaults in repos.yml)
#   2. Builds the managed portion via build-agents-md.sh
#   3. Preserves any content below "## Repo-specific additions"
#   4. Opens (or updates) a PR if the managed content has changed
#
# Requirements: gh (GitHub CLI, authenticated), yq, git
# Usage:        ./scripts/sync.sh [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOS_FILE="$REPO_ROOT/repos.yml"
BUILD_SCRIPT="$SCRIPT_DIR/build-agents-md.sh"
MARKER="## Repo-specific additions"
BRANCH_NAME="agents-md-sync/update"
DRY_RUN=false
WORK_DIR=$(mktemp -d)

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

trap 'rm -rf "$WORK_DIR"' EXIT

# ── Helpers ────────────────────────────────────────────────────────────────

log()  { echo "  $*"; }
fail() { echo "  ERROR: $*"; }

read_sections_from_yaml() {
    # Read sections array from a YAML string on stdin.
    yq -r '.sections // [] | .[]' 2>/dev/null || true
}

# ── Main loop ──────────────────────────────────────────────────────────────

repo_count=$(yq '.repos | length' "$REPOS_FILE")

if [[ "$repo_count" -eq 0 ]]; then
    echo "repos.yml has no entries — nothing to sync."
    exit 0
fi

for ((i = 0; i < repo_count; i++)); do
    repo_name=$(yq -r ".repos[$i].name" "$REPOS_FILE")
    echo "=== $repo_name ==="

    # ── Resolve sections ───────────────────────────────────────────────

    sections=()

    # Try the repo's own .agents-sync.yml first (via GitHub API).
    remote_yaml=$(gh api "repos/$repo_name/contents/.agents-sync.yml" \
        --jq '.content' 2>/dev/null || true)

    if [[ -n "$remote_yaml" ]]; then
        while IFS= read -r s; do
            [[ -n "$s" ]] && sections+=("$s")
        done < <(echo "$remote_yaml" | base64 -d | read_sections_from_yaml)
    fi

    # Fall back to default_sections in repos.yml.
    if [[ ${#sections[@]} -eq 0 ]]; then
        while IFS= read -r s; do
            [[ -n "$s" ]] && sections+=("$s")
        done < <(yq -r ".repos[$i].default_sections // [] | .[]" "$REPOS_FILE" 2>/dev/null)
    fi

    log "Sections: ${sections[*]:-none}"

    # ── Build managed content ──────────────────────────────────────────

    managed_content=$("$BUILD_SCRIPT" "${sections[@]}")

    # ── Clone & prepare ────────────────────────────────────────────────

    repo_dir="$WORK_DIR/$(echo "$repo_name" | tr '/' '_')"
    gh repo clone "$repo_name" "$repo_dir" -- --depth 1 2>/dev/null || {
        fail "clone failed"; continue
    }
    cd "$repo_dir"

    # ── Preserve repo-specific content ─────────────────────────────────

    repo_specific=""
    if [[ -f AGENTS.md ]] && grep -qF "$MARKER" AGENTS.md; then
        repo_specific=$(sed -n "/^${MARKER}/,\$p" AGENTS.md)
    fi

    if [[ -z "$repo_specific" ]]; then
        repo_specific="$(printf '%s\n\n%s\n' \
            "$MARKER" \
            "<!-- Add your repo-specific agent guidance below this line -->")"
    fi

    # ── Assemble ───────────────────────────────────────────────────────

    new_agents_md="$(printf '%s%s\n' "$managed_content" "$repo_specific")"

    # ── Diff check ─────────────────────────────────────────────────────

    if [[ -f AGENTS.md ]] && diff -q <(echo "$new_agents_md") AGENTS.md &>/dev/null; then
        log "Up to date — skipping."
        cd "$REPO_ROOT"
        continue
    fi

    if $DRY_RUN; then
        log "[DRY RUN] Would update AGENTS.md"
        cd "$REPO_ROOT"
        continue
    fi

    # ── Branch, commit, push ───────────────────────────────────────────

    git checkout -b "$BRANCH_NAME" 2>/dev/null || git checkout "$BRANCH_NAME" 2>/dev/null || {
        fail "could not create branch"; cd "$REPO_ROOT"; continue
    }

    echo "$new_agents_md" > AGENTS.md
    git add AGENTS.md
    git commit -m "chore: sync AGENTS.md from _agent-guidance

Sections: ${sections[*]:-none}
Managed content updated by the central _agent-guidance repository." || {
        log "Nothing to commit."; cd "$REPO_ROOT"; continue
    }

    git push -u origin "$BRANCH_NAME" 2>/dev/null || {
        fail "push failed"; cd "$REPO_ROOT"; continue
    }

    # ── Open or update PR ──────────────────────────────────────────────

    existing_pr=$(gh pr list --head "$BRANCH_NAME" --json number \
        --jq '.[0].number' 2>/dev/null || true)

    if [[ -n "$existing_pr" ]]; then
        log "PR #$existing_pr already exists — branch updated."
    else
        gh pr create \
            --title "chore: sync AGENTS.md from _agent-guidance" \
            --body "$(cat <<EOF
Automated sync of the managed portion of \`AGENTS.md\` from the central
[\`_agent-guidance\`] repository.

**Sections included:** ${sections[*]:-none}

Content below \`## Repo-specific additions\` has been preserved.
EOF
)" && log "PR created." || fail "PR creation failed"
    fi

    cd "$REPO_ROOT"
done

echo ""
echo "=== Sync complete ==="
