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
  - 4 custom skills + 19 Databricks platform skills (via databricks aitools install)
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
} finally {
    if ($tmpCloneDir -and (Test-Path $tmpCloneDir)) {
        Remove-Item -Recurse -Force $tmpCloneDir
    }
}
