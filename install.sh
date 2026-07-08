#!/usr/bin/env bash
# Databricks DE Claude Code Kit — Mac/Linux installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/felixmagieraacuity/databricks-de-kit/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --scope project|team|global
#
# Safe to run from a piped curl (no local script directory required) and
# safe to run from a local clone (reuses the local files, no network clone).
set -euo pipefail

echo "=== Databricks DE Claude Code Kit Installer ==="

REPO_URL="https://github.com/felixmagieraacuity/databricks-de-kit"
SCOPE=""

for arg in "$@"; do
    case "$arg" in
        --scope=*) SCOPE="${arg#--scope=}" ;;
        --scope) SCOPE="__next__" ;;
        *)
            if [ "${SCOPE:-}" = "__next__" ]; then
                SCOPE="$arg"
            fi
            ;;
    esac
done

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

# Step 2: resolve KIT_DIR — local clone next to this script if present,
# otherwise clone into a temp dir (pipe-safe: curl | bash has no script dir).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
TMP_CLONE_DIR=""

cleanup() {
    if [ -n "$TMP_CLONE_DIR" ] && [ -d "$TMP_CLONE_DIR" ]; then
        rm -rf "$TMP_CLONE_DIR"
    fi
}
trap cleanup EXIT

if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/skills" ]; then
    KIT_DIR="$SCRIPT_DIR"
    echo "[0/5] Using local kit checkout: $KIT_DIR"
else
    echo "[0/5] No local kit checkout found — cloning $REPO_URL ..."
    TMP_CLONE_DIR="$(mktemp -d)"
    git clone --depth 1 "$REPO_URL" "$TMP_CLONE_DIR"
    KIT_DIR="$TMP_CLONE_DIR"
fi

DEST="$(pwd)"

# Step 3: determine scope
if [ -z "$SCOPE" ]; then
    default_scope="project"
    if git -C "$DEST" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        default_scope="team"
    fi

    if [ -t 0 ]; then
        read -rp "Install scope? [project/team/global] (default: $default_scope): " scope_input </dev/tty || true
    elif [ -r /dev/tty ]; then
        printf "Install scope? [project/team/global] (default: %s): " "$default_scope"
        read -rp "" scope_input </dev/tty || true
    else
        scope_input=""
    fi
    SCOPE="${scope_input:-$default_scope}"
fi

case "$SCOPE" in
    project|team|global) ;;
    *)
        echo "Unknown --scope '$SCOPE' (expected project|team|global). Defaulting to 'project'."
        SCOPE="project"
        ;;
esac

echo "Install scope: $SCOPE"

# Step 4: resolve destination paths for this scope
if [ "$SCOPE" = "global" ]; then
    CLAUDE_DIR="$HOME/.claude"
    HOOKS_DIR="$CLAUDE_DIR/hooks"
    SETTINGS_PATH="$CLAUDE_DIR/settings.json"
else
    CLAUDE_DIR="$DEST/.claude"
    HOOKS_DIR="$CLAUDE_DIR/hooks"
    SETTINGS_PATH="$CLAUDE_DIR/settings.json"
fi

# Step 5: install skills, commands, agents, hooks
echo "[1/5] Installing DE Kit skills, commands, agents, and hooks ($SCOPE scope)..."

mkdir -p "$CLAUDE_DIR/skills" && cp -r "$KIT_DIR/skills/"* "$CLAUDE_DIR/skills/" \
    && echo "  Skills installed ($(ls -d "$KIT_DIR/skills/"*/ | wc -l | tr -d ' ') skill dirs) -> $CLAUDE_DIR/skills"

mkdir -p "$CLAUDE_DIR/commands" && cp "$KIT_DIR/.claude/commands/"*.md "$CLAUDE_DIR/commands/" \
    && echo "  Commands installed -> $CLAUDE_DIR/commands"

mkdir -p "$CLAUDE_DIR/agents" && cp "$KIT_DIR/agents/"*.md "$CLAUDE_DIR/agents/" \
    && echo "  Agents installed -> $CLAUDE_DIR/agents"

mkdir -p "$HOOKS_DIR" && cp "$KIT_DIR/hooks/"*.py "$HOOKS_DIR/" && chmod +x "$HOOKS_DIR/"*.py \
    && echo "  Hooks installed -> $HOOKS_DIR"

if [ "$SCOPE" = "global" ]; then
    echo "  Skipping ~/.claude/CLAUDE.md — never overwritten."
    echo "  Template available at: $KIT_DIR/.claude/CLAUDE.md (copy manually if desired)"
