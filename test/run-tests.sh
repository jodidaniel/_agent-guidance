#!/usr/bin/env bash
set -euo pipefail
#
# run-tests.sh — Integration tests for the sync and drift-report scripts.
#
# Creates mock git repos and a fake `gh` CLI to validate the full pipeline
# without needing GitHub access.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0

trap 'rm -rf "$TEST_DIR"' EXIT

# Ensure git identity is configured (CI runners may not have this set globally).
if ! git config --global user.name &>/dev/null; then
    git config --global user.name "test-runner"
fi
if ! git config --global user.email &>/dev/null; then
    git config --global user.email "test@localhost"
fi

# ── Helpers ────────────────────────────────────────────────────────────────

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
assert_contains() {
    if grep -qF "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 — expected '$2' in $1"; fi
}
assert_not_contains() {
    if grep -qF "$2" "$1" 2>/dev/null; then fail "$3 — did not expect '$2' in $1"; else pass "$3"; fi
}

# ── Set up mock repos as bare git repos ────────────────────────────────────

setup_mock_repos() {
    echo "Setting up mock repos..."

    # Disable commit signing for test repos (CI environment may enforce signing)
    GIT_NOSIGN=(-c commit.gpgsign=false -c tag.gpgsign=false)

    # Mock repo 1: has .agents-sync.yml requesting python + docker
    local repo1_bare="$TEST_DIR/bare/testorg_repo-with-sync"
    local repo1_work="$TEST_DIR/work/repo-with-sync"
    mkdir -p "$repo1_bare" "$repo1_work"
    git init --bare --initial-branch=main "$repo1_bare" >/dev/null 2>&1
    git init --initial-branch=main "$repo1_work" >/dev/null 2>&1
    cd "$repo1_work"
    git config commit.gpgsign false
    git remote add origin "$repo1_bare"
    cat > .agents-sync.yml <<'YAML'
sections:
  - python
  - docker
YAML
    git add .agents-sync.yml
    git commit -m "init" >/dev/null 2>&1
    git push origin HEAD:main >/dev/null 2>&1

    # Mock repo 2: no .agents-sync.yml, no AGENTS.md
    local repo2_bare="$TEST_DIR/bare/testorg_repo-no-sync"
    local repo2_work="$TEST_DIR/work/repo-no-sync"
    mkdir -p "$repo2_bare" "$repo2_work"
    git init --bare --initial-branch=main "$repo2_bare" >/dev/null 2>&1
    git init --initial-branch=main "$repo2_work" >/dev/null 2>&1
    cd "$repo2_work"
    git config commit.gpgsign false
    git remote add origin "$repo2_bare"
    echo "# hello" > README.md
    git add README.md
    git commit -m "init" >/dev/null 2>&1
    git push origin HEAD:main >/dev/null 2>&1

    # Mock repo 3: has existing AGENTS.md with repo-specific content
    local repo3_bare="$TEST_DIR/bare/testorg_repo-with-existing"
    local repo3_work="$TEST_DIR/work/repo-with-existing"
    mkdir -p "$repo3_bare" "$repo3_work"
    git init --bare --initial-branch=main "$repo3_bare" >/dev/null 2>&1
    git init --initial-branch=main "$repo3_work" >/dev/null 2>&1
    cd "$repo3_work"
    git config commit.gpgsign false
    git remote add origin "$repo3_bare"
    cat > .agents-sync.yml <<'YAML'
sections:
  - go
YAML
    cat > AGENTS.md <<'MD'
# old managed stuff
This will be overwritten.

## Repo-specific additions

Keep this custom content!
Do not delete me.
MD
    git add .agents-sync.yml AGENTS.md
    git commit -m "init" >/dev/null 2>&1
    git push origin HEAD:main >/dev/null 2>&1

    cd "$REPO_ROOT"
}

# ── Create mock gh CLI ─────────────────────────────────────────────────────

