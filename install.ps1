#!/usr/bin/env pwsh
# Databricks DE Claude Code Kit — Windows installer
#
# Usage:
#   irm https://raw.githubusercontent.com/felixmagieraacuity/databricks-de-kit/main/install.ps1 | iex
#   $env:KIT_SCOPE="project"; irm .../install.ps1 | iex   (non-interactive)
#
# Safe to run piped (irm | iex has no script path) and safe to run from a
# local clone (reuses local files, no network clone).
# Scope from env (irm | iex cannot pass -Scope); empty -> prompt below.
$Scope = if ($env:KIT_SCOPE) { $env:KIT_SCOPE } else { "" }

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

Write-Host "=== Databricks DE Claude Code Kit Installer ===" -ForegroundColor Cyan

$RepoUrl = "https://github.com/felixmagieraacuity/databricks-de-kit"

# Step 1: Check prereqs
$missing = @()
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    $missing += "uv (https://docs.astral.sh/uv/getting-started/installation/)"
}
if (-not (Get-Command databricks -ErrorAction SilentlyContinue)) {
    $missing += "Databricks CLI (https://docs.databricks.com/dev-tools/cli/install.html)"
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    $missing += "Claude Code CLI (https://claude.ai/code)"
}

if ($missing.Count -gt 0) {
    Write-Host "`nMissing prerequisites:" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "`nInstall missing tools and re-run. Continuing anyway..." -ForegroundColor Yellow
}

# Step 2: resolve KitDir — local clone next to this script if present,
# otherwise clone into a temp dir (pipe-safe: irm | iex has no $PSScriptRoot).
$tmpCloneDir = $null
$scriptDir = $PSScriptRoot

if ($scriptDir -and (Test-Path (Join-Path $scriptDir "skills"))) {
    $kitDir = $scriptDir
    Write-Host "[0/5] Using local kit checkout: $kitDir" -ForegroundColor Green
} else {
    Write-Host "[0/5] No local kit checkout found — cloning $RepoUrl ..." -ForegroundColor Green
    $tmpCloneDir = Join-Path ([System.IO.Path]::GetTempPath()) ("databricks-de-kit-" + [System.Guid]::NewGuid().ToString("N"))
    git clone --depth 1 $RepoUrl $tmpCloneDir
    $kitDir = $tmpCloneDir
}

