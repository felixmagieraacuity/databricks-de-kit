#!/usr/bin/env bash
set -euo pipefail

echo "=== Databricks DE Claude Code Kit Installer ==="

# Step 1: prereqs
missing=()
command -v uv >/dev/null 2>&1 || missing+=("uv (https://docs.astral.sh/uv/)")
command -v databricks >/dev/null 2>&1 || missing+=("Databricks CLI (https://docs.databricks.com/dev-tools/cli/install.html)")
command -v claude >/dev/null 2>&1 || missing+=("Claude Code CLI (https://claude.ai/code)")

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing prerequisites:"
    for m in "${missing[@]}"; do echo "  - $m"; done
    echo "Install missing tools and re-run. Continuing anyway..."
fi

# Step 2: Databricks Agent Skills + MCP (replaces the deprecated ai-dev-kit)
echo "[1/4] Installing Databricks Agent Skills + MCP server..."
databricks aitools install || \
    echo "databricks aitools install failed. Install manually: https://github.com/databricks/databricks-agent-skills"

# Step 3: kit files
echo "[2/4] Installing DE Kit skills, commands, hooks, and CLAUDE.md..."
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$(pwd)"

mkdir -p "$DEST/.claude/skills" && cp -r "$KIT_DIR/skills/"* "$DEST/.claude/skills/" && echo "  Skills installed ($(ls -d "$KIT_DIR/skills/"*/ | wc -l) skill dirs)"
mkdir -p "$DEST/.claude/commands" && cp "$KIT_DIR/.claude/commands/"*.md "$DEST/.claude/commands/" && echo "  Commands installed"
mkdir -p "$DEST/.claude/agents" && cp "$KIT_DIR/agents/"*.md "$DEST/.claude/agents/" && echo "  Agents installed"
mkdir -p "$DEST/scripts/hooks" && cp "$KIT_DIR/hooks/"*.py "$DEST/scripts/hooks/" && chmod +x "$DEST/scripts/hooks/"*.py && echo "  Hooks installed"

if [ -f "$DEST/CLAUDE.md" ]; then
    cp "$DEST/CLAUDE.md" "$DEST/CLAUDE.md.backup"
    echo "  Existing CLAUDE.md backed up"
fi
cp "$KIT_DIR/.claude/CLAUDE.md" "$DEST/CLAUDE.md" && echo "  CLAUDE.md installed"

if [ ! -f "$DEST/.env.example" ]; then
    cp "$KIT_DIR/.env.example" "$DEST/.env.example" && echo "  .env.example created"
fi

# Step 4: auth
echo "[3/4] Databricks authentication..."
echo "  To authenticate run: databricks auth login --host \$DATABRICKS_HOST"
read -rp "  Run databricks auth login now? (y/N): " auth
if [[ "$auth" =~ ^[Yy]$ ]]; then
    databricks auth login
fi

echo "[4/4] Done!"
cat <<EOF

What was installed:
  - Databricks Agent Skills + MCP server (via databricks aitools install)
  - 4 custom skills: bronze_ingestion, silver_transformation, spark_patterns, databricks_quality_auditor
  - 3 slash commands: /de:scaffold-pipeline, /de:inspect-generate-validate, /de:dbx-debug-job
  - 2 autonomous agents: databricks-medallion-scaffolder, databricks-job-debugger
  - 4 hooks: pre_commit_guard, sqlfluff_guard, extract_learnings, destructive_op_guard
  - CLAUDE.md template

Next steps:
  1. Fill in .env.example with your workspace details
  2. Wire hooks in .claude/settings.json (see README.md)
  3. Run: claude code
EOF
