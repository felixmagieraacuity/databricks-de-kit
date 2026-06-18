# Skill: Databricks Quality Auditor

## Purpose

This skill governs proactive code audits for PySpark, Lakeflow SDP (Spark Declarative Pipelines), and DLT pipelines in the Databricks Medallion architecture. It focuses on two domains the standard silver_transformation skill does not cover in depth: **strict schema evolution auditing** and **CDC (Change Data Capture) patterns native to Databricks**.

Activate this skill when the user asks to:
- Audit existing PySpark or DLT/SDP code for schema evolution correctness
- Implement CDC ingestion or propagation patterns on Databricks
- Review a pipeline for `mergeSchema` misuse or silent breaking changes
- Design a CDC architecture using Delta Change Data Feed or APPLY CHANGES INTO

**Stack constraints:** Databricks + Unity Catalog + Delta Lake only. No dbt, Snowflake, or Airflow.

---

## Part 1 — Schema Evolution Auditing

### The Two Categories of Schema Change

| Category | Examples | Correct Action |
|----------|----------|----------------|
| **Additive (safe)** | New nullable column, new table, widened numeric type | Allow with `mergeSchema = true` |
| **Breaking (dangerous)** | Column drop, type narrowing, rename, NOT NULL added, partition column change | Block pipeline; raise explicitly; require DDL migration |

### Audit Rule 1 — `mergeSchema` Must Never Be Used for Breaking Changes

`mergeSchema = true` handles only additive evolution. Using it during a breaking change silently corrupts downstream consumers.

**Audit check:** Search all pipeline code for `.option("mergeSchema", "true")`. For each occurrence, verify the preceding diff is purely additive.

```python
# CORRECT: additive — new nullable column arriving from upstream
df_silver.write \
    .format("delta") \
    .option("mergeSchema", "true") \
    .mode("overwrite") \
    .saveAsTable(SILVER_TABLE)

# WRONG: mergeSchema cannot handle a column drop or type change
# — the write succeeds but downstream readers break silently
```

**Detection helper — run before every write to a Silver/Gold table:**

```python
from delta.tables import DeltaTable
from pyspark.sql.types import StructType


def classify_schema_change(
    spark, table_fqn: str, df_new
) -> tuple[str, list[str]]:
    """
    Returns ('none'|'additive'|'breaking', [reasons]).
    Raises if the target table does not exist (first write — always safe).
    """
    if not DeltaTable.isDeltaTable(spark, table_fqn):
        return "none", []

    existing: StructType = spark.read.table(table_fqn).schema
    new: StructType = df_new.schema

    existing_map = {f.name: f for f in existing.fields}
    new_map = {f.name: f for f in new.fields}

    breaking, additive = [], []

    for name, old_field in existing_map.items():
        if name not in new_map:
            breaking.append(f"column dropped: {name}")
        elif old_field.dataType != new_map[name].dataType:
            breaking.append(
                f"type changed: {name} "
                f"{old_field.dataType} → {new_map[name].dataType}"
            )
        elif old_field.nullable and not new_map[name].nullable:
            breaking.append(f"nullable removed: {name}")

    for name in new_map:
        if name not in existing_map:
            additive.append(f"column added: {name}")

    category = "breaking" if breaking else ("additive" if additive else "none")
    return category, breaking + additive


# Usage before every write:
category, reasons = classify_schema_change(spark, SILVER_TABLE, df_silver)
if category == "breaking":
    raise RuntimeError(
        f"Breaking schema change detected for {SILVER_TABLE}.\n"
        f"Reasons: {reasons}\n"
        "Run a Delta table ALTER or migration notebook first."
    )
if category == "additive":
    write_opts = {"mergeSchema": "true"}
else:
    write_opts = {}
```

### Audit Rule 2 — SDP/DLT Schema Evolution

In Spark Declarative Pipelines, schema evolution is controlled at the pipeline level:

```python
import dlt  # SDP import

# Correct: schema evolution enabled pipeline-wide (additive only)
# Set in pipeline config: "configuration": {"pipelines.schemaEvolution": "additive"}

@dlt.table(
    name="silver_events",
    table_properties={"delta.enableChangeDataFeed": "true"},
)
def silver_events():
    return (
        dlt.read("bronze_events")
        # Explicit cast — never rely on implicit coercion
        .withColumn("event_ts", col("event_ts").cast("timestamp"))
    )
```

