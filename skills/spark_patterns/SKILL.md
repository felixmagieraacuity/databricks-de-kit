# Skill: Spark Patterns & Anti-Pattern Enforcement

## When This Skill Activates
- Writing or reviewing any PySpark transformation code
- JOIN operations, aggregations, window functions, or GROUP BY logic
- Performance review or optimization requests ("optimize this", "this is slow")
- Generating new pipeline stages (Bronze, Silver, or Gold)
- Any code involving DataFrame actions (collect, toPandas, count, show)
- Requests involving Delta table writes or MERGE operations
- Schema validation, type enforcement, or null handling code

---

## Core Mandate
Every PySpark snippet you write or review MUST be validated against this anti-pattern matrix. If a violation is detected in existing code, flag it and provide the corrected version. Never silently write bad Spark.

---

## Anti-Pattern Detection Matrix

### CRITICAL — Block immediately, rewrite before continuing

**1. Unbounded `collect()` or `toPandas()`**
```python
# BAD — pulls entire dataset to driver; OOM on large tables
results = df.collect()
pdf = df.toPandas()

# GOOD — push computation into Spark, collect only aggregates
results = df.agg(F.count("*"), F.sum("fare_amount")).collect()
# OR: write to Delta and query via SQL
```
Rule: `collect()` and `toPandas()` are only acceptable after an explicit `.limit(N)` or on DataFrames confirmed to be small (e.g., lookup tables < 10k rows). Always verify upstream filtering exists.

---

**2. Python loops iterating over rows**
```python
# BAD — row-by-row is serial; destroys parallelism
for row in df.collect():
    process(row["fare_amount"])

# GOOD — vectorized operations stay distributed
df = df.withColumn("processed", F.udf(process_udf)(F.col("fare_amount")))
# BETTER — eliminate UDF entirely with native Spark functions
df = df.withColumn("processed", F.when(F.col("fare_amount") > 0, ...).otherwise(...))
```

---

**3. Missing broadcast on small-table JOINs**
```python
# BAD — shuffle join on large table × small lookup
df_enriched = df_trips.join(df_zip_lookup, on="zip_code", how="left")

# GOOD — broadcast hint eliminates shuffle for the small side
from pyspark.sql.functions import broadcast
df_enriched = df_trips.join(broadcast(df_zip_lookup), on="zip_code", how="left")
```
Rule: Any lookup/dimension table < ~10MB (typically < 100k rows for simple schemas) must be broadcast. Add the hint explicitly — never rely on Spark's auto-broadcast threshold alone.

---

**4. Cartesian product from missing JOIN key**
```python
# BAD — cross join producing n × m rows; usually a bug
df_result = df_a.join(df_b)  # no ON clause

# GOOD — always specify join predicate
df_result = df_a.join(df_b, df_a.id == df_b.ref_id, how="inner")
```
Flag any `.join()` call without an explicit join condition.

---

**5. Non-partitioned Delta writes**
```python
# BAD — single-partition write; read performance degrades with table growth
df.write.format("delta").mode("overwrite").save(target_path)

# GOOD — partition by a low-cardinality, query-time filter column
df.write \
    .format("delta") \
    .mode("overwrite") \
    .option("partitionOverwriteMode", "dynamic") \
    .partitionBy("pickup_date") \
    .saveAsTable(target_fqn)
```
Partition column rules: use a date/timestamp-derived column (daily or monthly granularity), never partition on high-cardinality columns (IDs, UUIDs). For Silver/Gold: `event_date`, `report_month`, `ingestion_date`.

---

**6. Non-idempotent writes using plain `append`**
```python
# BAD — re-running the job duplicates every row
df.write.format("delta").mode("append").saveAsTable(target_fqn)

# GOOD option A — MERGE on natural key (dedup at write time)
spark.sql(f"""
    MERGE INTO {target_fqn} AS target
    USING staging AS source
    ON target.natural_key = source.natural_key
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")

# GOOD option B — partition overwrite (idempotent for date-partitioned tables)
df.write \
    .format("delta") \
    .mode("overwrite") \
    .option("partitionOverwriteMode", "dynamic") \
    .partitionBy("event_date") \
    .saveAsTable(target_fqn)
```

