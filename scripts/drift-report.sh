#!/usr/bin/env bash
set -euo pipefail
#
# drift-report.sh — Generate a markdown drift-report dashboard.
#
# Discovers all repos in the organization dynamically and checks:
#   • Whether AGENTS.md exists
#   • Whether the managed section matches what we would generate
#   • Whether the repo-specific marker header is present
#   • Whether a sync PR is currently open
#   • Which sections the repo requests
#
# Output: drift-report.md in the repository root.
#
# Requirements: gh (GitHub CLI, authenticated), yq
#
# Environment:
#   GITHUB_REPOSITORY_OWNER — org/user to scan (auto-set in GitHub Actions)
#   SYNC_SELF_REPO          — this repo's name, excluded from report (default: _agent-guidance)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build-agents-md.sh"
OUTPUT_FILE="$REPO_ROOT/drift-report.md"
MARKER="## Repo-specific additions"
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M UTC")
BRANCH_NAME="agents-md-sync/update"
SELF_REPO="${SYNC_SELF_REPO:-_agent-guidance}"

# Resolve the org/user name.
if [[ -n "${GITHUB_REPOSITORY_OWNER:-}" ]]; then
    ORG="$GITHUB_REPOSITORY_OWNER"
else
    ORG=$(git remote get-url origin | sed -E 's#.*/([^/]+)/[^/]+\.git$#\1#; s#.*/([^/]+)/[^/]+$#\1#')
fi

# ── Helpers ────────────────────────────────────────────────────────────────

strip_volatile() {
    grep -v '^<!-- Last synced:' || true
}

fetch_file_content() {
    local repo="$1" path="$2"
    local encoded
    encoded=$(gh api "repos/$repo/contents/$path" --jq '.content' 2>/dev/null || true)
    [[ -n "$encoded" ]] && echo "$encoded" | base64 -d 2>/dev/null || true
}

# ── Discover repos ─────────────────────────────────────────────────────────

echo "Scanning repos for: $ORG (excluding $SELF_REPO)"

mapfile -t REPOS < <(
    gh repo list "$ORG" \
        --no-archived \
        --source \
        --json nameWithOwner \
        --limit 1000 \
        --jq '.[].nameWithOwner' \
    | grep -v "/${SELF_REPO}$" \
    | sort
)

echo "Found ${#REPOS[@]} repo(s)"
echo ""

# ── Build report ───────────────────────────────────────────────────────────

{
    echo "# AGENTS.md Drift Report"
    echo ""
    echo "> Last generated: $TIMESTAMP"
    echo "> Organization: \`$ORG\` — ${#REPOS[@]} repo(s) scanned"
    echo ""
    echo "| Repository | Status | Has marker | Open PR | Sections | Notes |"
    echo "|------------|--------|------------|---------|----------|-------|"
} > "$OUTPUT_FILE"

if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "| *(no repos found)* | — | — | — | — | Check org name and gh auth |" >> "$OUTPUT_FILE"
fi

for repo_name in "${REPOS[@]}"; do
    echo "  Checking $repo_name ..."

    status="unknown"
    has_marker="—"
    open_pr="none"
    sections_display="—"
    notes=""

    # ── Resolve sections from repo's .agents-sync.yml ──────────────────

    sections=()

    remote_yaml=$(fetch_file_content "$repo_name" ".agents-sync.yml")
    if [[ -n "$remote_yaml" ]]; then
        while IFS= read -r s; do
            [[ -n "$s" ]] && sections+=("$s")
        done < <(echo "$remote_yaml" | yq -r '.sections // [] | .[]' 2>/dev/null || true)
    fi

    sections_display="${sections[*]:-none}"

    # ── Fetch current AGENTS.md ────────────────────────────────────────

    current_agents=$(fetch_file_content "$repo_name" "AGENTS.md")

    if [[ -z "$current_agents" ]]; then
        status="**no-agents-md**"
        notes="AGENTS.md not found in repo"
    else
        # Check marker header
        if echo "$current_agents" | grep -qF "$MARKER"; then
            has_marker="yes"
        else
            has_marker="no"
        fi

        # Build expected managed content and compare
        expected=$("$BUILD_SCRIPT" "${sections[@]}" 2>/dev/null || true)

        if [[ -z "$expected" ]]; then
            status="**update-failed**"
            notes="Could not build expected content"
        else
            # Extract managed section from current file
            if [[ "$has_marker" == "yes" ]]; then
                current_managed=$(echo "$current_agents" | sed "/$MARKER/,\$d")
            else
                current_managed="$current_agents"
            fi

            expected_clean=$(echo "$expected" | strip_volatile)
            current_clean=$(echo "$current_managed" | strip_volatile)

            if diff -q <(echo "$expected_clean") <(echo "$current_clean") &>/dev/null; then
                status="**up-to-date**"
            else
                status="**drift-detected**"
            fi
        fi
    fi

    # ── Check for open sync PR ─────────────────────────────────────────

    pr_number=$(gh pr list --repo "$repo_name" --head "$BRANCH_NAME" \
        --json number --jq '.[0].number' 2>/dev/null || true)

    if [[ -n "$pr_number" ]]; then
        open_pr="#$pr_number"
        [[ "$status" == "**drift-detected**" ]] && status="**pr-open**"
    fi

    # ── Write row ──────────────────────────────────────────────────────

    echo "| \`$repo_name\` | $status | $has_marker | $open_pr | $sections_display | $notes |" >> "$OUTPUT_FILE"
done

# ── Footer ─────────────────────────────────────────────────────────────────

{
    echo ""
    echo "---"
    echo ""
    echo "**Status legend**"
    echo ""
    echo "| Status | Meaning |"
    echo "|--------|---------|"
    echo "| **up-to-date** | Managed section matches the expected output |"
    echo "| **drift-detected** | Managed section has diverged — needs sync |"
    echo "| **pr-open** | A sync PR is already open for this repo |"
    echo "| **no-agents-md** | Repo does not have an AGENTS.md yet |"
    echo "| **update-failed** | An error occurred while checking this repo |"
} >> "$OUTPUT_FILE"

echo ""
echo "Drift report written to $OUTPUT_FILE"
