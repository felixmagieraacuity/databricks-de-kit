# Skill: Bronze Ingestion Patterns

## When This Skill Activates
- Scaffolding a new data ingestion pipeline
- Setting up Auto Loader (`cloudFiles`) for any source system
- Creating Bronze layer tables in Unity Catalog
- Handling raw file landing zones (JSON, CSV, Parquet, Avro, XML)
- Designing schema inference vs. enforcement strategies
- Setting up streaming ingestion with checkpoints
- Defining Unity Catalog volume structure for raw data
- Any request involving Bronze table creation or raw data landing

---

## Core Mandate
Bronze is the **immutable raw archive**. Its single job is to land data exactly as it arrived — no cleansing, no enrichment, no business logic. Every Bronze pipeline you generate must satisfy the Bronze Contract below. Violations must be flagged and corrected before any code is accepted.

---

## The Bronze Contract

### What Bronze IS
- A verbatim copy of the source data, preserved exactly as received
- An audit trail with provenance metadata on every row
- The single source of truth for replay and reprocessing

### What Bronze IS NOT
- A place for type coercion, null handling, or business rules (belongs in Silver)
- A place for deduplication or filtering (belongs in Silver)
- A place for derived columns or enrichment (belongs in Silver)

### Mandatory Audit Columns
Every Bronze table MUST include these columns, populated by the ingestion pipeline — never by the source system:

| Column | Type | Description |
|--------|------|-------------|
| `_source_file` | STRING | Full path to the source file (Auto Loader: `_metadata.file_path`) |
| `_ingested_at` | TIMESTAMP | UTC timestamp when the row was written |
| `_ingestion_job_id` | STRING | Databricks job run ID or pipeline ID for lineage |

```python
from pyspark.sql import functions as F

df = df.withColumn("_source_file", F.col("_metadata.file_path")) \
       .withColumn("_ingested_at", F.current_timestamp()) \
       .withColumn("_ingestion_job_id", F.lit(dbutils.notebook.entry_point.getDbutils().notebook().getContext().currentRunId().get()))
```

### Naming Convention
```
<catalog>.bronze.<source_system>_<entity>

Examples:
  main.bronze.salesforce_opportunities
  main.bronze.stripe_payments
  main.bronze.kafka_clickstream_events
  main.bronze.sftp_inventory_export
```
Always snake_case. Always fully qualified (catalog.schema.table).

---

## Unity Catalog Volume Structure

Raw files land in Unity Catalog Volumes (not DBFS). Standard layout:

```
/Volumes/<catalog>/bronze/
├── raw/                          # Landing zone — source files arrive here
│   ├── <source_system>/
│   │   └── <entity>/
│   │       ├── 2024/01/15/       # Date-partitioned subdirs (optional but recommended)
│   │       │   └── file.json
│   │       └── file.parquet
│
├── checkpoints/                  # Auto Loader / streaming checkpoints
│   └── <stream_name>/            # One checkpoint dir per stream
│
└── schema_hints/                 # Auto Loader schema tracking (cloudFiles.schemaLocation)
    └── <stream_name>/
```

Volume vs. DBFS tradeoffs:
- **Unity Catalog Volumes**: governed, auditable, supports fine-grained access control — use for all new pipelines
- **DBFS**: legacy, no Unity Catalog governance — only maintain existing; never create new Bronze on DBFS

---

## Auto Loader Patterns

### Standard Batch-Trigger Auto Loader (Recommended for most Bronze pipelines)

```python
from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import StructType, StructField, StringType, DoubleType, TimestampType

def ingest_bronze(
    spark: SparkSession,
    source_path: str,
    target_fqn: str,
    checkpoint_path: str,
    schema: StructType,
    source_format: str = "json",
) -> None:
    """Incrementally ingests raw files from source_path into Bronze Delta table."""

    df_stream = (
        spark.readStream
        .format("cloudFiles")
        .option("cloudFiles.format", source_format)
        .option("cloudFiles.schemaLocation", checkpoint_path + "/_schema")
        .option("cloudFiles.inferColumnTypes", "false")   # prefer explicit schema
        .option("maxFilesPerTrigger", 1000)               # rate control
        .schema(schema)
        .load(source_path)
    )

    # Add mandatory audit columns
    df_with_audit = (
        df_stream
        .withColumn("_source_file", F.col("_metadata.file_path"))
        .withColumn("_ingested_at", F.current_timestamp())
        .withColumn("_ingestion_job_id", F.lit(
            spark.conf.get("spark.databricks.clusterUsageTags.clusterOwnerOrgId", "local")
        ))
    )

    (
        df_with_audit.writeStream
        .format("delta")
        .option("checkpointLocation", checkpoint_path)
        .option("mergeSchema", "true")           # handle additive source schema changes
        .outputMode("append")
        .trigger(availableNow=True)              # process all available files, then stop
        .toTable(target_fqn)
    )
```

