## DE2 Project Report: Aviation Data Pipeline (OpenSky)

---

>**Students:** Maxence DELEHELLE, Amine SAAD-EDDINE   
>**Teacher:** Badr TAJINI     
>**Academic year:** 2025–2026  
>**Program:** Data & Applications - Engineering - (FD)   
>**Course:** Data Engineering II 
---

## 1.  Problem Statement & SLOs 

This project involves building an end-to-end, data-intensive pipeline utilizing ADS-B flight records from the OpenSky Network. The scope includes raw data ingestion, cleaning, enrichment, windowed streaming aggregations, full-text inverted indexing, aircraft behavioral clustering, and the generation of a curated corpus for LLM applications. Performance objectives include a Bronze-to-Gold duration under 10 minutes, a streaming trigger interval under 30 seconds, text query latency below 2,000 ms, a clustering silhouette score of at least 0.25, a storage ratio relative to CSV below 60%, and an LLM quality pass rate of at least 80%.
    
## 2.  Dataset 

The source data consists of OpenSky Network ADS-B bulk exports, specifically flights\_data4.csv, using a 13-column schema including identifiers such as icao24, callsign, and airport codes. The natural key for the dataset is defined as (icao24, firstseen).
    
## 3.  Pipeline

 Layout The output directory structure is organized into layers: bronze for raw immutable landing, silver for cleaned and deduplicated data, gold for analytics tables (routes, daily volumes, aircraft career summaries, and clusters), streaming for windowed aggregations, text for the inverted index, and llm\_ready for the curated corpus.
    
## 4.  ETL Pipeline (Bronze to Gold) 

Raw CSVs are ingested with an all-string permissive schema and saved as Parquet. The Silver layer enforces schema contracts, including non-null ICAO codes, casting of timestamps, and the removal of invalid flight durations. The Gold layer features optimized analytics tables, where AQE is enabled to automatically right-size shuffle stages. The storage footprint for the Parquet files is roughly 47% of the original raw CSV size, satisfying the storage SLO.
    
## 5.  Streaming Pipeline 

The pipeline uses a file source for streaming with a 30-minute watermark on event\_ts and a 10-minute tumbling window grouped by departure airport. Aggregations include record counts, average flight duration, and distinct aircraft counts, with outputs saved in append mode with checkpointing.
    
## 6.  Text Pipeline 

Each document consists of a natural-language sentence derived from flight records. Processing steps include lowercase conversion, regex cleaning, token length filtering, and stop-word removal. An inverted index is built mapping tokens to term frequencies and document IDs, achieving query latencies under 200 ms and storage requirements at approximately 35% of the equivalent CSV.
    
## 7.  Iterative Workload (KMeans Clustering) 

The clustering pipeline uses seven features, including flight duration and distance metrics, scaled via StandardScaler. A parameter sweep was conducted across k values {3, 5, 7, 10, 15} and seeds {42, 123, 456}. An explicit repartition(4) operation before KMeans reduced shuffle exchange, yielding a 1.3 to 1.8x speedup. Cluster assignments are saved to the gold directory, and data health is monitored by comparing centroids between H1 and H2.
    
## 8.  LLM Data Readiness 

The text corpus is formatted as natural language sentences, such as "Flight {callsign} operated aircraft {icao24} departed {dep} bound for {arr}". Quality filters include null removal, character length requirements, ASCII ratio checks, and xxhash64 deduplication, resulting in a pass rate of at least 90%, which meets the SLO.
    
## 9.  Optimizations Summary 

Key optimizations include reducing storage by converting CSVs to Parquet, using AQE for partition sizing, applying partitionBy on dep\_airport for route tables, repartitioning for KMeans shuffle efficiency, and caching the text index for low-latency queries.
    
## 10.  SLO Compliance Summary 

All defined SLOs were met, with actual performance results including a pipeline duration of roughly 2–4 minutes, sub-200ms text query latency, a clustering silhouette score of at least 0.25, and an LLM quality pass rate of 90%.