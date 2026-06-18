# Databricks DE Claude Code Kit

One-liner to get Claude Code set up for Databricks Data Engineering.

## Install

### Option A — Claude Code plugin marketplace (recommended)

```bash
# add this repo as a marketplace, then install the plugin
/plugin marketplace add your-org/databricks-de-kit
/plugin install databricks-de-kit@databricks-de-kit
```

This wires up the skills, commands, **agents**, and hooks automatically. You can also
point the marketplace at a local clone:

```bash
/plugin marketplace add ./databricks-de-kit
```

### Option B — script installer (copies files into the current project)

**Windows (PowerShell)**
```powershell
irm https://raw.githubusercontent.com/your-org/databricks-de-kit/main/install.ps1 | iex
```

**Mac / Linux**
```bash
curl -fsSL https://raw.githubusercontent.com/your-org/databricks-de-kit/main/install.sh | bash
```

> **Note:** Update the URL above to match your actual repository location before publishing.

## What gets installed

| Component | Details |
|-----------|---------|
| **MCP** | Databricks Agent Skills + MCP server, via `databricks aitools install` (list_tables, get_table_info, execute_sql, run_job, …) |
| **Skills** | 23 curated Databricks DE skills (4 custom + 19 platform) — see Skills reference below |
| **Commands** | /de:scaffold-pipeline · /de:inspect-generate-validate · /de:dbx-debug-job |
| **Agents** | databricks-medallion-scaffolder · databricks-job-debugger (autonomous subagents) |
| **Hooks** | pre_commit_guard · sqlfluff_guard · extract_learnings · destructive_op_guard |
| **CLAUDE.md** | Canonical Databricks project template (edit for your catalog/schema) |

## After install

1. Fill in `.env.example` → copy to `.env` with your values
2. Add hooks to `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "command": "python scripts/hooks/pre_commit_guard.py" },
      { "matcher": "Bash|Write|Edit", "command": "python scripts/hooks/destructive_op_guard.py" }
    ],
    "PostToolUse": [
      { "matcher": "Write|Edit", "command": "python scripts/hooks/sqlfluff_guard.py" }
    ],
    "Stop": [
      { "command": "python scripts/hooks/extract_learnings.py" }
    ]
  }
}
```

3. Authenticate to Databricks: `databricks auth login --host $DATABRICKS_HOST`

## Skills reference

23 curated skills, scoped to **Databricks data engineering**. Skills auto-load when their
trigger keywords appear in a prompt. (MLflow/GenAI-eval, app-dev, and model-serving skills
are intentionally excluded — different domain.)

### Custom DE core (4)

| Skill | Trigger | What it does |
|-------|---------|-------------|
| `bronze_ingestion` | Scaffolding ingestion, Auto Loader, Bronze tables | Enforces Bronze Contract, audit columns, idempotency patterns |
| `silver_transformation` | Bronze→Silver transforms, dedup, quality | 6 mandatory rules: architecture, idempotency, dedup, Delta, logging, schema evolution |
| `spark_patterns` | Any PySpark code | 10-point anti-pattern matrix, Photon/Liquid Clustering optimizations |
| `databricks_quality_auditor` | Schema audits, CDC patterns | `classify_schema_change()` helper, APPLY CHANGES INTO, CDF, MERGE patterns |

### Databricks platform (19)

Pipelines & ingestion: `databricks-spark-declarative-pipelines` · `databricks-spark-structured-streaming` · `databricks-zerobus-ingest` · `spark-python-data-source`
SQL & transformation: `databricks-dbsql` · `databricks-ai-functions` · `databricks-metric-views`
Governance & formats: `databricks-unity-catalog` · `databricks-iceberg`
Orchestration & deploy: `databricks-jobs` · `databricks-bundles`
Platform & tooling: `databricks-python-sdk` · `databricks-config` · `databricks-docs` · `databricks-synthetic-data-gen`
Consumption & operational: `databricks-aibi-dashboards` · `databricks-genie` · `databricks-lakebase-provisioned` · `databricks-lakebase-autoscale`

## Commands reference

| Command | Usage |
|---------|-------|
| `/de:scaffold-pipeline` | Scaffold bronze→silver→job for a new data source |
| `/de:inspect-generate-validate` | Inspect table → generate pipeline code → validate output |
| `/de:dbx-debug-job` | Debug a failing job run: get error, diagnose, propose fix |

## Agents reference

Autonomous subagents that run in their **own context window** and take a multi-step task
off your hands end-to-end. Unlike the slash commands (which you drive step-by-step in your
main context), these fire-and-forget: they inspect, generate/fix, write, and validate
on their own, returning only the result. Both operate **within the existing hooks** — the
destructive-op guard and pre-commit pytest gate still apply.

| Agent | When it triggers | What it does autonomously |
|-------|------------------|---------------------------|
| `databricks-medallion-scaffolder` | "scaffold a pipeline for `catalog.bronze.orders`", "build bronze→silver→gold for `<source>`" | Inspects real schema via MCP → samples data → generates PySpark to repo conventions → writes pipeline + test → runs and validates output. Orchestrates the bronze_ingestion / silver_transformation / quality_auditor skills. Stops only on a breaking schema change (emits the migration). |
| `databricks-job-debugger` | "the `<job>` failed, fix it", "debug job run `<id>`" | Fetches runs → pulls noisy logs (kept in its own context) → finds root cause → applies the fix → re-runs the affected job to validate. Returns 3-line root cause + fix + validation result. Orchestrates spark_debug / spark_patterns / databricks-jobs. |

Invoke explicitly with the Agent tool, or just describe the task — the `description`
metadata lets Claude auto-dispatch them.

## Hook configuration

| Hook | Type | Purpose |
|------|------|---------|
| `pre_commit_guard.py` | PreToolUse (Bash) | Runs pytest before git commit; blocks on failure |
| `destructive_op_guard.py` | PreToolUse (Bash/Write/Edit) | Blocks DROP TABLE, rm -rf, TRUNCATE, DELETE without WHERE |
| `sqlfluff_guard.py` | PostToolUse (Write/Edit) | Auto-formats .sql files with sparksql dialect |
| `extract_learnings.py` | Stop | Summarizes DE sessions into docs/learnings/ |

### Hook environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TEST_PATH` | `tests/` | Directory for `pre_commit_guard` to run pytest against |
| `LEARNINGS_DIR` | `docs/learnings/` | Output directory for `extract_learnings` session summaries |
| `ANTHROPIC_API_KEY` | — | Required by `extract_learnings` for Claude API calls |

## Updates

```bash
git pull
./install.ps1   # Windows
./install.sh    # Mac/Linux
```