### Continuous Streaming (near-real-time, event-driven)

```python
(
    df_with_audit.writeStream
    .format("delta")
    .option("checkpointLocation", checkpoint_path)
    .option("mergeSchema", "true")
    .outputMode("append")
    .trigger(processingTime="30 seconds")        # micro-batch every 30s
    .toTable(target_fqn)
)
```

### Batch Ingestion (no streaming; full or incremental file load)

```python
def ingest_bronze_batch(
    spark: SparkSession,
    source_path: str,
    target_fqn: str,
    schema: StructType,
    source_format: str = "parquet",
) -> None:
    df = (
        spark.read
        .format(source_format)
        .schema(schema)
        .load(source_path)
        .withColumn("_source_file", F.input_file_name())
        .withColumn("_ingested_at", F.current_timestamp())
        .withColumn("_ingestion_job_id", F.lit("batch"))
    )

    # Idempotent write: overwrite by ingestion date partition
    (
        df.withColumn("_ingestion_date", F.to_date(F.col("_ingested_at")))
        .write
        .format("delta")
        .mode("overwrite")
        .option("partitionOverwriteMode", "dynamic")
        .option("mergeSchema", "true")
        .partitionBy("_ingestion_date")
        .saveAsTable(target_fqn)
    )
```

---

## Batch vs. Streaming Decision Matrix

| Criterion | Use Batch | Use Streaming |
|-----------|-----------|---------------|
| Source delivery | File drops (hourly/daily) | Kafka, Event Hubs, Kinesis |
| Latency requirement | > 1 hour acceptable | < 5 minutes required |
| File volume | Thousands of files | Millions of events |
| Re-processing | Partition overwrite sufficient | Checkpoint replay required |
| Typical sources | SFTP, S3 exports, API exports | CDC feeds, clickstream, IoT |

Default: use `trigger(availableNow=True)` (micro-batch) for most Bronze ingestion. It's simpler to operate than continuous streaming and handles late-arriving files naturally.

---

## Schema Handling Strategy

### Explicit Schema (preferred for production)
Always define the schema explicitly in Python. Never rely on schema inference in production Bronze pipelines — inferred types change when source systems update:

```python
raw_schema = StructType([
    StructField("id", StringType(), nullable=False),
    StructField("amount", StringType(), nullable=True),   # keep as string in Bronze; cast in Silver
    StructField("created_at", StringType(), nullable=True),  # keep as string; parse in Silver
    StructField("status", StringType(), nullable=True),
])
```

Note: Bronze intentionally stores amounts and timestamps as strings. Type enforcement happens in Silver. This preserves the raw source value even if it's malformed — allowing debugging and reprocessing without data loss.

### Rescued Data Column (handle unexpected fields gracefully)
```python
spark.readStream
    .format("cloudFiles")
    .option("cloudFiles.format", "json")
    .option("cloudFiles.schemaLocation", schema_location)
    .option("rescuedDataColumn", "_rescued_data")   # unexpected fields land here as JSON string
    .schema(known_schema)
    .load(source_path)
```
`_rescued_data` is a STRING column containing any fields not in your schema. Inspect it in Silver to decide whether schema evolution is needed.

### Schema Evolution Handling
```python
# Additive changes (new nullable columns from source): allow via mergeSchema
.option("mergeSchema", "true")

# Breaking changes (non-nullable column added, type changed): raise RuntimeError
# Add schema validation assertion after read:
expected_columns = {"id", "amount", "created_at", "status"}
actual_columns = set(df.columns) - {"_source_file", "_ingested_at", "_ingestion_job_id", "_rescued_data"}
missing = expected_columns - actual_columns
if missing:
    raise RuntimeError(f"Source schema missing required columns: {missing}")
```