try {
    $dest = Get-Location

    # Step 3: determine scope
    if (-not $Scope) {
        $defaultScope = "project"
        git -C $dest rev-parse --is-inside-work-tree *> $null
        if ($LASTEXITCODE -eq 0) {
            $defaultScope = "team"
        }
        $scopeInput = Read-Host "Install scope? [project/team/global] (default: $defaultScope)"
        if ([string]::IsNullOrWhiteSpace($scopeInput)) {
            $Scope = $defaultScope
        } else {
            $Scope = $scopeInput
        }
    }

    if ($Scope -notin @("project", "team", "global")) {
        Write-Host "Unknown -Scope '$Scope' (expected project|team|global). Defaulting to 'project'." -ForegroundColor Yellow
        $Scope = "project"
    }

    Write-Host "Install scope: $Scope" -ForegroundColor Cyan

    # Step 4: resolve destination paths for this scope
    if ($Scope -eq "global") {
        $claudeDir = Join-Path $HOME ".claude"
    } else {
        $claudeDir = Join-Path $dest ".claude"
    }
    $hooksDir = Join-Path $claudeDir "hooks"
    $settingsPath = Join-Path $claudeDir "settings.json"

    # Step 5: install skills, commands, agents, hooks
    Write-Host "`n[1/5] Installing DE Kit skills, commands, agents, and hooks ($Scope scope)..." -ForegroundColor Green

    $skillsDest = Join-Path $claudeDir "skills"
    New-Item -ItemType Directory -Force $skillsDest | Out-Null
    Copy-Item "$kitDir\skills\*" $skillsDest -Recurse -Force
    Write-Host "  Skills installed -> $skillsDest"

    $cmdDest = Join-Path $claudeDir "commands"
    New-Item -ItemType Directory -Force $cmdDest | Out-Null
    Copy-Item "$kitDir\.claude\commands\*.md" $cmdDest -Force
    Write-Host "  Commands installed -> $cmdDest"

    $agentsDest = Join-Path $claudeDir "agents"
    New-Item -ItemType Directory -Force $agentsDest | Out-Null
    Copy-Item "$kitDir\agents\*.md" $agentsDest -Force
    Write-Host "  Agents installed -> $agentsDest"

    New-Item -ItemType Directory -Force $hooksDir | Out-Null
    Copy-Item "$kitDir\hooks\*.py" $hooksDir -Force
    Write-Host "  Hooks installed -> $hooksDir"

    if ($Scope -eq "global") {
        Write-Host "  Skipping ~/.claude/CLAUDE.md — never overwritten."
        Write-Host "  Template available at: $kitDir\.claude\CLAUDE.md (copy manually if desired)"
    } else {
        $claudeMdSrc = "$kitDir\.claude\CLAUDE.md"
        $claudeMdDest = Join-Path $dest "CLAUDE.md"
        if (Test-Path $claudeMdDest) {
            Copy-Item $claudeMdDest "$claudeMdDest.backup" -Force
            Write-Host "  Existing CLAUDE.md backed up -> CLAUDE.md.backup"
        }
        Copy-Item $claudeMdSrc $claudeMdDest -Force
        Write-Host "  CLAUDE.md installed -> $claudeMdDest"
    }

    $envDest = Join-Path $dest ".env.example"
    if (-not (Test-Path $envDest)) {
        Copy-Item "$kitDir\.env.example" $envDest -Force
        Write-Host "  .env.example created"
    }

    # Step 6: wire hooks into settings.json (merge, not overwrite)
    Write-Host "`n[2/5] Wiring hooks into $settingsPath ..." -ForegroundColor Green

    if ($Scope -eq "global") {
        $hookPyPrefix = (Join-Path $HOME ".claude\hooks") -replace '\\', '/'
    } else {
        $hookPyPrefix = ".claude/hooks"
    }

    $settingsParent = Split-Path $settingsPath -Parent
    New-Item -ItemType Directory -Force $settingsParent | Out-Null

    $mergeHooksScript = @'
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
    return f"python {hook_prefix}/{name}"


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
'@

    $mergeHooksScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("merge_hooks_" + [System.Guid]::NewGuid().ToString("N") + ".py")
    Set-Content -Path $mergeHooksScriptPath -Value $mergeHooksScript -Encoding UTF8
    python $mergeHooksScriptPath $settingsPath $hookPyPrefix
    Remove-Item $mergeHooksScriptPath -Force

    # Step 7: ai-dev-kit MCP (github.com/databricks-solutions/ai-dev-kit)
    Write-Host "`n[3/5] Setting up ai-dev-kit MCP server..." -ForegroundColor Green

    $aiDevKitDir = Join-Path $HOME ".databricks-de-kit\ai-dev-kit"

    if (Test-Path (Join-Path $aiDevKitDir ".git")) {
        Write-Host "  ai-dev-kit already cloned -> $aiDevKitDir (skipping clone)"
    } else {
        New-Item -ItemType Directory -Force (Split-Path $aiDevKitDir -Parent) | Out-Null
        git clone https://github.com/databricks-solutions/ai-dev-kit.git $aiDevKitDir
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ai-dev-kit cloned -> $aiDevKitDir"
        } else {
            Write-Host "  WARNING: failed to clone ai-dev-kit. Set it up manually:" -ForegroundColor Yellow
            Write-Host "    git clone https://github.com/databricks-solutions/ai-dev-kit.git $aiDevKitDir" -ForegroundColor Yellow
            $aiDevKitDir = $null
        }
    }

    if ($aiDevKitDir -and (Test-Path $aiDevKitDir)) {
        if (Get-Command uv -ErrorAction SilentlyContinue) {
            Push-Location $aiDevKitDir
            uv venv (Join-Path $aiDevKitDir ".venv") | Out-Null
            $env:VIRTUAL_ENV = Join-Path $aiDevKitDir ".venv"
            uv pip install -e ./databricks-tools-core -e ./databricks-mcp-server
            $uvExit = $LASTEXITCODE
            Pop-Location
            if ($uvExit -eq 0) {
                Write-Host "  ai-dev-kit MCP dependencies installed"
            } else {
                Write-Host "  WARNING: uv pip install failed for ai-dev-kit. Install manually:" -ForegroundColor Yellow
                Write-Host "    cd $aiDevKitDir; uv pip install -e ./databricks-tools-core -e ./databricks-mcp-server" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  WARNING: uv not found — skipping ai-dev-kit dependency install." -ForegroundColor Yellow
            Write-Host "    Install uv, then run: cd $aiDevKitDir; uv pip install -e ./databricks-tools-core -e ./databricks-mcp-server" -ForegroundColor Yellow
        }

        Write-Host "  Registering 'databricks' MCP server ($Scope scope)..."
        if ($Scope -eq "global") {
            if (Get-Command claude -ErrorAction SilentlyContinue) {
                claude mcp add -s user databricks -- uv run --directory $aiDevKitDir python databricks-mcp-server/run_server.py
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Registered via 'claude mcp add -s user'"
                } else {
                    Write-Host "  WARNING: 'claude mcp add' failed — register manually (see README)." -ForegroundColor Yellow
                }
            } else {
                Write-Host "  WARNING: claude CLI not found — cannot run 'claude mcp add'. Register manually (see README)." -ForegroundColor Yellow
            }
        } else {
            $mcpJsonPath = Join-Path $dest ".mcp.json"
            $aiDevKitDirForward = $aiDevKitDir -replace '\\', '/'

            $mergeMcpScript = @'
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
'@
            $mergeMcpScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("merge_mcp_" + [System.Guid]::NewGuid().ToString("N") + ".py")
            Set-Content -Path $mergeMcpScriptPath -Value $mergeMcpScript -Encoding UTF8
            python $mergeMcpScriptPath $mcpJsonPath $aiDevKitDirForward
            Remove-Item $mergeMcpScriptPath -Force
        }
    }

    # Step 8: Databricks Agent Skills (skills only — NOT an MCP server)
    Write-Host "`n[4/5] Installing Databricks Agent Skills (databricks aitools install)..." -ForegroundColor Green
    if ($Scope -eq "global") {
        databricks aitools install
    } else {
        databricks aitools install --scope project
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: databricks aitools install failed. Install manually: https://github.com/databricks/databricks-agent-skills" -ForegroundColor Yellow
    }

    # Step 9: scope-specific bookkeeping (.gitignore for project scope, .mcp.json ignore for team)
    if ($Scope -eq "project") {
        $gitignore = Join-Path $dest ".gitignore"
        if (-not (Test-Path $gitignore)) { New-Item -ItemType File $gitignore | Out-Null }
        $entries = @(".claude/skills", ".claude/commands", ".claude/agents", ".claude/hooks", ".claude/settings.json", "CLAUDE.md", ".mcp.json")
        $existingLines = Get-Content $gitignore
        foreach ($entry in $entries) {
            if ($existingLines -notcontains $entry) {
                Add-Content $gitignore $entry
            }
        }
        Write-Host "  .gitignore updated (project scope: kit files stay local-only)"
    } elseif ($Scope -eq "team") {
        $gitignore = Join-Path $dest ".gitignore"
        if (-not (Test-Path $gitignore)) { New-Item -ItemType File $gitignore | Out-Null }
        $existingLines = Get-Content $gitignore
        if ($existingLines -notcontains ".mcp.json") {
            Add-Content $gitignore ".mcp.json"
        }
        Write-Host "  .gitignore updated (team scope: only .mcp.json stays local-only — commit the rest so your team gets it via git pull)"
    }

    Write-Host "`n[5/5] Done!" -ForegroundColor Green
    Write-Host @"