else
    if [ -f "$DEST/CLAUDE.md" ]; then
        cp "$DEST/CLAUDE.md" "$DEST/CLAUDE.md.backup"
        echo "  Existing CLAUDE.md backed up -> CLAUDE.md.backup"
    fi
    cp "$KIT_DIR/.claude/CLAUDE.md" "$DEST/CLAUDE.md" && echo "  CLAUDE.md installed -> $DEST/CLAUDE.md"
fi

if [ ! -f "$DEST/.env.example" ]; then
    cp "$KIT_DIR/.env.example" "$DEST/.env.example" && echo "  .env.example created"
fi

# Step 6: wire hooks into settings.json (merge, not overwrite)
echo "[2/5] Wiring hooks into $SETTINGS_PATH ..."

if [ "$SCOPE" = "global" ]; then
    HOOK_PY_PREFIX="$HOME/.claude/hooks"
else
    HOOK_PY_PREFIX=".claude/hooks"
fi

mkdir -p "$(dirname "$SETTINGS_PATH")"

python3 - "$SETTINGS_PATH" "$HOOK_PY_PREFIX" <<'PYEOF'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
hook_prefix = sys.argv[2]

if settings_path.exists():
    with open(settings_path) as f:
        existing = json.load(f)
else:
    existing = {}

existing.setdefault("hooks", {})


def cmd(name: str) -> str:
    return f"python3 {hook_prefix}/{name}"


new_hooks = {
    "PreToolUse": [
        {"matcher": "Bash", "hooks": [{"type": "command", "command": cmd("pre_commit_guard.py")}]},
        {"matcher": "Bash|Write|Edit", "hooks": [{"type": "command", "command": cmd("destructive_op_guard.py")}]},
    ],
    "PostToolUse": [
        {"matcher": "Write|Edit", "hooks": [{"type": "command", "command": cmd("sqlfluff_guard.py")}]},
    ],
    "Stop": [
        {"hooks": [{"type": "command", "command": cmd("extract_learnings.py")}]},
    ],
}


def entry_signature(entry):
    return json.dumps(entry, sort_keys=True)


for hook_type, entries in new_hooks.items():
    existing["hooks"].setdefault(hook_type, [])
    existing_sigs = {entry_signature(e) for e in existing["hooks"][hook_type]}
    for entry in entries:
        if entry_signature(entry) not in existing_sigs:
            existing["hooks"][hook_type].append(entry)

with open(settings_path, "w") as f:
    json.dump(existing, f, indent=2)
    f.write("\n")

print(f"  Hooks merged into {settings_path}")
PYEOF

# Step 7: ai-dev-kit MCP (github.com/databricks-solutions/ai-dev-kit)
echo "[3/5] Setting up ai-dev-kit MCP server..."

AI_DEV_KIT_DIR="$HOME/.databricks-de-kit/ai-dev-kit"

if [ -d "$AI_DEV_KIT_DIR/.git" ]; then
    echo "  ai-dev-kit already cloned -> $AI_DEV_KIT_DIR (skipping clone)"
else
    mkdir -p "$(dirname "$AI_DEV_KIT_DIR")"
    if git clone https://github.com/databricks-solutions/ai-dev-kit.git "$AI_DEV_KIT_DIR"; then
        echo "  ai-dev-kit cloned -> $AI_DEV_KIT_DIR"
    else
        echo "  WARNING: failed to clone ai-dev-kit. Set it up manually:"
        echo "    git clone https://github.com/databricks-solutions/ai-dev-kit.git $AI_DEV_KIT_DIR"
        AI_DEV_KIT_DIR=""
    fi
fi