---

**7. Schema-on-read without enforcement**
```python
# BAD — implicit schema drift silently corrupts downstream tables
df = spark.read.format("json").load(source_path)

# GOOD — explicit StructType + enforce schema
from pyspark.sql.types import StructType, StructField, StringType, DoubleType, TimestampType

schema = StructType([
    StructField("trip_id", StringType(), nullable=False),
    StructField("fare_amount", DoubleType(), nullable=True),
    StructField("pickup_datetime", TimestampType(), nullable=False),
])
df = spark.read.format("json").schema(schema).load(source_path)
```

---

**8. Implicit type coercion in JOIN predicates**
```python
# BAD — Spark promotes types silently; JOIN may miss matches or cartesian
df_trips.join(df_lookup, df_trips.zip_code == df_lookup.zip_id)
# If zip_code is StringType and zip_id is IntegerType — implicit cast, potential full scan

# GOOD — explicit cast before JOIN to guarantee type alignment
df_trips = df_trips.withColumn("zip_code", F.col("zip_code").cast(StringType()))
df_lookup = df_lookup.withColumn("zip_id", F.col("zip_id").cast(StringType()))
df_enriched = df_trips.join(broadcast(df_lookup), df_trips.zip_code == df_lookup.zip_id, "left")
```

---

**9. Missing `enableChangeDataFeed` on Silver/Gold tables**
```python
# BAD — CDC queries on Delta table fail silently
df.write.format("delta").saveAsTable("silver.trips")

# GOOD — enable CDF at table creation for all Silver and Gold tables
df.write \
    .format("delta") \
    .option("delta.enableChangeDataFeed", "true") \
    .saveAsTable("silver.trips")
```

---

**10. `count()` actions inside transformation chains**
```python
# BAD — triggers a full distributed scan mid-transformation; blocks the driver
input_count = df.count()  # action inside transform function
df_filtered = df.filter(F.col("fare_amount") > 0)
filtered_count = df_filtered.count()  # second full scan

# GOOD — collect counts as a side-effect after the transformation is complete
df_result = df.filter(F.col("fare_amount") > 0)
# Count once, at the end, after writing (or inside assertions block)
output_count = df_result.count()
```
Exception: Counts in post-write assertion blocks are acceptable — they run once after the pipeline completes.

---

## Databricks-Specific Optimizations

### OPTIMIZE and ZORDER
Run after bulk loads or large MERGE operations to improve read performance:
```sql
-- After loading a partitioned Silver table
OPTIMIZE silver.nyctaxi_trips ZORDER BY (pickup_zip, dropoff_zip);

-- For time-series queries: ZORDER on the most selective filter column
OPTIMIZE gold.daily_revenue ZORDER BY (report_date, borough);
```
When to apply: after any job that writes > 1M rows, weekly on high-churn tables, never inside the streaming write path.

### Liquid Clustering (Databricks Runtime 13.3+)
Prefer over Hive-style partitioning for tables > 1TB or with multiple common filter patterns:
```sql
CREATE TABLE silver.events
CLUSTER BY (event_date, user_id)
TBLPROPERTIES ('delta.enableDeletionVectors' = 'true');
```
Liquid clustering self-tunes; no `OPTIMIZE ZORDER` needed. Use Hive partitioning only for tables where partition pruning eliminates > 90% of data on every query.

### ANALYZE TABLE for Query Statistics
After initial load and periodically for tables with skewed data:
```sql
ANALYZE TABLE silver.nyctaxi_trips COMPUTE STATISTICS FOR ALL COLUMNS;
```
This feeds the Spark optimizer cost-based planning; especially important before complex multi-table JOINs.