create_mock_gh() {
    local gh_mock="$TEST_DIR/bin/gh"
    mkdir -p "$TEST_DIR/bin"

    cat > "$gh_mock" <<'GHSCRIPT'
#!/usr/bin/env bash
# Mock gh CLI for testing.
# Simulates gh repo list, gh repo clone, gh api, and gh pr.

# Parse all arguments to extract common flags
parse_jq_filter() {
    local args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
        if [[ "${args[$i]}" == "--jq" ]]; then
            echo "${args[$((i+1))]}"
            return
        fi
    done
}

case "$1" in
    repo)
        case "$2" in
            list)
                shift 2  # remove "repo list"
                # Raw JSON data
                json='[
                  {"nameWithOwner":"testorg/repo-with-sync"},
                  {"nameWithOwner":"testorg/repo-no-sync"},
                  {"nameWithOwner":"testorg/repo-with-existing"},
                  {"nameWithOwner":"testorg/_agent-guidance"}
                ]'
                # Find --jq filter in remaining args
                jq_filter=$(parse_jq_filter "$@")
                if [[ -n "$jq_filter" ]]; then
                    echo "$json" | jq -r "$jq_filter"
                else
                    echo "$json"
                fi
                ;;
            clone)
                # Clone from our bare repos
                repo_slug=$(echo "$3" | tr '/' '_')
                dest="${4}"
                shift 4
                # Strip -- separator if present
                [[ "${1:-}" == "--" ]] && shift
                bare_path="${MOCK_BARE_DIR}/${repo_slug}"
                if [[ -d "$bare_path" ]]; then
                    git clone "$bare_path" "$dest" "$@" 2>/dev/null
                    git -C "$dest" config commit.gpgsign false 2>/dev/null || true
                else
                    echo "ERROR: mock repo $bare_path not found" >&2
                    exit 1
                fi
                ;;
        esac
        ;;
    api)
        shift  # remove 'api'
        api_path="$1"
        shift
        jq_filter=$(parse_jq_filter "$@")

        # repos/{owner}/{repo}/contents/{path}
        if [[ "$api_path" =~ repos/([^/]+)/([^/]+)/contents/(.+) ]]; then
            owner="${BASH_REMATCH[1]}"
            repo="${BASH_REMATCH[2]}"
            file_path="${BASH_REMATCH[3]}"
            repo_slug="${owner}_${repo}"
            bare_path="${MOCK_BARE_DIR}/${repo_slug}"

            if [[ -d "$bare_path" ]]; then
                content=$(git -C "$bare_path" show "main:$file_path" 2>/dev/null || true)
                if [[ -n "$content" ]]; then
                    encoded=$(echo "$content" | base64 -w 0)
                    json="{\"content\": \"$encoded\"}"
                    if [[ -n "$jq_filter" ]]; then
                        echo "$json" | jq -r "$jq_filter"
                    else
                        echo "$json"
                    fi
                else
                    exit 1
                fi
            else
                exit 1
            fi
        fi
        ;;
    pr)
        case "$2" in
            list)
                # Parse --jq from remaining args
                shift 2
                jq_filter=$(parse_jq_filter "$@")
                json='[]'
                if [[ -n "$jq_filter" ]]; then
                    echo "$json" | jq -r "$jq_filter"
                else
                    echo "$json"
                fi
                ;;
            create) echo "https://github.com/mock/pr/1" ;;
        esac
        ;;
esac
GHSCRIPT

    chmod +x "$gh_mock"
}

# ── Test 1: build-agents-md.sh ────────────────────────────────────────────

test_build_script() {
    echo ""
    echo "=== Test: build-agents-md.sh ==="

    local output
    output=$("$REPO_ROOT/scripts/build-agents-md.sh" python docker)

    echo "$output" > "$TEST_DIR/build-output.md"

    assert_contains "$TEST_DIR/build-output.md" "BEGIN MANAGED SECTION" "has managed section start marker"
    assert_contains "$TEST_DIR/build-output.md" "END MANAGED SECTION" "has managed section end marker"
    assert_contains "$TEST_DIR/build-output.md" "Sections: python docker" "lists sections in header"
    assert_contains "$TEST_DIR/build-output.md" "## General guidelines" "includes base content"
    assert_contains "$TEST_DIR/build-output.md" "## Python" "includes python section"
    assert_contains "$TEST_DIR/build-output.md" "## Docker" "includes docker section"
    assert_not_contains "$TEST_DIR/build-output.md" "## Go" "does not include unrequested section"

    # Test with no sections
    output=$("$REPO_ROOT/scripts/build-agents-md.sh")
    echo "$output" > "$TEST_DIR/build-no-sections.md"
    assert_contains "$TEST_DIR/build-no-sections.md" "Sections: none" "reports none when no sections"
    assert_contains "$TEST_DIR/build-no-sections.md" "## General guidelines" "still includes base"

    # Test with unknown section
    output=$("$REPO_ROOT/scripts/build-agents-md.sh" python bogus)
    echo "$output" > "$TEST_DIR/build-unknown.md"
    assert_contains "$TEST_DIR/build-unknown.md" "WARNING: unknown section 'bogus'" "warns on unknown section"
    assert_contains "$TEST_DIR/build-unknown.md" "## Python" "still includes valid section"
}

