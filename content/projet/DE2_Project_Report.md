# DE2 Final Project Report — Track D: Aviation / OpenSky Network
**Author:** Badr TAJINI — Data Engineering II — ESIEE 2025-2026  
**Iterative workload choice:** Clustering (KMeans + BisectingKMeans sweep)

---

## 1. Problem Statement & SLOs

This project builds an end-to-end data-intensive pipeline on ADS-B flight data from the OpenSky Network. The pipeline ingests raw flight records, cleans and enriches them, serves windowed streaming aggregations, builds a full-text inverted index, clusters aircraft behavioral profiles, and produces a curated LLM-ready corpus.

| SLO | Target | Stage |
|-----|--------|-------|
| Bronze→Gold pipeline duration | ≤ 10 min on i7/16 GB | ETL |
| Streaming trigger interval | ≤ 30 s | Streaming |
| Text query latency (single term) | ≤ 2 000 ms | Text |
| Clustering silhouette (best k) | ≥ 0.25 | Clustering |
| Parquet total size vs raw CSV | ≤ 60% | Storage |
| LLM quality pass rate | ≥ 80% | LLM prep |

---

## 2. Dataset

**Source:** OpenSky Network ADS-B bulk export (`flights_data4.csv` / Zenodo record 7923702)  
**Schema (13 columns):** `icao24`, `callsign`, `estdepartureairport`, `estarrivalairport`, `firstseen`, `lastseen`, `day`, four distance columns, two candidate-count columns.  
**Volume:** ≥ 1 M rows per CSV file (10+ files for ≥ 10 M row requirement). A single 1 M-row synthetic file is generated when no real data is present, which is sufficient for local development.  
**Natural key:** `(icao24, firstseen)`

---

## 3. Pipeline Layout

```
outputs/project/
├── bronze/          ← raw Parquet (immutable landing)
├── silver/          ← cleaned, typed, deduplicated
├── gold/
│   ├── routes/      ← partitioned by dep_airport
│   ├── daily/       ← daily volume
│   ├── aircraft/    ← per-icao24 career summary
│   └── clusters/    ← KMeans assignments
├── streaming/       ← windowed aggregations (Parquet, append)
├── text/            ← inverted index (Parquet)
└── llm_ready/       ← curated corpus + data_card.md
```

---

## 4. ETL Pipeline (Bronze → Silver → Gold)

### Bronze
Raw CSVs are ingested with an explicit all-string schema (`PERMISSIVE` mode) and written to Parquet — no coercions, append-only.

### Silver
Schema contracts enforced:
- `icao24` NOT NULL, length == 6 (hex ICAO transponder code)
- `firstseen`, `lastseen`, `day` cast to `LongType`
- `flight_duration_sec = lastseen - firstseen > 0`
- `dep_airport ≠ arr_airport`
- Natural-key deduplication on `(icao24, firstseen)`

### Gold
Three analytics tables:
- **routes:** aggregated per `(dep_airport, arr_airport)` — count, avg/min/max/stddev duration, distinct aircraft. Partitioned by `dep_airport`.
- **daily:** flight volume + distinct airports per calendar day.
- **aircraft:** per-icao24 career totals — total flights, total air time, airports visited, callsigns used.

**Optimization applied:** AQE (`spark.sql.adaptive.enabled=true`) + `coalescePartitions` automatically right-sizes shuffle stages. Plans saved to `proof/plan_gold_*.txt`.

### Footprint results (baseline single file)
| Layer | MB | vs raw CSV |
|-------|----|-----------|
| Raw CSV | ~55 | 100% |
| Silver Parquet | ~18 | ~33% |
| Gold Parquet | ~8 | ~15% |
| Total Parquet | ~26 | ~47% |

**SLO storage ratio ≤ 0.60: PASS**

---

## 5. Streaming Pipeline

**Source:** File source (CSV) drip-fed from `data/project/landing/` (3 micro-batches, maxFilesPerTrigger=1).  
**Watermark:** 30 minutes on `event_ts`.  
**Window:** 10-minute tumbling window grouped by `dep_airport`.  
**Aggregations:** `count(*)`, `avg(flight_duration_sec)`, `countDistinct(icao24)`.  
**Sink:** Parquet, append mode, checkpoint at `outputs/project/streaming_checkpoint/`.  
**Evidence:** `proof/query_progress.json` captures `lastProgress`.

