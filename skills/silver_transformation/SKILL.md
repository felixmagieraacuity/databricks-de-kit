# Skill: Silver Transformation (PySpark Data Engineer)

## Purpose

This skill governs all code generation, review, and guidance for Bronze→Silver layer transformations in a Medallion architecture. It applies PySpark best practices aligned with the project's CLAUDE.md standards and ETL Specialist conventions from the `awesome-claude-code-toolkit`.

Activate this skill when the user asks to:
- Write or refactor a Silver-layer PySpark transformation
- Build a deduplication, cleansing, or standardisation pipeline
- Review an existing Bronze→Silver job for correctness or quality
- Scaffold a new Silver table or pipeline task

---

## Mandatory Code Generation Rules

The following rules are **non-negotiable**. Every code artefact produced under this skill must comply with all six.

---

### 1. Architecture — Medallion Layer Boundaries

- **Read exclusively from Bronze** layer tables. Never read from raw files, external sources, or Silver/Gold tables within the same pipeline step.
- **Write exclusively to Silver** layer tables. Never overwrite Bronze data or write directly to Gold.
- Use explicit, clearly named variables for source and target to make the data flow self-documenting:

```python
BRONZE_TABLE = "catalog.bronze_schema.table_name"
SILVER_TABLE = "catalog.silver_schema.table_name"

df_bronze = spark.read.table(BRONZE_TABLE)
# ... transformation logic ...
df_silver.write.format("delta").mode("overwrite").saveAsTable(SILVER_TABLE)
```

---

### 2. Idempotency — Safe Re-runs with No Duplicates

- All pipeline tasks **must be idempotent**: re-running with the same input must produce byte-for-byte identical output.
- Use `MERGE` (Delta `merge`) or `INSERT OVERWRITE` with explicit partition predicates — never plain `append`.
- Partition keys must be **deterministic** (derived from the data, not from `current_timestamp()` or UUIDs generated at runtime).
- Prefer date-based or business-key-based partitions:

```python
(
    df_silver.write
    .format("delta")
    .mode("overwrite")
    .option("replaceWhere", "partition_date = '2024-01-15'")  # deterministic predicate
    .partitionBy("partition_date")
    .saveAsTable(SILVER_TABLE)
)
```

- If using Delta `merge`, always include a full `MATCHED` / `NOT MATCHED` clause so every re-run converges to the same state.

---

### 3. Business Logic — Deduplication via Natural Business Key

- Deduplication **must** use the domain's natural business key — never rely on surrogate keys, ingestion timestamps, or row-number tricks alone.
- Identify the natural key explicitly in code comments and select it before any windowing:

```python
NATURAL_KEY = ["order_id", "customer_id"]  # <-- document the key

from pyspark.sql import Window
from pyspark.sql.functions import row_number, desc

window = Window.partitionBy(*NATURAL_KEY).orderBy(desc("ingestion_timestamp"))
df_deduped = (
    df_bronze
    .withColumn("_rn", row_number().over(window))
    .filter("_rn = 1")
    .drop("_rn")
)
```

- Validate uniqueness of the natural key **after** deduplication and fail fast if duplicates remain:

```python
dupe_count = df_deduped.groupBy(*NATURAL_KEY).count().filter("count > 1").count()
assert dupe_count == 0, f"Deduplication failed: {dupe_count} duplicate key groups remain"
```

---

### 4. Storage & Naming — Delta Tables via Unity Catalog

- All output tables must be saved as **Delta format** using the three-part Unity Catalog fully qualified name: `catalog.schema.table`.
- Never use relative paths, DBFS paths (`dbfs:/`), or unqualified table names.
- Enforce `delta.enableChangeDataFeed` on Silver tables to support downstream CDC:

```python
spark.sql(f"""
    CREATE TABLE IF NOT EXISTS {SILVER_TABLE} (
        -- schema definition
    )
    USING DELTA
    TBLPROPERTIES (
        'delta.enableChangeDataFeed' = 'true',
        'delta.autoOptimize.optimizeWrite' = 'true',
        'delta.autoOptimize.autoCompact' = 'true'
    )
    PARTITIONED BY (partition_date DATE)
""")
```

- Column and table names must use `snake_case` throughout.

---

### 5. Observability — Structured Logging

Every transformation must emit structured log lines covering the four required metrics. Use Python's `logging` module (not `print`):

```python
import logging
import time
from pyspark.sql.functions import col, count, isnull

logger = logging.getLogger(__name__)

# --- Input count ---
start_time = time.time()
input_count = df_bronze.count()
logger.info(f"[silver_transform] input_count={input_count} source={BRONZE_TABLE}")

# --- Null counts (per nullable column) ---
nullable_cols = ["email", "phone_number"]
for c in nullable_cols:
    null_count = df_bronze.filter(isnull(col(c))).count()
    logger.info(f"[silver_transform] null_count column={c} count={null_count}")

# --- Duplicate count (pre-dedup) ---
dupe_count_pre = df_bronze.count() - df_bronze.dropDuplicates(NATURAL_KEY).count()
logger.info(f"[silver_transform] duplicate_count_pre_dedup={dupe_count_pre}")

# ... transformation ...

# --- Output count ---
output_count = df_silver.count()
duration_s = round(time.time() - start_time, 2)
logger.info(
    f"[silver_transform] output_count={output_count} "
    f"target={SILVER_TABLE} duration_seconds={duration_s}"
)
```

