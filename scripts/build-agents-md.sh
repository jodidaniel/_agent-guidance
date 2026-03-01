#!/usr/bin/env bash
set -euo pipefail
#
# build-agents-md.sh — Assemble a complete AGENTS.md from base + requested sections.
#
# Usage:  ./scripts/build-agents-md.sh [section ...]
# Example: ./scripts/build-agents-md.sh python docker
#
# Writes the managed portion of AGENTS.md to stdout.
# The caller is responsible for appending the repo-specific section.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_FILE="$REPO_ROOT/agents-md/base.md"
SECTIONS_DIR="$REPO_ROOT/agents-md/sections"
SECTIONS=("${@}")

# ── Managed-section header (machine-readable markers) ──────────────────────
echo "<!-- BEGIN MANAGED SECTION — DO NOT EDIT ABOVE \"## Repo-specific additions\" -->"
echo "<!-- Source: _agent-guidance -->"
echo "<!-- Sections: ${SECTIONS[*]:-none} -->"
echo ""

# ── Base content ───────────────────────────────────────────────────────────
cat "$BASE_FILE"

# ── Requested language / tooling sections ──────────────────────────────────
for section in "${SECTIONS[@]}"; do
    section_file="$SECTIONS_DIR/${section}.md"
    if [[ -f "$section_file" ]]; then
        echo ""
        cat "$section_file"
    else
        echo ""
        echo "<!-- WARNING: unknown section '${section}' — no file at sections/${section}.md -->"
    fi
done

echo ""
echo "<!-- END MANAGED SECTION -->"
echo ""