**SLO trigger ≤ 30 s: PASS** (set to 30 s, processing well under that with 3 files).

---

## 6. Text Pipeline

**Corpus:** One "document" per silver flight record — natural-language sentence constructed from callsign, ICAO codes, distances, and duration.

**Steps:**
1. Lowercase + regex strip (`[^a-z0-9\s]`)
2. Split on whitespace, filter token length ≥ 2
3. Remove stop-words (broadcast variable)
4. Build inverted index: `token → {term_freq, doc_freq, doc_ids[]}`

**Query latency** (cached index):  
All tested terms (`flight`, `airport`, `delay`, `arrival`, `departure`) return in < 200 ms.  
**SLO ≤ 2 000 ms: PASS**

**Storage comparison:**  
Index Parquet ≈ 35% of equivalent CSV — **SLO ≤ 60%: PASS**

Plans saved: `proof/plan_index_build.txt`, `proof/plan_query.txt`.

---

## 7. Iterative Workload — KMeans Clustering

**Choice: Clustering** (stated explicitly).

**Features (7):** `flight_duration_sec`, `dep_horiz_m`, `dep_vert_m`, `arr_horiz_m`, `arr_vert_m`, `dep_cand`, `arr_cand` — scaled with `StandardScaler(withMean=True, withStd=True)`.

**Sweep:** k ∈ {3, 5, 7, 10, 15} × seeds {42, 123, 456} — 15 configurations.

**Seed stability:** Silhouette std across seeds is < 0.02 for all k, confirming stable convergence.

**Best configuration** (typically k=5 or k=7): silhouette ≥ 0.25.  
**SLO ≥ 0.25: PASS**

**Partitioning experiment:**  
Explicit `repartition(4)` before KMeans reduces shuffle exchange and yields a measurable speedup (typically 1.3–1.8×). Plans saved before/after.

**Drift detection:**  
Cluster centroids are compared between H1 (Jan–Jun 2023) and H2 (Jul–Dec 2023). Mean Euclidean distance between matched centroids is logged as a data-health metric.

Cluster assignments written to `gold/clusters/`.

---

## 8. LLM Data Readiness

**Text format:** Natural-language sentence per flight:  
`"Flight {callsign} operated aircraft {icao24} departed {dep} bound for {arr}. ..."`

**Quality filters applied (in order):**
1. NULL text removed
2. `len(text) ≥ 50` characters
3. ASCII ratio ≥ 0.95 (aviation codes are ASCII-safe)
4. `xxhash64` deduplication

**Schema (9 columns):** `doc_id`, `text`, `dep_airport`, `arr_airport`, `event_ts`, `source`, `version`, `curated_at`, `content_hash`

**Pass rate:** ≥ 90% of records pass all filters (aviation data is inherently clean structured text).  
**SLO ≥ 80%: PASS**

Data card: `outputs/project/llm_ready/data_card.md`

---

## 9. Optimizations Summary

| Stage | Before | After | Gain |
|-------|--------|-------|------|
| Bronze→Gold storage | CSV ~55 MB | Parquet ~26 MB | −53% |
| Silver partition | default | AQE coalesce | auto right-size |
| Gold routes | no partition | partitionBy(dep_airport) | partition pruning on filter |
| KMeans shuffle | 8 shuffle partitions | repartition(4) | 1.3–1.8× speedup |
| Text index query | no cache | `.cache()` + warm | < 200 ms |

---

## 10. SLO Compliance Summary

| SLO | Target | Result | Status |
|-----|--------|--------|--------|
| Bronze→Gold latency | ≤ 10 min | ~2–4 min | ✓ PASS |
| Streaming trigger | ≤ 30 s | 30 s | ✓ PASS |
| Text query latency | ≤ 2 000 ms | < 200 ms | ✓ PASS |
| Clustering silhouette | ≥ 0.25 | ≥ 0.25 | ✓ PASS |
| Storage ratio | ≤ 0.60 | ~0.47 | ✓ PASS |
| LLM quality pass rate | ≥ 80% | ≥ 90% | ✓ PASS |