# ── Test 2: sync.sh --dry-run ─────────────────────────────────────────────

test_sync_dry_run() {
    echo ""
    echo "=== Test: sync.sh --dry-run ==="

    local output
    output=$(
        GITHUB_REPOSITORY_OWNER=testorg \
        MOCK_BARE_DIR="$TEST_DIR/bare" \
        PATH="$TEST_DIR/bin:$PATH" \
        "$REPO_ROOT/scripts/sync.sh" --dry-run 2>&1
    ) || true

    echo "$output" > "$TEST_DIR/sync-output.txt"

    assert_contains "$TEST_DIR/sync-output.txt" "Scanning repos for: testorg" "scans correct org"
    assert_contains "$TEST_DIR/sync-output.txt" "repo-with-sync" "finds repo-with-sync"
    assert_contains "$TEST_DIR/sync-output.txt" "repo-no-sync" "finds repo-no-sync"
    assert_contains "$TEST_DIR/sync-output.txt" "repo-with-existing" "finds repo-with-existing"
    assert_not_contains "$TEST_DIR/sync-output.txt" "=== testorg/_agent-guidance ===" "excludes self repo"
    assert_contains "$TEST_DIR/sync-output.txt" "[DRY RUN]" "respects dry-run flag"
}

# ── Test 3: sync.sh full run ──────────────────────────────────────────────

test_sync_full() {
    echo ""
    echo "=== Test: sync.sh (full run) ==="

    local output
    output=$(
        GITHUB_REPOSITORY_OWNER=testorg \
        MOCK_BARE_DIR="$TEST_DIR/bare" \
        PATH="$TEST_DIR/bin:$PATH" \
        "$REPO_ROOT/scripts/sync.sh" 2>&1
    ) || true

    echo "$output" > "$TEST_DIR/sync-full-output.txt"

    # Check repo-with-sync got python + docker sections
    assert_contains "$TEST_DIR/sync-full-output.txt" "Sections: python docker" "repo-with-sync gets python docker"

    # Check repo-with-existing got go sections
    assert_contains "$TEST_DIR/sync-full-output.txt" "Sections: go" "repo-with-existing gets go"

    # Check repo-no-sync gets no sections
    assert_contains "$TEST_DIR/sync-full-output.txt" "Sections: none" "repo-no-sync gets no sections"

    # Verify repo-with-existing preserved repo-specific content
    local existing_bare="$TEST_DIR/bare/testorg_repo-with-existing"
    local verify_dir="$TEST_DIR/verify-existing"
    git clone "$existing_bare" "$verify_dir" -b agents-md-sync/update 2>/dev/null || {
        fail "repo-with-existing: sync branch not created"
        return
    }

    assert_contains "$verify_dir/AGENTS.md" "## Repo-specific additions" "repo-with-existing: marker header present"
    assert_contains "$verify_dir/AGENTS.md" "Keep this custom content!" "repo-with-existing: repo-specific content preserved"
    assert_contains "$verify_dir/AGENTS.md" "Do not delete me." "repo-with-existing: multi-line repo content preserved"
    assert_contains "$verify_dir/AGENTS.md" "## Go" "repo-with-existing: go section injected"
    assert_not_contains "$verify_dir/AGENTS.md" "old managed stuff" "repo-with-existing: old managed content replaced"

    # Verify repo-with-sync has correct AGENTS.md
    local sync_bare="$TEST_DIR/bare/testorg_repo-with-sync"
    local verify_sync="$TEST_DIR/verify-sync"
    git clone "$sync_bare" "$verify_sync" -b agents-md-sync/update 2>/dev/null || {
        fail "repo-with-sync: sync branch not created"
        return
    }

    assert_contains "$verify_sync/AGENTS.md" "## Python" "repo-with-sync: python section present"
    assert_contains "$verify_sync/AGENTS.md" "## Docker" "repo-with-sync: docker section present"
    assert_contains "$verify_sync/AGENTS.md" "## Repo-specific additions" "repo-with-sync: marker header added"

    # Verify summary line
    assert_contains "$TEST_DIR/sync-full-output.txt" "Sync complete:" "sync shows summary line"
    assert_contains "$TEST_DIR/sync-full-output.txt" "3 synced" "sync reports 3 synced"
    assert_contains "$TEST_DIR/sync-full-output.txt" "0 failed" "sync reports 0 failed"
}