What was installed ($Scope scope):
  - 23 Databricks DE skills (4 custom + 19 platform)
  - 3 slash commands: /de:scaffold-pipeline, /de:inspect-generate-validate, /de:dbx-debug-job
  - 2 autonomous agents: databricks-medallion-scaffolder, databricks-job-debugger
  - 4 hooks (wired into settings.json): pre_commit_guard, destructive_op_guard, sqlfluff_guard, extract_learnings
  - ai-dev-kit MCP server (databricks tools: list_tables, get_table_info, execute_sql, run_job, ...)
  - CLAUDE.md template
"@

    if ($Scope -eq "team") {
        Write-Host "  - Kit files are tracked in git (team scope) — teammates get them via 'git pull'."
        Write-Host "    .mcp.json stays gitignored (per-person, contains an absolute path)."
    } elseif ($Scope -eq "project") {
        Write-Host "  - Kit files are gitignored (project scope) — local to this checkout only."
    }

    Write-Host @"

Next steps:
  1. databricks auth login   (then set DATABRICKS_CONFIG_PROFILE to the resulting profile)
  2. Fill in .env.example / your Databricks workspace details as needed
"@

    # Step 10: ELI5 onboarding HTML
    $htmlOut = Join-Path $Dest "databricks-de-kit-start.html"
    $htmlContent = @'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<title>Databricks DE Kit</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,sans-serif;background:#0f1117;color:#e1e4e8;padding:2.5rem;max-width:900px;margin:0 auto}
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
  .item .cmd{background:#161b22;border-radius:5px;padding:.65rem .9rem;font-family:monospace;font-size:.82rem;color:#79c0ff;border:1px solid #30363d}
</style>
</head>
<body>
<h1>Databricks DE Kit</h1>
<p class="sub">Installiert. Hier ist, was du jetzt hast und wie du es einsetzt.</p>

<h2>Slash Commands</h2>
<div class="grid">
  <div class="card">
    <code>/de:scaffold-pipeline</code>
    <p>Neue Datenquelle X - Claude inspiziert Schema, schreibt Bronze+Silver-Notebooks und richtet den Job ein.</p>
    <p class="when"><strong>Wann:</strong> Neue Datenquelle onboarden.</p>
  </div>
  <div class="card">
    <code>/de:inspect-generate-validate</code>
    <p>Tabelle profilieren, Code generieren, Ergebnis validieren - alles in einem Schritt.</p>
    <p class="when"><strong>Wann:</strong> Tabelle verstehen + Code dafuer.</p>
  </div>
  <div class="card">
    <code>/de:dbx-debug-job</code>
    <p>Job fehlgeschlagen? Run-ID angeben. Claude analysiert Logs, findet Root-Cause, schlaegt Fix vor.</p>
    <p class="when"><strong>Wann:</strong> Databricks Job abgestuerzt.</p>
  </div>
</div>

<h2>Autonome Agents</h2>
<div class="grid">
  <div class="card">
    <code>databricks-medallion-scaffolder</code>
    <p>Wie scaffold-pipeline, vollstaendig autonom. Inspiziert, schreibt Bronze/Silver/Gold, validiert.</p>
  </div>
  <div class="card">
    <code>databricks-job-debugger</code>
    <p>Wie dbx-debug-job, autonom. Gibt: Root-Cause (2 Zeilen) + Fix + Validierung.</p>
  </div>
</div>

<h2>Hooks (laufen im Hintergrund)</h2>
<table>
  <tr><th>Hook</th><th>Was er tut</th></tr>
  <tr><td><code>pre_commit_guard</code></td><td>Stoppt git commits wenn Tests fehlschlagen</td></tr>
  <tr><td><code>destructive_op_guard</code></td><td>Blockiert destruktive DDL-Operationen und unsichere Deletes</td></tr>
  <tr><td><code>sqlfluff_guard</code></td><td>Formatiert SQL-Dateien automatisch nach jedem Speichern</td></tr>
  <tr><td><code>extract_learnings</code></td><td>Destilliert am Session-Ende was Claude gelernt hat</td></tr>
</table>

<div class="auto">
  <h2>Soll ich dir was automatisieren?</h2>
  <p class="desc">Kopier eine dieser Zeilen direkt in Claude:</p>
  <div class="item">
    <div class="lbl">Health-Check aller Bronze-Tabellen</div>
    <div class="cmd">/de:inspect-generate-validate -- fuehre das fuer alle Tabellen in meinem Bronze-Schema aus und gib mir einen Qualitaets-Report</div>
  </div>
  <div class="item">
    <div class="lbl">CLAUDE.md mit echten Werten befuellen</div>
    <div class="cmd">Ergaenze meine CLAUDE.md mit meinen Databricks-Werten: CATALOG=..., SCHEMA=..., HOST=...</div>
  </div>
  <div class="item">
    <div class="lbl">Erste Pipeline scaffolden</div>
    <div class="cmd">/de:scaffold-pipeline -- starte mit meiner ersten Datenquelle: [Tabellenname einfuegen]</div>
  </div>
  <div class="item">
    <div class="lbl">Letzten failing Job fixen</div>
    <div class="cmd">/de:dbx-debug-job -- mein letzter Job-Run hat gefailed, analysiere und fix ihn: [Run-ID einfuegen]</div>
  </div>
</div>
</body>
</html>
'@
    [System.IO.File]::WriteAllText($htmlOut, $htmlContent, [System.Text.Encoding]::UTF8)
    Write-Host "`n  Onboarding guide: $htmlOut" -ForegroundColor Green
    Start-Process $htmlOut -ErrorAction SilentlyContinue
} finally {
    if ($tmpCloneDir -and (Test-Path $tmpCloneDir)) {
        Remove-Item -Recurse -Force $tmpCloneDir
    }
}