**Audit check for SDP:** Ensure `pipelines.schemaEvolution = additive` is set in the pipeline JSON config, and that no `@dlt.table` decorator uses `schema=` with a StructType that removes columns from the previous run.

### Audit Rule 3 — Partition Column Changes Are Always Breaking

Changing a Delta table's partition columns requires a full table rewrite. No `mergeSchema` flag handles this.

```python
# WRONG: cannot change partition from date to month without a rewrite
df.write.format("delta").partitionBy("event_month")  # was event_date

# CORRECT: explicit migration path
spark.sql(f"CREATE TABLE {NEW_TABLE} USING DELTA PARTITIONED BY (event_month) AS SELECT * FROM {OLD_TABLE}")
spark.sql(f"DROP TABLE {OLD_TABLE}")
spark.sql(f"ALTER TABLE {NEW_TABLE} RENAME TO {OLD_TABLE}")
```

---

## Part 2 — CDC Patterns Native to Databricks

Databricks provides three native CDC mechanisms. Choose based on pipeline type.

### Pattern A — APPLY CHANGES INTO (SDP/DLT — Preferred for Streaming CDC)

Use when the source is a CDC stream (Kafka, Kinesis, DMS) feeding a Lakeflow SDP pipeline. This is the highest-level abstraction and handles out-of-order events automatically.

```python
import dlt
from pyspark.sql.functions import col, expr

# 1. Ingest the raw CDC stream as a Bronze streaming table
@dlt.table(name="bronze_orders_cdc")
def bronze_orders_cdc():
    return (
        spark.readStream
        .format("cloudFiles")  # or kafka, kinesis
        .option("cloudFiles.format", "json")
        .load("abfss://landing@<storage>.dfs.core.windows.net/orders_cdc/")
    )

# 2. Apply changes to produce a Silver SCD Type 1 table
dlt.create_streaming_table(
    name="silver_orders",
    table_properties={"delta.enableChangeDataFeed": "true"},
)

dlt.apply_changes(
    target="silver_orders",
    source="bronze_orders_cdc",
    keys=["order_id"],                        # natural business key
    sequence_by=col("cdc_timestamp"),         # determines event ordering
    apply_as_deletes=expr("op = 'D'"),        # map DELETE operation code
    apply_as_truncates=expr("op = 'T'"),      # optional: map TRUNCATE
    except_column_list=["op", "cdc_timestamp", "_rescued_data"],
    stored_as_scd_type=1,                     # use 2 for full history
)
```

**Audit checks for APPLY CHANGES INTO:**
- `sequence_by` must point to a monotonically increasing column (source timestamp or LSN) — never use ingestion timestamp
- `keys` must match the upstream primary key exactly
- `apply_as_deletes` expression must be present; omitting it turns DELETEs into upserts silently

### Pattern B — Delta Change Data Feed (CDF) for Downstream Propagation

Use when a Silver table is already written and downstream Gold/serving layers need to consume only changed rows.

```python
# Enable CDF on the Silver table (do this at creation or via ALTER)
spark.sql(f"""
    ALTER TABLE {SILVER_TABLE}
    SET TBLPROPERTIES ('delta.enableChangeDataFeed' = 'true')
""")

# Read changes since a known version or timestamp
df_changes = (
    spark.read
    .format("delta")
    .option("readChangeFeed", "true")
    .option("startingVersion", last_processed_version)  # store in a control table
    .table(SILVER_TABLE)
)

# _change_type values: insert | update_preimage | update_postimage | delete
df_upserts = df_changes.filter(
    col("_change_type").isin("insert", "update_postimage")
)
df_deletes = df_changes.filter(col("_change_type") == "delete")
```

**Control table pattern — never hardcode version numbers:**

```python
CONTROL_TABLE = "catalog.ops_schema.cdf_checkpoints"

def get_last_version(spark, source_table: str) -> int:
    row = (
        spark.read.table(CONTROL_TABLE)
        .filter(col("source_table") == source_table)
        .select("last_version")
        .first()
    )
    return row["last_version"] if row else 0

def save_version(spark, source_table: str, version: int) -> None:
    spark.sql(f"""
        MERGE INTO {CONTROL_TABLE} t
        USING (SELECT '{source_table}' AS source_table, {version} AS last_version) s
        ON t.source_table = s.source_table
        WHEN MATCHED THEN UPDATE SET t.last_version = s.last_version
        WHEN NOT MATCHED THEN INSERT *
    """)
```

