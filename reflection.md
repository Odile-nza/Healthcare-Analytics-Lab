# Reflection: OLTP to Star Schema — Healthcare Analytics
# ========================================================
# All performance figures are real measured values from
# EXPLAIN ANALYZE on 10000-encounter datasets in PostgreSQL
# ========================================================

---

## 1. Why Is the Star Schema Faster?

The star schema outperforms the normalized OLTP schema for
analytical queries through three mechanisms: fewer joins,
pre-computed data, and better indexing. However our testing
revealed an important nuance — the advantage depends heavily
on query type and data volume.

### Fewer Joins
Query 4 demonstrated this most clearly. The OLTP schema
required traversing billing → encounters → providers →
specialties (3 joins, 4 tables) just to answer "how much
revenue by specialty per month?" Every billing row had to
travel through two intermediate tables to attach a specialty
name. The star schema stores total_allowed_amount directly
in fact_encounters — the billing table is never touched.
Result: 28.519ms dropped to 10.085ms — 2.8x faster.

Similarly Query 1 needed encounters → providers → specialties
(2 hops) just to get specialty_name. The star schema stores
specialty_key directly on the fact table — one hop instead
of two. The Hash Join time dropped from 45.386ms to 4.922ms
— 9x faster for that step alone.

### Pre-Computed Data
The most impactful pre-computation was the dim_date dimension.
OLTP Queries 1 and 4 both called TO_CHAR() on datetime
columns — a function executed on every single row before
grouping could happen. At 10000 rows this adds measurable
overhead. At 1 million rows it becomes a serious bottleneck.
The dim_date dimension pre-stores year, month, month_name,
quarter as plain columns. Queries read d.year and d.month
— simple column lookups with zero function overhead.

The is_readmission boolean flag is the most strategically
important pre-computation. Query 3 revealed that the OLTP
self-join removed 33888 rows at 10000 encounters. The
complexity is O(n²) — it grows with the square of data
volume. Pre-computing this flag during ETL moves the
expensive work to the nightly batch load where it runs once.
Every analyst who queries readmissions gets instant results
from a simple SUM(CASE WHEN is_readmission) scan.

### Better Indexing
All dimension foreign keys in the fact table are indexed
integer surrogate keys. Joining on integers is faster than
joining on strings. The OLTP schema joined on natural keys
like encounter_type VARCHAR(50) while the star schema joins
on encounter_type_key INT — a significant difference at scale.

---

## 2. Trade-offs: What Did We Gain? What Did We Lose?

### What We Gained

Query performance for analytical workloads improved
meaningfully for two of the four queries tested. Query 1
ran 2.2x faster and Query 4 ran 2.8x faster on the same
10000-row dataset. Query 4 also showed a 2.2x reduction
in planning time (59ms to 27ms) and used half the memory
(936kB to 446kB) — demonstrating that star schema is more
efficient in multiple dimensions simultaneously.

The pre-aggregated metrics in fact_encounters provide
immediate value beyond raw query speed. Clinical operations
staff can ask "what is the average length of stay for
Cardiology inpatients?" with a single AVG(length_of_stay_days)
query — no date arithmetic, no joins. This democratizes
analytics for non-technical users.

The dim_date dimension with 366 rows for 2024 enables
time intelligence queries that are cumbersome in OLTP —
fiscal year grouping, week-over-week comparisons, weekend
vs weekday analysis — all without a single function call.

### What We Lost

Data redundancy is the most visible cost. Specialty name
and department name are stored in dim_provider (denormalized)
and also in dim_specialty and dim_department. If Cardiology
is renamed to Cardiac Sciences, it must be updated in
multiple places. The ETL process must handle this carefully
to prevent inconsistency.

ETL complexity is significant. We built a pipeline that
generates dim_date automatically, pre-computes age groups,
denormalizes providers, calculates length of stay, detects
readmissions, and loads bridge tables in the correct order.
This pipeline runs daily and must handle late-arriving billing
records, missing dimension keys, and failed loads with
rollback capability. None of this complexity existed when
queries ran directly against OLTP.

Real-time data is sacrificed. The warehouse reflects
yesterday's data at best. A patient admitted at 11pm
will not appear in analytics until the next morning's
ETL load completes. For operational decisions requiring
live data, analysts must still query the OLTP system.

### Was It Worth It?

For analytical workloads at scale — yes, clearly. Our
honest testing showed that even at a modest 10000 rows
two queries improved significantly. The pre-aggregated
metrics and date dimension alone justify the ETL investment
because they benefit every query permanently. As data
volume grows to millions of encounters the advantages
compound while the ETL cost remains roughly constant.