---

## Idempotency Requirements

Bronze pipelines must be re-runnable without duplicating data.

### Streaming (Auto Loader): Idempotent by default
Auto Loader with a checkpoint tracks processed files. Re-running the same stream skips already-processed files. Guard: **never delete or move the checkpoint directory** without also clearing the Bronze table.

### Batch: Use partition overwrite or MERGE
```python
# Option A: partition overwrite by ingestion date (recommended for daily batch)
.option("partitionOverwriteMode", "dynamic")
.mode("overwrite")
.partitionBy("_ingestion_date")

# Option B: MERGE on source file path + row hash (for non-partitioned tables)
# Pre-compute hash of all source columns
df = df.withColumn("_row_hash", F.sha2(F.concat_ws("|", *source_cols), 256))

spark.sql(f"""
    MERGE INTO {target_fqn} AS target
    USING staging AS source
    ON target._source_file = source._source_file
   AND target._row_hash = source._row_hash
    WHEN NOT MATCHED THEN INSERT *
""")
```

---

## Forbidden Patterns in Bronze

| Pattern | Why Forbidden | Correct Location |
|---------|---------------|-----------------|
| `df.filter(F.col("status") == "active")` | Loses rejected rows; can't reprocess | Silver |
| `df.withColumn("amount", F.col("raw_amount").cast(DoubleType()))` | Type enforcement hides malformed source data | Silver |
| `df.dropDuplicates(["id"])` | Dedup discards records; source may re-send valid updates | Silver |
| `df.withColumn("full_name", F.concat(...))` | Derived columns are business logic | Silver/Gold |
| Streaming without `checkpointLocation` | Non-idempotent; duplicates on restart | Always required |
| Streaming without watermarks on unbounded streams | Memory leak; driver OOM on long-running jobs | Always required |
| Writing to DBFS (`/dbfs/...`) | No Unity Catalog governance | Unity Catalog Volumes |
| Hardcoded paths or credentials | Security violation; breaks across environments | Use `dbutils.widgets` + secrets |

---

## Full Scaffold Template

```python
"""
Bronze ingestion: <source_system> → <entity>
Target: <catalog>.bronze.<source_system>_<entity>
"""
import logging
from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import StructType, StructField, StringType

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


RAW_SCHEMA = StructType([
    # TODO: define fields — keep all as StringType in Bronze
    StructField("id", StringType(), nullable=False),
])


def ingest(spark: SparkSession, source_path: str, target_fqn: str, checkpoint_path: str) -> None:
    logger.info(f"[BRONZE] Starting ingestion → {target_fqn}")

    df_stream = (
        spark.readStream
        .format("cloudFiles")
        .option("cloudFiles.format", "json")
        .option("cloudFiles.schemaLocation", f"{checkpoint_path}/_schema")
        .option("rescuedDataColumn", "_rescued_data")
        .schema(RAW_SCHEMA)
        .load(source_path)
        .withColumn("_source_file", F.col("_metadata.file_path"))
        .withColumn("_ingested_at", F.current_timestamp())
        .withColumn("_ingestion_job_id", F.lit(spark.conf.get(
            "spark.databricks.clusterUsageTags.clusterOwnerOrgId", "local"
        )))
    )

    query = (
        df_stream.writeStream
        .format("delta")
        .option("checkpointLocation", checkpoint_path)
        .option("mergeSchema", "true")
        .outputMode("append")
        .trigger(availableNow=True)
        .toTable(target_fqn)
    )
    query.awaitTermination()
    logger.info(f"[BRONZE] Ingestion complete → {target_fqn}")


def main():
    catalog = dbutils.widgets.get("catalog")
    source_system = dbutils.widgets.get("source_system")
    entity = dbutils.widgets.get("entity")

    target_fqn = f"{catalog}.bronze.{source_system}_{entity}"
    source_path = f"/Volumes/{catalog}/bronze/raw/{source_system}/{entity}/"
    checkpoint_path = f"/Volumes/{catalog}/bronze/checkpoints/{source_system}_{entity}"

    spark = SparkSession.builder.getOrCreate()
    ingest(spark, source_path, target_fqn, checkpoint_path)


if __name__ == "__main__":
    main()
```
