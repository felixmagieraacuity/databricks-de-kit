---
name: inspect-generate-validate
description: Core workflow — inspect a table, generate pipeline code, validate output
---

Run the inspect→generate→validate workflow for a Databricks table.

**Step 1 — Inspect**
Use MCP tools to understand the data:
- `list_tables` on the target schema
- `get_table_info` on the target table (schema, columns, partitions, stats)
- `execute_sql`: `SELECT * FROM {table} LIMIT 10`
- `execute_sql`: `SELECT COUNT(*), COUNT(DISTINCT {pk_column}) FROM {table}` for cardinality

**Step 2 — Sample and profile**
- Check for nulls: `SELECT COUNT(*) - COUNT({col}) AS nulls FROM {table}` for key columns
- Check for anomalies in numeric columns (negative values, outliers)
- Report findings before generating any code

**Step 3 — Generate**
Based on the inspection, generate the appropriate pipeline code:
- Use @bronze_ingestion skill for raw→bronze
- Use @silver_transformation skill for bronze→silver transforms
- Use @spark_patterns skill for all PySpark idioms
- Add data quality expectations as assert statements

**Step 4 — Validate**
After generating, verify the output:
- Run `execute_sql` on the output table: row count > 0, no nulls in key columns
- Check the assertions pass
- Report: rows in, rows out, any rows filtered with reason
