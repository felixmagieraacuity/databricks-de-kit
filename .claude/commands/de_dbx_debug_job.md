---
name: dbx-debug-job
description: Debug a failing Databricks job run — get error, diagnose, propose fix
---

Debug a failing Databricks job. Provide the job run ID or job name.

**Step 1 — Get run details**
Use MCP tools:
- `get_run` with the run ID to get run status and task details
- `get_run_output` to get the error message and stack trace

**Step 2 — Read failing code**
- Identify which task failed
- Read the notebook or script for that task
- Check the CLAUDE.md for relevant conventions and known anti-patterns

**Step 3 — Diagnose**
Analyze the error:
- Schema mismatch: column renamed, type changed, column dropped upstream?
- Data quality: null in non-nullable column, unexpected value range?
- Infrastructure: cluster OOM, timeout, network issue?
- Logic: wrong filter, incorrect join key, off-by-one in window function?

**Step 4 — Propose and validate fix**
- Propose the minimal fix with explanation
- Run `execute_sql` to validate the fix logic against sample data
- Do NOT push directly to production — present the fix for review first

Apply the @databricks_quality_auditor skill to check for data quality root causes.