**Audit checks for CDF:**
- `delta.enableChangeDataFeed` must be set to `true` **before** the first write that should be tracked — retroactive enabling only captures future changes
- Always filter on `_change_type`; reading CDF without a filter returns duplicate rows (pre/post images)
- Checkpoint version must be persisted durably (control table, not in-memory)

### Pattern C — MERGE for Batch CDC Apply (Standard PySpark)

Use when CDC arrives as a batch snapshot diff (not streaming) and the target is a Unity Catalog Delta table.

```python
from delta.tables import DeltaTable

target = DeltaTable.forName(spark, SILVER_TABLE)
source = df_cdc_batch  # columns: natural_key, ..., op (I/U/D)

(
    target.alias("t")
    .merge(
        source.alias("s"),
        "t.order_id = s.order_id",  # join on natural key
    )
    .whenMatchedDelete(condition="s.op = 'D'")
    .whenMatchedUpdateAll(condition="s.op = 'U'")
    .whenNotMatchedInsertAll(condition="s.op = 'I'")
    .execute()
)
```

**Audit checks for MERGE-based CDC:**
- Always handle DELETE explicitly — `whenMatchedDelete` must be present if the source contains `D` records
- Verify the merge condition uses the full natural key (composite keys must include all components)
- Run a post-merge row count and compare to expected: `inserts + updates - deletes = net_delta`

---

## Part 3 — Proactive Audit Checklist

When auditing any PySpark or SDP pipeline, verify every item below:

### Schema Evolution
- [ ] `mergeSchema = true` is only present where schema change is provably additive
- [ ] Breaking changes (drop/rename/type) are blocked with a `RuntimeError` or explicit DDL migration
- [ ] Partition columns have not changed silently between pipeline runs
- [ ] SDP pipelines set `pipelines.schemaEvolution = additive` (not `evolutionMode = none` which blocks all evolution)
- [ ] `@dlt.table(schema=...)` is not used to silently redefine column types

### CDC Correctness
- [ ] APPLY CHANGES INTO: `sequence_by` is a source-system timestamp/LSN, not ingestion time
- [ ] APPLY CHANGES INTO: `apply_as_deletes` is defined — its absence silently converts DELETEs to upserts
- [ ] CDF readers: `_change_type` filter is applied before any aggregation or join
- [ ] CDF checkpoints: `startingVersion` is read from a durable control table, not hardcoded
- [ ] MERGE statements: DELETE case is handled; missing it leaks deleted rows into Silver/Gold

### Data Quality
- [ ] Row counts are validated after MERGE/APPLY CHANGES: `net_delta = inserts + updates - deletes`
- [ ] `delta.enableChangeDataFeed = true` is set on all Silver and Gold tables that feed downstream consumers
- [ ] Schema contract is documented as a StructType or DDL comment alongside each table definition
- [ ] Null handling for CDC operation column (`op`/`_change_type`) is explicit — unexpected values raise, not silently drop

---

## Anti-Patterns to Flag Immediately

| Anti-Pattern | Why It Fails | Correct Alternative |
|---|---|---|
| `mergeSchema=true` on a column-drop write | Delta accepts the write; downstream readers fail with AnalysisException | Classify change first; raise on breaking |
| CDF read without `_change_type` filter | Pre-image rows cause double-counting in aggregations | Always filter to `insert` + `update_postimage` |
| APPLY CHANGES with `sequence_by=current_timestamp()` | Out-of-order events re-processed at ingestion time will be misordered | Use source-side `cdc_timestamp` or LSN |
| MERGE missing `whenMatchedDelete` | Soft-deleted records survive in Silver indefinitely | Always include the delete clause for CDC merges |
| Storing CDF `startingVersion` in a Python variable | Version lost on cluster restart; CDC gap created | Persist to a Unity Catalog control table |
| Changing partition column without table rewrite | `mergeSchema` silently ignores the partition change; Hive metastore becomes inconsistent | Explicit CREATE-AS-SELECT + DROP + RENAME |