---

## 3. Bridge Tables: Worth It?

The decision to keep diagnoses and procedures in bridge
tables rather than denormalizing them into the fact table
was correct architecturally but revealed a performance
limitation in our testing.

### Why Bridge Tables Are Correct

Denormalizing diagnoses into the fact table would require
either multiple diagnosis columns (primary_diagnosis,
secondary_diagnosis, tertiary_diagnosis) — which breaks
when encounters have more diagnoses than columns — or one
row per diagnosis per encounter, which destroys the grain
and causes revenue double-counting.

Bridge tables preserve the grain (one row per encounter
in fact_encounters) while supporting flexible diagnosis
queries. The query "find all encounters with both
Hypertension and Heart Failure as diagnoses" can only
be answered through bridge tables — it is impossible
with a denormalized design.

### The Performance Finding

Query 2 showed that bridge tables did NOT outperform OLTP
junction tables at 10000 rows. Both produced 40000
intermediate rows and star schema was actually 1.4x slower
due to COUNT(DISTINCT) overhead. This is a genuine
limitation that should be acknowledged, not hidden.

The root cause is that many-to-many row explosion is
inherent to the relationship structure regardless of
schema design. Bridge tables use faster integer surrogate
keys but the explosion still occurs.

### Would I Do It Differently in Production?

In production I would add a materialized view or a separate
pre-aggregated table for the most common diagnosis-procedure
pair queries. This pre-aggregation would run nightly and
store the top N combinations directly — eliminating the
explosion entirely for standard reporting. Bridge tables
would remain for ad-hoc clinical queries that need
full flexibility.

---

## 4. Performance Quantification (Real Measured Data)

### Query 1: Monthly Encounters by Specialty

| Metric          | OLTP        | Star Schema  |
|-----------------|-------------|--------------|
| Execution Time  | 66.451 ms   | 30.117 ms    |
| Planning Time   | 12.960 ms   | 52.378 ms    |
| Hash Join Time  | 45.386 ms   | 4.922 ms     |
| Memory Used     | 931 kB      | 1010 kB      |
| Improvement     | —           | 2.2x faster  |

Main reason: TO_CHAR() eliminated by dim_date pre-computed
columns. Hash Join time dropped 9x — from 45ms to 5ms —
because specialty_key is directly on fact table with no
provider chain traversal needed.

---

### Query 4: Revenue by Specialty & Month

| Metric          | OLTP        | Star Schema  |
|-----------------|-------------|--------------|
| Execution Time  | 28.519 ms   | 10.085 ms    |
| Planning Time   | 59.118 ms   | 26.756 ms    |
| Memory Used     | ~936 kB     | ~446 kB      |
| Tables Joined   | 4           | 3            |
| Improvement     | —           | 2.8x faster  |

Main reason: Billing table join eliminated by pre-aggregating
total_allowed_amount in fact_encounters. Planning time cut
in half because optimizer evaluates fewer join permutations.
Memory usage halved because no billing hash table needed.

---

### Query 3: Scale Projection (Critical Finding)

| Scale       | OLTP (O(n²))    | Star Schema (O(n)) |
|-------------|-----------------|---------------------|
| 10K rows    | 12.432 ms       | 45.875 ms           |
| 100K rows   | ~1,200 ms est.  | ~46 ms est.         |
| 1M rows     | ~120,000 ms est.| ~46 ms est.         |
| Crossover   | —               | ~50,000 rows        |

At 10000 rows OLTP wins. Beyond 50000 rows star schema
wins by an exponentially growing margin. At 1 million
rows the estimated improvement is 40x. This demonstrates
that star schema value is not visible at small scale —
it must be evaluated at production data volumes.

---

## Summary

This lab demonstrated that dimensional modeling is a
tool with specific strengths and limitations not a
universal performance solution. Star schema delivered
real improvements for queries involving pre-aggregated
metrics and date-based grouping (Queries 1 and 4) while
OLTP outperformed on small-scale self-join and many-to-many
queries (Queries 2 and 3).

The most important insight is that star schema value is
primarily realized at production scale. Pre-computed flags
like is_readmission transform O(n²) problems into O(n)
problems a difference that is negligible at 10000 rows
but catastrophic at 1 million. The ETL complexity we
introduced is the investment that makes this possible.

The most valuable lesson from this lab is that performance
optimization in data engineering requires honest measurement,
not assumption. Our testing produced results that contradicted
the expected outcome for two of four queries and those
unexpected results led to deeper understanding of when and
why each schema design excels.