### Photon-Aware Operations
Photon (Databricks' vectorized query engine) accelerates:
- Native Spark SQL functions (`F.col`, `F.when`, `F.lit`, window functions)
- Delta reads and writes
- Joins and aggregations using built-in operators

Photon does NOT accelerate:
- Python UDFs (use Pandas UDFs / `applyInPandas` instead for vectorization)
- `mapPartitions` with arbitrary Python logic
- `RDD` operations

Rule: Always prefer native Spark SQL functions over custom Python UDFs. If a UDF is unavoidable, use `@pandas_udf` (vectorized) instead of `@udf` (row-at-a-time).

```python
# BAD — row-at-a-time UDF, bypasses Photon
@F.udf(returnType=StringType())
def normalize_borough(s):
    return s.strip().title() if s else None

# GOOD — native Spark SQL, Photon-accelerated
df = df.withColumn("borough", F.initcap(F.trim(F.col("borough"))))

# ACCEPTABLE when logic is complex — Pandas UDF (vectorized, Photon-partial)
@F.pandas_udf(StringType())
def complex_normalize(s: pd.Series) -> pd.Series:
    return s.str.strip().str.title()
```

---

## Medallion Architecture Guard-Rails

### Bronze Layer Rules
- Store raw data **exactly as received** — no type coercion, no value transformation
- Mandatory audit columns: `_source_file STRING`, `_ingested_at TIMESTAMP`, `_ingestion_job_id STRING`
- Write mode: append-only (or idempotent MERGE on `_source_file`) — never overwrite raw data
- No filtering, no enrichment, no business logic

### Silver Layer Rules
- Read ONLY from Bronze — never read from external sources or other Silver tables in the same pipeline
- Enforce types explicitly (`cast(DoubleType())`) before filtering
- Deduplicate on natural business key — never on synthetic IDs
- Enrich via broadcast JOINs to dimension tables
- Write with `enableChangeDataFeed=true` and `mergeSchema=true`
- Run post-write assertions before returning (fail fast)

### Gold Layer Rules
- Read from Silver (or other Gold) — never from Bronze
- Aggregate to business-level granularity (daily, weekly, by region, by product)
- Schema is presentation-ready: human-readable column names, documented nullability
- SCD Type 2 patterns for slowly-changing dimensions
- Never contain raw row-level data

### Cross-Layer Violation
```python
# FORBIDDEN — Gold reading directly from Bronze
df_gold = spark.table("bronze.raw_events")  # VIOLATION

# CORRECT — Gold reads from Silver
df_gold = spark.table("silver.events")
```

---

## Required Code Structure for New Pipelines

Every new transformation function must follow this signature pattern:

```python
def transform(df_input: DataFrame, spark: SparkSession) -> DataFrame:
    """Applies <layer> transformation to <entity>."""
    # 1. Count input
    input_count = df_input.count()

    # 2. Enforce types
    df = df_input.withColumn("col", F.col("col").cast(DoubleType()))

    # 3. Filter (business rules)
    df = df.filter(F.col("amount") > 0)

    # 4. Deduplicate (Silver/Gold only)
    df = df.dropDuplicates(["natural_key_col1", "natural_key_col2"])

    # 5. Enrich via broadcast JOIN (if needed)
    df = df.join(broadcast(lookup_df), on="join_key", how="left")

    # 6. Derive computed columns
    df = df.withColumn("derived_col", F.datediff(...))

    # 7. Post-transform assertions
    output_count = df.count()
    assert output_count > 0, "Transformation produced no rows"
    assert df.filter(F.col("amount") < 0).count() == 0, "Negative amounts found"

    return df
```

Separate entry point handles Databricks-specific I/O:
```python
def main():
    catalog = dbutils.widgets.get("catalog")
    schema = dbutils.widgets.get("schema")
    # ... read, call transform(), write
```

---

## Testing Requirements

Every `transform()` function requires a corresponding pytest test covering:
1. The primary happy path
2. Each filter rule (one test per filter condition)
3. Deduplication behavior
4. NULL handling for enrichment JOINs
5. Derived column correctness

Test structure:
```python
# conftest.py — session-scoped SparkSession
@pytest.fixture(scope="session")
def spark():
    return SparkSession.builder.master("local[2]").appName("test").getOrCreate()

# test_<entity>.py
def test_negative_fare_is_filtered(spark):
    data = [(-10.0, "2024-01-01"), (5.0, "2024-01-01")]
    df = spark.createDataFrame(data, ["fare_amount", "pickup_date"])
    result = transform(df, spark)
    assert result.count() == 1
    assert result.first()["fare_amount"] == 5.0
```
