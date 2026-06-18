---
name: scaffold-pipeline
description: Scaffold a complete bronze→silver→job pipeline for a new data source
---

Scaffold a new Databricks medallion pipeline for a data source. Follow these steps:

1. Ask the user for: catalog name, schema name, source table name, target silver schema
2. Use MCP tools to inspect the source table:
   - `list_tables` on the source schema
   - `get_table_info` on the source table
   - `execute_sql` to sample 5 rows: `SELECT * FROM {catalog}.{schema}.{table} LIMIT 5`
3. Generate bronze ingestion notebook using the @bronze_ingestion skill patterns:
   - Auto Loader or batch read depending on source type
   - Add `_ingested_at`, `_source_file`, `_batch_id` metadata columns
   - Write to Delta with merge schema enabled
4. Generate silver transformation notebook using the @silver_transformation skill:
   - Data quality filters (nulls, duplicates, business rules)
   - Add derived columns, cast types, normalize names
   - Write expectations as assertions
5. Generate Databricks Asset Bundle job YAML:
   - Two tasks: bronze_ingest → silver_transform
   - Serverless compute
   - Daily schedule at 03:00 UTC
   - Named {source_table}_pipeline
6. Validate: run `execute_sql` to verify the silver table was created and has rows

Apply the @spark_patterns skill for all PySpark code.