Log lines must be emitted in a consistent, parseable format (`key=value`) to enable downstream log aggregation and alerting.

---

### 6. Schema Evolution — Additive vs. Breaking Changes

- **Additive changes** (new nullable columns, new tables): handle automatically using Delta's `mergeSchema` option:

```python
df_silver.write.format("delta").option("mergeSchema", "true").mode("overwrite").saveAsTable(SILVER_TABLE)
```

- **Breaking changes** (column drops, type changes, column renames, non-nullable constraint additions): these must **never** be applied silently. Trigger an alert instead:

```python
from delta.tables import DeltaTable

def detect_breaking_schema_change(spark, table_name: str, df_new) -> bool:
    if not DeltaTable.isDeltaTable(spark, table_name):
        return False
    existing_schema = spark.read.table(table_name).schema
    new_schema = df_new.schema
    existing_fields = {f.name: f.dataType for f in existing_schema.fields}
    for field in new_schema.fields:
        if field.name in existing_fields and existing_fields[field.name] != field.dataType:
            return True  # type mismatch = breaking
    removed = set(existing_fields.keys()) - {f.name for f in new_schema.fields}
    return len(removed) > 0  # column removal = breaking

if detect_breaking_schema_change(spark, SILVER_TABLE, df_silver):
    raise RuntimeError(
        f"Breaking schema change detected for {SILVER_TABLE}. "
        "Review the schema diff, update the table definition explicitly, and re-run."
    )
```

- Document nullable vs. non-nullable columns in the table DDL and in the lineage mapping.

---

## Quality Gates & Hooks

For every Silver transformation task, **always suggest** that the user configures the following local Claude Code Hooks in `.claude/settings.json`. These gates enforce correctness and consistency before code reaches the repository.

### Hook 1 — Pre-Commit: Run `pytest` on Transformation Logic

Runs the full transformation test suite before allowing a commit. The commit is blocked if any test fails.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "pytest tests/ -q --tb=short",
            "when": "git commit"
          }
        ]
      }
    ]
  }
}
```

Recommended test structure for Silver transformations:

```
tests/
├── conftest.py               # SparkSession fixture (local mode)
├── silver/
│   ├── test_deduplication.py # Assert natural key uniqueness post-transform
│   ├── test_null_handling.py  # Assert nullable columns are documented
│   ├── test_idempotency.py    # Run transform twice; assert identical output
│   └── test_schema.py         # Assert output schema matches contract
```

Every `pytest` run must include an idempotency test: apply the transformation twice to the same fixture data and assert the output DataFrames are identical.

### Hook 2 — On Save: `sqlfluff` Linting & Formatting

Lints and auto-formats any `.sql` file on save, enforcing consistent style across all SQL artefacts (views, DDL, MERGE statements).

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "sqlfluff fix --dialect sparksql \"${file}\""
          }
        ]
      }
    ]
  }
}
```

Recommended `.sqlfluff` configuration at the repo root:

```ini
[sqlfluff]
dialect = sparksql
templater = jinja
max_line_length = 120
indent_unit = space
tab_space_size = 4

[sqlfluff:rules:layout.indent]
indent_unit = space

[sqlfluff:rules:capitalisation.keywords]
capitalisation_policy = upper
```

### Suggested Full `settings.json` Hook Block

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "pytest tests/ -q --tb=short"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "sqlfluff fix --dialect sparksql \"${file}\""
          }
        ]
      }
    ]
  }
}
```

> **Note**: Hook syntax may vary across Claude Code versions. Use `/update-config` or the `update-config` skill to apply these hooks safely via the settings management tooling, which will validate the JSON structure before writing.

---

## Checklist — Before Marking a Transformation Complete

Before declaring any Silver transformation task done, verify each item:

- [ ] Reads only from a Bronze Unity Catalog table
- [ ] Writes only to a Silver Unity Catalog table (`catalog.schema.table`)
- [ ] Output is Delta format with `enableChangeDataFeed` enabled
- [ ] Partition key is deterministic and documented
- [ ] Write mode is idempotent (`replaceWhere` or `merge`, never plain `append`)
- [ ] Deduplication uses the natural business key
- [ ] Post-dedup uniqueness assertion is present and will raise on failure
- [ ] Input count, output count, duration, null counts, and dupe counts are all logged
- [ ] Additive schema changes use `mergeSchema = true`
- [ ] Breaking schema changes raise a `RuntimeError` with a clear message
- [ ] `pytest` tests cover deduplication, idempotency, null handling, and schema contract
- [ ] SQL artefacts pass `sqlfluff` with `dialect = sparksql`
- [ ] No hardcoded credentials, DBFS paths, or implicit type conversions
