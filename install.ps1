#!/usr/bin/env pwsh
# Databricks DE Claude Code Kit — Windows installer

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

Write-Host "=== Databricks DE Claude Code Kit Installer ===" -ForegroundColor Cyan

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

# Step 2: Install Databricks Agent Skills + MCP (replaces the deprecated ai-dev-kit)
Write-Host "`n[1/4] Installing Databricks Agent Skills + MCP server..." -ForegroundColor Green
try {
    databricks aitools install
} catch {
    Write-Host "databricks aitools install failed: $_" -ForegroundColor Red
    Write-Host "Install manually: https://github.com/databricks/databricks-agent-skills" -ForegroundColor Yellow
}

# Step 3: Copy kit files to current project
Write-Host "`n[2/4] Installing DE Kit skills, commands, hooks, and CLAUDE.md..." -ForegroundColor Green

$kitDir = $PSScriptRoot
$dest = Get-Location

# Skills
$skillsDest = Join-Path $dest ".claude\skills"
New-Item -ItemType Directory -Force $skillsDest | Out-Null
Copy-Item "$kitDir\skills\*" $skillsDest -Recurse -Force
Write-Host "  Skills installed to .claude/skills/"

# Commands
$cmdDest = Join-Path $dest ".claude\commands"
New-Item -ItemType Directory -Force $cmdDest | Out-Null
Copy-Item "$kitDir\.claude\commands\*.md" $cmdDest -Force
Write-Host "  Commands installed to .claude/commands/"

# Agents
$agentsDest = Join-Path $dest ".claude\agents"
New-Item -ItemType Directory -Force $agentsDest | Out-Null
Copy-Item "$kitDir\agents\*.md" $agentsDest -Force
Write-Host "  Agents installed to .claude/agents/"

# Hooks
$hooksDest = Join-Path $dest "scripts\hooks"
New-Item -ItemType Directory -Force $hooksDest | Out-Null
Copy-Item "$kitDir\hooks\*.py" $hooksDest -Force
Write-Host "  Hooks installed to scripts/hooks/"

# CLAUDE.md
$claudeMdSrc = "$kitDir\.claude\CLAUDE.md"
$claudeMdDest = Join-Path $dest "CLAUDE.md"
if (Test-Path $claudeMdDest) {
    Copy-Item $claudeMdDest "$claudeMdDest.backup" -Force
    Write-Host "  Existing CLAUDE.md backed up to CLAUDE.md.backup"
}
Copy-Item $claudeMdSrc $claudeMdDest -Force
Write-Host "  CLAUDE.md installed"

# .env.example
$envDest = Join-Path $dest ".env.example"
if (-not (Test-Path $envDest)) {
    Copy-Item "$kitDir\.env.example" $envDest -Force
    Write-Host "  .env.example created — fill in your values"
}

# Step 4: Guided auth
Write-Host "`n[3/4] Databricks authentication..." -ForegroundColor Green
Write-Host "  Run this to authenticate:" -ForegroundColor White
Write-Host "  databricks auth login --host `$env:DATABRICKS_HOST" -ForegroundColor Cyan
$auth = Read-Host "  Run databricks auth login now? (y/N)"
if ($auth -eq 'y' -or $auth -eq 'Y') {
    databricks auth login
}

# Done
Write-Host "`n[4/4] Done!" -ForegroundColor Green
Write-Host @"

What was installed:
  - Databricks Agent Skills + MCP server (via databricks aitools install)
  - 4 custom skills: bronze_ingestion, silver_transformation, spark_patterns, databricks_quality_auditor
  - 3 slash commands: /de:scaffold-pipeline, /de:inspect-generate-validate, /de:dbx-debug-job
  - 2 autonomous agents: databricks-medallion-scaffolder, databricks-job-debugger
  - 4 hooks: pre_commit_guard, sqlfluff_guard, extract_learnings, destructive_op_guard
  - CLAUDE.md template
  - .env.example

Next steps:
  1. Fill in .env.example with your workspace details
  2. Wire hooks in .claude/settings.json (see README.md)
  3. Run: claude code
"@