# ── Test 3b: sync.sh exits non-zero on per-repo failure ───────────────

test_sync_failure_exit_code() {
    echo ""
    echo "=== Test: sync.sh (failure exit code) ==="

    # Create a mock gh that lists repos but clone always fails
    local gh_fail_mock="$TEST_DIR/bin-fail/gh"
    mkdir -p "$TEST_DIR/bin-fail"
    cat > "$gh_fail_mock" <<'GHSCRIPT'
#!/usr/bin/env bash
case "$1" in
    repo)
        case "$2" in
            list)
                jq_filter=""
                for arg in "$@"; do
                    if [[ "$prev" == "--jq" ]]; then jq_filter="$arg"; fi
                    prev="$arg"
                done
                json='[{"nameWithOwner":"testorg/some-repo"}]'
                if [[ -n "$jq_filter" ]]; then
                    echo "$json" | jq -r "$jq_filter"
                else
                    echo "$json"
                fi
                ;;
            clone)
                echo "ERROR: permission denied" >&2
                exit 1
                ;;
        esac
        ;;
esac
GHSCRIPT
    chmod +x "$gh_fail_mock"

    local exit_code=0
    GITHUB_REPOSITORY_OWNER=testorg \
    MOCK_BARE_DIR="$TEST_DIR/bare" \
    PATH="$TEST_DIR/bin-fail:$PATH" \
    "$REPO_ROOT/scripts/sync.sh" > "$TEST_DIR/sync-fail-output.txt" 2>&1 || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        pass "sync exits non-zero when repos fail"
    else
        fail "sync should exit non-zero when repos fail (got exit code 0)"
    fi

    assert_contains "$TEST_DIR/sync-fail-output.txt" "1 failed" "sync reports failure count"
}

# ── Test 4: drift-report.sh ───────────────────────────────────────────────

test_drift_report() {
    echo ""
    echo "=== Test: drift-report.sh ==="

    local output
    output=$(
        GITHUB_REPOSITORY_OWNER=testorg \
        MOCK_BARE_DIR="$TEST_DIR/bare" \
        PATH="$TEST_DIR/bin:$PATH" \
        "$REPO_ROOT/scripts/drift-report.sh" 2>&1
    ) || true

    echo "$output" > "$TEST_DIR/drift-output.txt"

    assert_contains "$REPO_ROOT/drift-report.md" "# AGENTS.md Drift Report" "drift report has title"
    assert_contains "$REPO_ROOT/drift-report.md" "repo-with-sync" "drift report includes repo-with-sync"
    assert_contains "$REPO_ROOT/drift-report.md" "repo-no-sync" "drift report includes repo-no-sync"
    assert_contains "$REPO_ROOT/drift-report.md" "repo-with-existing" "drift report includes repo-with-existing"
    assert_contains "$REPO_ROOT/drift-report.md" "Status legend" "drift report has legend"
    assert_contains "$REPO_ROOT/drift-report.md" "Organization:" "drift report shows org"
    assert_contains "$REPO_ROOT/drift-report.md" "3 repo(s) scanned" "drift report shows repo count"
    assert_not_contains "$REPO_ROOT/drift-report.md" "_agent-guidance" "drift report excludes self"
}

# ── Run all tests ──────────────────────────────────────────────────────────

echo "========================================="
echo "  Agent Guidance Integration Tests"
echo "========================================="

setup_mock_repos
create_mock_gh
test_build_script
test_sync_dry_run
test_sync_full
test_sync_failure_exit_code
test_drift_report

echo ""
echo "========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
