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
  - 23 Databricks DE skills (4 custom + 19 platform)
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

# Step 10: ELI5 onboarding HTML
HTML_OUT="$DEST/databricks-de-kit-start.html"
cat <<'HTMLEOF' > "$HTML_OUT"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<title>Databricks DE Kit — Was du jetzt hast</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f1117;color:#e1e4e8;padding:2.5rem;max-width:900px;margin:0 auto}
  h1{color:#ff3621;font-size:1.75rem;margin-bottom:.25rem}
  .sub{color:#8b949e;margin-bottom:2.5rem;font-size:.95rem}
  h2{color:#8b949e;font-size:.75rem;text-transform:uppercase;letter-spacing:.1em;margin:2.5rem 0 .75rem}
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:.875rem}
  .card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:1.25rem}
  .card code{background:#21262d;color:#ff7b72;padding:.2rem .5rem;border-radius:4px;font-size:.85rem;display:inline-block;margin-bottom:.75rem}
  .card p{font-size:.875rem;line-height:1.55;color:#c9d1d9}
  .when{margin-top:.6rem;font-size:.8rem;color:#8b949e}
  .when strong{color:#58a6ff}
  table{width:100%;border-collapse:collapse;margin-top:.5rem}
  td,th{padding:.55rem .75rem;text-align:left;border-bottom:1px solid #21262d;font-size:.85rem}
  th{color:#8b949e;font-weight:500}
  td code{background:#21262d;color:#ff7b72;padding:.1rem .35rem;border-radius:3px;font-size:.8rem}
  .auto{background:#0d1117;border:1px solid #ff3621;border-radius:8px;padding:1.5rem;margin-top:2.5rem}
  .auto h2{margin:0 0 .5rem;color:#ff3621;font-size:.95rem;text-transform:none;letter-spacing:0}
  .auto .desc{color:#8b949e;font-size:.8rem;margin-bottom:1rem}
  .item{margin:.5rem 0}
  .item .lbl{font-size:.72rem;color:#8b949e;margin-bottom:.2rem}
  .item .cmd{background:#161b22;border-radius:5px;padding:.65rem .9rem;font-family:'SF Mono',Menlo,monospace;font-size:.82rem;color:#79c0ff;border:1px solid #30363d}
</style>
</head>
<body>
<h1>Databricks DE Kit</h1>
<p class="sub">Installiert. Hier ist, was du jetzt hast — und wie du es einsetzt.</p>

<h2>Slash Commands — Direkt in Claude eintippen</h2>
<div class="grid">
  <div class="card">
    <code>/de:scaffold-pipeline</code>
    <p>Du sagst "neue Datenquelle X" — Claude inspiziert das Schema, schreibt Bronze- und Silver-Notebooks und richtet den Databricks Job ein. Von Null zur laufenden Pipeline.</p>
    <p class="when"><strong>Wann:</strong> Neue Datenquelle onboarden.</p>
  </div>
  <div class="card">
    <code>/de:inspect-generate-validate</code>
    <p>Zeig mir meine Daten und schreib Code dafür. Claude profiliert die Tabelle, generiert Transformationen und validiert das Ergebnis — alles in einem Schritt.</p>
    <p class="when"><strong>Wann:</strong> Tabelle verstehen + sofort Code dafür.</p>
  </div>
  <div class="card">
    <code>/de:dbx-debug-job</code>
    <p>Job fehlgeschlagen? Gib die Run-ID an. Claude holt die Logs, liest den Code, findet den Root-Cause und schlägt den kleinsten möglichen Fix vor.</p>
    <p class="when"><strong>Wann:</strong> Ein Databricks Job ist abgestürzt.</p>
  </div>
</div>

<h2>Autonome Agents — Laufen selbstständig durch</h2>
<div class="grid">
  <div class="card">
    <code>databricks-medallion-scaffolder</code>
    <p>Wie scaffold-pipeline, aber vollständig autonom. Kein Nachfragen — inspiziert, schreibt Bronze/Silver/Gold, validiert. Für komplexe Multi-Layer-Pipelines.</p>
  </div>
  <div class="card">
    <code>databricks-job-debugger</code>
    <p>Wie dbx-debug-job, aber autonom. Gibt dir am Ende: Root-Cause in 2 Zeilen + Fix + Validierung. Kein Rauschen.</p>
  </div>
</div>

<h2>Hooks — Laufen still im Hintergrund</h2>
<table>
  <tr><th>Hook</th><th>Was er tut</th></tr>
  <tr><td><code>pre_commit_guard</code></td><td>Stoppt git commits wenn Tests fehlschlagen</td></tr>
  <tr><td><code>destructive_op_guard</code></td><td>Blockiert destruktive Operationen (schema-breaking DDL, unsichere Deletes)</td></tr>
  <tr><td><code>sqlfluff_guard</code></td><td>Formatiert SQL-Dateien automatisch nach jedem Speichern</td></tr>
  <tr><td><code>extract_learnings</code></td><td>Destilliert am Session-Ende was Claude gelernt hat in docs/learnings/</td></tr>
</table>

<div class="auto">
  <h2>Soll ich dir was automatisieren?</h2>
  <p class="desc">Kopier eine dieser Zeilen direkt in Claude:</p>

  <div class="item">
    <div class="lbl">Health-Check aller Bronze-Tabellen</div>
    <div class="cmd">/de:inspect-generate-validate — führe das für alle Tabellen in meinem Bronze-Schema aus und gib mir einen Qualitäts-Report</div>
  </div>
  <div class="item">
    <div class="lbl">CLAUDE.md mit echten Werten befüllen</div>
    <div class="cmd">Ergänze meine CLAUDE.md mit meinen Databricks-Werten: CATALOG=..., SCHEMA=..., HOST=...</div>
  </div>
  <div class="item">
    <div class="lbl">Erste Pipeline scaffolden</div>
    <div class="cmd">/de:scaffold-pipeline — starte mit meiner ersten Datenquelle: [Tabellenname einfügen]</div>
  </div>
  <div class="item">
    <div class="lbl">Letzten failing Job fixen</div>
    <div class="cmd">/de:dbx-debug-job — mein letzter Job-Run hat gefailed, analysiere und fix ihn: [Run-ID einfügen]</div>
  </div>
</div>
</body>
</html>
HTMLEOF

echo ""
echo "  Onboarding guide: $HTML_OUT"
if [[ "$OSTYPE" == "darwin"* ]]; then
    open "$HTML_OUT" 2>/dev/null || true
fi