if [ -n "$AI_DEV_KIT_DIR" ] && [ -d "$AI_DEV_KIT_DIR" ]; then
    if command -v uv >/dev/null 2>&1; then
        if uv venv "$AI_DEV_KIT_DIR/.venv" >/dev/null 2>&1 && (cd "$AI_DEV_KIT_DIR" && VIRTUAL_ENV="$AI_DEV_KIT_DIR/.venv" uv pip install -e ./databricks-tools-core -e ./databricks-mcp-server); then
            echo "  ai-dev-kit MCP dependencies installed"
        else
            echo "  WARNING: uv pip install failed for ai-dev-kit. Install manually:"
            echo "    cd $AI_DEV_KIT_DIR && uv pip install -e ./databricks-tools-core -e ./databricks-mcp-server"
        fi
    else
        echo "  WARNING: uv not found — skipping ai-dev-kit dependency install."
        echo "    Install uv, then run: cd $AI_DEV_KIT_DIR && uv pip install -e ./databricks-tools-core -e ./databricks-mcp-server"
    fi

    echo "  Registering 'databricks' MCP server ($SCOPE scope)..."
    if [ "$SCOPE" = "global" ]; then
        if command -v claude >/dev/null 2>&1; then
            claude mcp add -s user databricks -- uv run --directory "$AI_DEV_KIT_DIR" python databricks-mcp-server/run_server.py \
                && echo "  Registered via 'claude mcp add -s user'" \
                || echo "  WARNING: 'claude mcp add' failed — register manually (see README)."
        else
            echo "  WARNING: claude CLI not found — cannot run 'claude mcp add'. Register manually (see README)."
        fi
    else
        MCP_JSON_PATH="$DEST/.mcp.json"
        python3 - "$MCP_JSON_PATH" "$AI_DEV_KIT_DIR" <<'PYEOF'
import json
import sys
from pathlib import Path

mcp_path = Path(sys.argv[1])
ai_dev_kit_dir = sys.argv[2]

if mcp_path.exists():
    with open(mcp_path) as f:
        existing = json.load(f)
else:
    existing = {}

existing.setdefault("mcpServers", {})
existing["mcpServers"]["databricks"] = {
    "command": "uv",
    "args": ["run", "--directory", ai_dev_kit_dir, "python", "databricks-mcp-server/run_server.py"],
    "defer_loading": True,
}

with open(mcp_path, "w") as f:
    json.dump(existing, f, indent=2)
    f.write("\n")

print(f"  .mcp.json written/merged -> {mcp_path}")
PYEOF
    fi
fi

# Step 8: Databricks Agent Skills (skills only — NOT an MCP server)
echo "[4/5] Installing Databricks Agent Skills (databricks aitools install)..."
if [ "$SCOPE" = "global" ]; then
    databricks aitools install || \
        echo "  WARNING: databricks aitools install failed. Install manually: https://github.com/databricks/databricks-agent-skills"
else
    databricks aitools install --scope project || \
        echo "  WARNING: databricks aitools install --scope project failed. Install manually: https://github.com/databricks/databricks-agent-skills"
fi

# Step 9: scope-specific bookkeeping (.gitignore for project scope, .mcp.json ignore for team)
if [ "$SCOPE" = "project" ]; then
    GITIGNORE="$DEST/.gitignore"
    touch "$GITIGNORE"
    for entry in ".claude/skills" ".claude/commands" ".claude/agents" ".claude/hooks" ".claude/settings.json" "CLAUDE.md" ".mcp.json"; do
        grep -qxF "$entry" "$GITIGNORE" || echo "$entry" >> "$GITIGNORE"
    done
    echo "  .gitignore updated (project scope: kit files stay local-only)"
elif [ "$SCOPE" = "team" ]; then
    GITIGNORE="$DEST/.gitignore"
    touch "$GITIGNORE"
    grep -qxF ".mcp.json" "$GITIGNORE" || echo ".mcp.json" >> "$GITIGNORE"
    echo "  .gitignore updated (team scope: only .mcp.json stays local-only — commit the rest so your team gets it via git pull)"
fi

echo "[5/5] Done!"
cat <<EOF

What was installed ($SCOPE scope):
  - 4 custom skills + 19 Databricks platform skills (via databricks aitools install)
  - 3 slash commands: /de:scaffold-pipeline, /de:inspect-generate-validate, /de:dbx-debug-job
  - 2 autonomous agents: databricks-medallion-scaffolder, databricks-job-debugger
  - 4 hooks (wired into settings.json): pre_commit_guard, destructive_op_guard, sqlfluff_guard, extract_learnings
  - ai-dev-kit MCP server (databricks tools: list_tables, get_table_info, execute_sql, run_job, ...)
  - CLAUDE.md template
EOF

if [ "$SCOPE" = "team" ]; then
    echo "  - Kit files are tracked in git (team scope) — teammates get them via 'git pull'."
    echo "    .mcp.json stays gitignored (per-person, contains an absolute path)."
elif [ "$SCOPE" = "project" ]; then
    echo "  - Kit files are gitignored (project scope) — local to this checkout only."
fi

cat <<'EOF'

Next steps:
  1. databricks auth login   (then set DATABRICKS_CONFIG_PROFILE to the resulting profile)
  2. Fill in .env.example / your Databricks workspace details as needed
EOF
