# CLAUDE.md — Databricks Data Engineering

## Platform Overview
Production data platform built on Databricks with Medallion Architecture and Unity Catalog for governance and lineage tracking.

## Tech Stack
- **Platform**: Databricks (Unity Catalog)
- **Languages**: PySpark, SQL, Python
- **Architecture**: Medallion (Bronze → Silver → Gold)
- **Data Format**: Delta Lake (all tables)

## Environment Variables
Configure these before working on pipelines:
```
DATABRICKS_HOST    — workspace URL (e.g. https://your-workspace.azuredatabricks.net)
DATABRICKS_PROFILE — CLI profile name
DATABRICKS_CATALOG — target catalog (e.g. your_catalog)
DATABRICKS_SCHEMA  — default schema
```

## Medallion Architecture Rules

### Bronze Layer
- **Purpose**: Raw data ingestion — immutable archive
- **Constraints**:
  - Minimal transformation — no cleansing, no business rules
  - Schema enforcement enabled; keep source types as-is (strings for amounts/dates)
  - Preserve source system metadata via audit columns
  - No deduplication — source may re-send valid updates
  - Mandatory audit columns: `_source_file`, `_ingested_at`, `_ingestion_job_id`

### Silver Layer
- **Purpose**: Cleansed, standardized data
- **Transformations**:
  - Data type standardization (cast from Bronze strings to target types)
  - Deduplication by natural/business keys only
  - Null value handling with explicit assertions
  - Broadcast JOINs for dimension enrichment
  - Outlier detection and business rule filtering

### Gold Layer
- **Purpose**: Business-ready analytics
- **Outputs**:
  - Business aggregations and KPIs
  - Dimensional models (star schema)
  - Time-series snapshots
  - Never contains raw row-level data

## Code Conventions

### Naming & Organization
- `snake_case` for all table and column names
- Unity Catalog fully qualified names: `catalog.schema.table`
- No hardcoded paths — always parameterize via `dbutils.widgets` or env vars
- Bronze tables: `<catalog>.bronze.<source_system>_<entity>`
- Silver tables: `<catalog>.silver.<entity>` (logical name)
- Gold tables: `<catalog>.gold.fct_<fact>`, `<catalog>.gold.dim_<dimension>`

### PySpark Best Practices
- Prefer PySpark over SQL for complex logic
- Use SQL for window functions and CTEs where readability is better
- Always import explicitly — no `import *`
- Partition large tables by a low-cardinality date/month column
- Use `trigger(availableNow=True)` for batch-triggered streaming jobs

### Logging & Monitoring
Every transformation must log (use `logging` module, not `print`):
- Input row count
- Output row count
- Transformation duration in seconds
- Key metrics: null counts, duplicate counts per key column

```python
import logging, time
logger = logging.getLogger(__name__)

start = time.time()
input_count = df_bronze.count()
logger.info(f"[transform] input_count={input_count} source={BRONZE_TABLE}")
# ... transform ...
output_count = df_silver.count()
logger.info(f"[transform] output_count={output_count} duration_seconds={round(time.time()-start,2)}")
```

## Data Quality Standards

### Bronze→Silver Validation
- **Schema validation**: Enforce expected types on Bronze reads; raise on missing required columns
- **Null checks**: Assert NOT NULL on primary/foreign key columns after transformation
- **Duplicate detection**: Post-dedup uniqueness assertion must be present and raise on failure
- **Row count verification**: Log input vs. output; alert if output is 0

### Silver→Gold Validation
- **Aggregation reconciliation**: Sum/count checks between layers
- **Join cardinality**: Verify expected join cardinality (1:1 vs 1:N)
- **Key uniqueness**: Assert dimensional keys are unique

### Standard Validation Template
```python
input_count = df_source.count()
output_count = df_transformed.count()
null_count = df_transformed.filter(col("key_column").isNull()).count()

logger.info(f"input={input_count} output={output_count} nulls={null_count}")
assert output_count > 0, "Transformation produced no rows"
assert null_count == 0, "Key column contains nulls"
```

## Forbidden Patterns

### Memory & Performance
- `collect()` on large DataFrames — use `limit()` for samples only
- `toPandas()` without prior filtering/aggregation
- Unpartitioned writes of large tables (>1M rows)
- Cartesian joins — always specify join predicate and broadcast small side
- Python row-level loops over DataFrames — use Spark operations

### Code Quality
- `import *` statements
- Hardcoded credentials — use Databricks secrets: `dbutils.secrets.get(scope, key)`
- Hardcoded paths or catalog/schema names — parameterize via widgets
- Nested Python loops for DataFrame operations

### Data Governance
- Writing outside Unity Catalog (no raw DBFS paths)
- Sharing unvalidated data to Gold layer
- Missing data quality assertions on any pipeline output
- Transformations without lineage documentation

## Unity Catalog Patterns

### Standard Catalog Organization
```
<your_catalog>
├── bronze    — all raw ingested data
├── silver    — cleaned, deduplicated, typed
├── gold      — business-ready aggregations and dims
└── tools     — metadata, validation helpers, control tables
```

### Table Naming Examples
- Bronze: `your_catalog.bronze.salesforce_accounts`, `your_catalog.bronze.stripe_payments`
- Silver: `your_catalog.silver.fct_orders`, `your_catalog.silver.dim_customer`
- Gold: `your_catalog.gold.kpi_daily_revenue`
- Metadata: `your_catalog.tools.dq_validation_results`, `your_catalog.tools.cdf_checkpoints`

## Debugging & Common Issues

### Row Count Mismatches
- Check for soft deletes in source (`deleted_flag`, `is_active`, `status`)
- Verify join cardinality — a 1:N join inflates rows
- Look for duplicate keys in dimension/lookup tables
- Check Bronze for `_rescued_data` column — unexpected fields land there

### Performance Issues
- Run `df.explain()` to check physical plan before optimizing
- Partition strategy: partition by date column, never by high-cardinality ID
- Small files: `OPTIMIZE <table>` after bulk loads; set `autoCompact = true`
- Missing broadcast hint on small table joins causes shuffle; add `broadcast()`

### Schema Evolution
- Additive changes (new nullable columns): use `mergeSchema = true`
- Breaking changes (drop/rename/type change): raise `RuntimeError`; run explicit DDL migration
- Partition column changes require full table rewrite — never use `mergeSchema` for these

## Diagramming Rules
- Use **Mermaid `erDiagram` syntax** saved as `.md` files
- Never use PlantUML, Draw.io, or formats requiring separate tools
- File naming: `er_diagram_<dataset>.md` in `docs/`
- Every table: all columns with types, PKs marked, FKs marked
- Regenerate after every schema change — never maintain manually
