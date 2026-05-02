# WA Equity Trading (WAET) — Project Architecture

> **Project:** WA Equity Trading
> **GCP Project ID:** `wa-equity-trading`
> **Primary Region:** `us-central1`
> **Environment:** `prd` (production)
> **Last Updated:** 2026-03-15

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Full Architecture Diagram](#2-full-architecture-diagram)
3. [Repository Map](#3-repository-map)
4. [Infrastructure Layer (Terraform)](#4-infrastructure-layer-terraform)
5. [Data Ingestion Layer (IQFeed → GCS)](#5-data-ingestion-layer-iqfeed--gcs)
6. [Processing Layer (GCS → BigQuery)](#6-processing-layer-gcs--bigquery)
7. [Cloud Workflows Pipeline](#7-cloud-workflows-pipeline)
8. [Backfill Organizer (Google Sheets)](#8-backfill-organizer-google-sheets)
9. [IQFeed Docker Container](#9-iqfeed-docker-container)
10. [Dataform & ML Subsets](#10-dataform--ml-subsets)
11. [GCP Resource Inventory](#11-gcp-resource-inventory)
12. [IAM & Security](#12-iam--security)
13. [Cost Model](#13-cost-model)
14. [Monitoring & Alerting](#14-monitoring--alerting)
15. [Backfill Status](#15-backfill-status)
16. [Operational Runbook](#16-operational-runbook)
17. [Key Design Decisions](#17-key-design-decisions)

---

## 1. System Overview

WAET is a **quantitative equity trading data platform** built entirely on GCP. Its core purpose is to collect, store, and analyse historical tick-level market data sourced from **IQFeed** (DTN's real-time/historical market data feed).

The platform is composed of three tightly coupled repositories:

| Repository | Role |
|---|---|
| `infrastructure-setup` | Terraform IaC — provisions every GCP resource |
| `iqfeed-docker` | Dockerised IQFeed client + `vm_batch_ingest.sh` download orchestrator |
| `waet-data-layer` | Cloud Workflows, Dataform, BigQuery pipelines, Go connectors |

**Data journey in one sentence:**
A Google Sheets row defines a batch → `vm_batch_ingest.sh` runs on a GCE VM → `qdownload` streams ticks from IQFeed directly into GCS via gcsfuse → `_SUCCESS` fires Eventarc → Cloud Workflow transforms raw CSVs into 1-second OHLCV bars in BigQuery → batch is archived.

---

## 2. Full Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│  PLANNING LAYER                                                                  │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐                │
│  │  Backfill Organizer (Google Sheets)                         │                │
│  │  Each row = 1 batch                                         │                │
│  │  Col E: status_code (0 = ready)                             │                │
│  │  Col I: pre-generated qdownload command                     │                │
│  │  Sheets Reference ID → spine of the whole system            │                │
│  └─────────────────────────────────────────────────────────────┘                │
└──────────────────────────────────────┬───────────────────────────────────────────┘
                                       │  operator reads batch command
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  INGESTION LAYER (GCE VM: vm-prd-iqfeed-docker, e2-standard-2, us-central1-a)   │
│                                                                                  │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │  vm_batch_ingest.sh                                                       │  │
│  │  bash ~/vm_batch_ingest.sh <start_date> <end_date> <gcs_output_path>     │  │
│  │                                                                           │  │
│  │  1. Reads IQFeed credentials from GCE instance metadata                  │  │
│  │  2. docker run  iqfeed-client:latest  (with SYS_ADMIN + /dev/fuse)       │  │
│  │  3. Waits for IQFeed "ping OK" in supervisor logs (up to 120s)           │  │
│  │  4. Inside container: gcsfuse mounts GCS bucket at /mnt/gcs              │  │
│  │  5. qdownload -p 32  writes CSVs directly to /mnt/gcs                   │  │
│  │  6. Health loop: polls keepalive log every 10s                           │  │
│  │     → 3× "timed out"  ⟹  kill qdownload, restart container, retry       │  │
│  │  7. On success: parse log → _FAILED.csv + _SUCCESS written to GCS        │  │
│  └───────────────────────────────────────────────────────────────────────────┘  │
│                                                                                  │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │  IQFeed Docker Container  (linux/amd64, Wine64, Supervisor)               │  │
│  │                                                                           │  │
│  │  ┌────────────┐  ┌──────────┐  ┌────────────────────┐  ┌─────────────┐  │  │
│  │  │   Xvfb     │  │ x11vnc   │  │  iqfeed-startup     │  │  keepalive  │  │  │
│  │  │ (display)  │  │ :5900    │  │  Wine64 loop        │  │  ping /15s  │  │  │
│  │  └────────────┘  └──────────┘  │  iqconnect.exe      │  └─────────────┘  │  │
│  │                                └────────────────────┘                    │  │
│  │  ┌───────────────────────────────────────────────────┐                   │  │
│  │  │  Node.js Proxy  (app/proxy.js)                    │                   │  │
│  │  │  9100 → 9101 (Lookup)   9300 → 9301 (Admin)       │                   │  │
│  │  │  Auto-authenticates: REGISTER + SET LOGINID + ...  │                   │  │
│  │  └───────────────────────────────────────────────────┘                   │  │
│  │                                                                           │  │
│  │  ┌───────────────────────────────────────────────────┐                   │  │
│  │  │  qdownload (Go binary)                            │                   │  │
│  │  │  -p 32  tick  symbols.txt (1,040 symbols)         │                   │  │
│  │  │  Output: /mnt/gcs/{output_path}/{date}/{SYM}.csv  │                   │  │
│  │  └───────────────────────────────────────────────────┘                   │  │
│  └───────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────┬───────────────────────────────────────────┘
                                       │  gcsfuse writes directly
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  STORAGE LAYER                                                                   │
│                                                                                  │
│  gs://bkt-prd-iqfeed-raw-files-001/                                              │
│  └── raw/market-data/                                                            │
│       └── {SHEETS_ID}/                ← Sheets Reference ID ties everything     │
│            └── {INGEST_DATE}/                                                    │
│                 ├── AAPL.csv          ← tick CSV per symbol                      │
│                 ├── TSLA.csv             datetime,last,lastsize,totalsize,        │
│                 ├── ...  (1,040 files)   bid,ask,tickid,basis,market,cond        │
│                 ├── _FAILED.csv       ← symbols that errored (symbol,reason,date)│
│                 └── _SUCCESS          ← TRIGGERS PIPELINE ──────────────────────┤
│                                                                                  │
│  gs://bkt-prd-iqfeed-raw-archive-001/  (Autoclass, terminal=ARCHIVE, 365d TTL)  │
│  └── raw/market-data/{SHEETS_ID}/{INGEST_DATE}/ ← archived after ingest         │
└──────────────────────────────────────┬───────────────────────────────────────────┘
                                       │  _SUCCESS finalised → Eventarc
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  ORCHESTRATION LAYER (Cloud Workflows + Eventarc)                                │
│                                                                                  │
│  Eventarc Standard                                                               │
│  Filter: type == "google.cloud.storage.object.v1.finalized"                      │
│           && subject.endsWith("/_SUCCESS")                                       │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │  s1-ingest-silver                                                        │   │
│  │  1. CREATE OR REPLACE EXTERNAL TABLE tick_raw_external                   │   │
│  │     → gs://.../{SHEETS_ID}/{UPLOAD_DATE}/*.csv  (single wildcard)        │   │
│  │  2. DELETE existing rows for this batch (idempotency)                    │   │
│  │  3. INSERT INTO ds_prd_silver.tick_1sec_001                              │   │
│  │     GROUP BY symbol + TIMESTAMP_TRUNC(ts, SECOND)                       │   │
│  │     → ask/bid/last OHLC, volume SUM, tick_count                         │   │
│  │  4. Write _SILVER_READY to markers bucket, delete _SUCCESS from raw      │   │
│  └──────────────────────────────────┬───────────────────────────────────────┘   │
│                                     │ _SILVER_READY                             │
│  ┌──────────────────────────────────▼───────────────────────────────────────┐   │
│  │  s2-ingest-failed                                                        │   │
│  │  1. Read _FAILED.csv → external table                                    │   │
│  │  2. MERGE → ds_prd_silver.failed_symbols                                 │   │
│  │  3. Invoke s3, delete _SILVER_READY                                      │   │
│  └──────────────────────────────────┬───────────────────────────────────────┘   │
│                                     │ _READY_TO_ARCHIVE                         │
│  ┌──────────────────────────────────▼───────────────────────────────────────┐   │
│  │  s3-ingest-metadata                                                      │   │
│  │  1. Capture batch metrics (raw tick count, silver row count, ratio)      │   │
│  │  2. INSERT INTO ds_prd_silver.batch_ingest_log                           │   │
│  │  3. Write _READY_TO_ARCHIVE                                             │   │
│  └──────────────────────────────────┬───────────────────────────────────────┘   │
│                                     │ _READY_TO_ARCHIVE                         │
│  ┌──────────────────────────────────▼───────────────────────────────────────┐   │
│  │  s4-archive-batch                                                        │   │
│  │  1. List all objects (paginated, 50/page)                                │   │
│  │  2. Copy each → bkt-prd-iqfeed-raw-archive-001 (same path)              │   │
│  │  3. Delete originals from raw bucket                                     │   │
│  │  4. Write _ARCHIVED, delete _READY_TO_ARCHIVE                            │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────┬───────────────────────────────────────────┘
                                       │
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  BIGQUERY LAYER                                                                  │
│                                                                                  │
│  ds_prd_silver                                                                   │
│  ├── tick_1sec_001           ← 1-second OHLCV bars (1.74B+ rows)                │
│  │   Partitioned: DATE(ts_1sec)   Clustered: symbol                             │
│  │   Columns: symbol, trade_date, batch_id, ts_1sec,                            │
│  │            ask/bid/last OHLC (×4 each), volume, tick_count                   │
│  │                                                                               │
│  ├── failed_symbols          ← symbols that errored per batch                   │
│  │   Partitioned: batch_date   Columns: batch_id, symbol, reason, date          │
│  │                                                                               │
│  └── batch_ingest_log        ← per-batch ingest metrics                         │
│      Partitioned: batch_date   Clustered: batch_id, symbol                      │
│      Columns: batch_id, raw_tick_count, silver_tick_count,                       │
│               raw_to_silver_ratio, ingested_at                                   │
│                                                                                  │
│  ds_prd_iqfeed_raw_external                                                      │
│  ├── tick_raw_external       ← ephemeral per-batch external table (auto-refresh) │
│  └── raw_batch_markers_external_001  ← marker enumeration for ops               │
│                                                                                  │
│  ds_prd_diagnostics                                                              │
│  └── Pipeline health metrics                                                     │
└──────────────────────────────────────┬───────────────────────────────────────────┘
                                       │
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  ANALYSIS LAYER                                                                  │
│                                                                                  │
│  Dataform (waet-data-transformation-layer, GitHub)                               │
│  ├── definitions/silver/tick_1sec.sqlx    ← schema reference (not live ingest)  │
│  ├── definitions/make_dataset.js          ← dynamic ML subset generation        │
│  └── includes/constants.js               ← parameter definitions                │
│                                                                                  │
│  ML Subsets (ds_prd_ml_subsets)                                                  │
│  Segmented by: market_cap, earnings_day, time_of_day,                            │
│                rsi_1h, adx_1h, atr_1h, rvol_1h, market_rsi_1h, market_adx_1h   │
│                                                                                  │
│  adhoc-processing (Python / uv)                                                  │
│  ├── Aggregates tick CSVs → 1-second CSVs locally                                │
│  ├── Computes: peak_disagreement, fragility_proxy, quote_move_no_last_pct       │
│  └── Writes results back to Google Sheets (trade analysis workbooks)             │
│                                                                                  │
│  Vertex AI Workbench (wb-prd-ml-training)                                        │
│  └── n1-standard-4, 150 GB boot SSD, 100 GB data SSD                            │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Repository Map

```
Desktop/
├── infrastructure-setup/          Terraform IaC for all GCP resources
│   ├── init/                      Bootstrap: API enablement, Workload Identity, GitHub Actions SA
│   ├── iac/                       Main infrastructure
│   │   ├── main.tf                Orchestrates all modules via YAML resource configs
│   │   ├── resources/             YAML-driven resource definitions
│   │   │   ├── buckets/           GCS bucket configs
│   │   │   ├── compute/           GCE VM configs
│   │   │   ├── datasets/          BigQuery dataset configs
│   │   │   ├── eventarc/          Eventarc trigger configs
│   │   │   ├── external_tables/   BigQuery external table configs
│   │   │   ├── dataform/          Dataform repo config
│   │   │   ├── vertex_ai/         Workbench config
│   │   │   └── iam/               Developer IAM grants
│   │   └── workflows/             Cloud Workflow YAML definitions (s1–s4)
│   └── modules/                   Reusable Terraform modules
│       ├── buckets/
│       ├── compute/
│       ├── datasets/
│       ├── workflows/
│       ├── dataform/
│       ├── external_tables/
│       ├── vertex_ai/
│       └── agent_policy/
│
├── iqfeed-docker/                 IQFeed Docker image + VM batch script
│   ├── Dockerfile                 linux/amd64, Wine64, Supervisor, gcsfuse, qdownload
│   ├── supervisord.conf           6 managed services (Xvfb, VNC, fluxbox, IQFeed, proxy, keepalive)
│   ├── vm_batch_ingest.sh         GCE VM orchestrator — main entrypoint for batch downloads
│   ├── ingest.sh                  Simple EOD daily ingestion script
│   ├── iqfeed_startup.sh          Wine64 auto-restart loop for iqconnect.exe
│   ├── iqfeed_keepalive.sh        Ping daemon (every 15s) to prevent idle disconnect
│   ├── start_and_download.sh      Local development helper
│   ├── app/proxy.js               Node.js TCP proxy with auto-auth
│   └── symbols.txt                1,040 ticker symbols
│
└── waet-data-layer/               Data pipeline: Go connectors, Cloud Workflows, Dataform
    ├── connectors/
    │   ├── qdownload/             Go: IQFeed TCP → CSV (parallelism: 8 default, 32 on VM)
    │   └── qupload/               Go: local CSV → GCS with resume support
    ├── workflows/ingest.yaml      Cloud Workflow source (canonical copy)
    ├── definitions/               Dataform SQLX (bronze retired, silver active as schema ref)
    ├── adhoc-processing/          Python: tick → 1-sec stats → Google Sheets
    ├── scripts/
    │   ├── bulk_ingest.sh         Sequential trigger for backfill batches
    │   └── bulk_archive.sh        Parallel trigger (N=10 groups) for archival
    └── docs/                      Architecture, pipeline, Eventarc, local setup guides
```

---

## 4. Infrastructure Layer (Terraform)

### Deployment Pattern

```bash
# Phase 1 — Run once per project
cd infrastructure-setup/init/
terraform init && terraform apply

# Phase 2 — Main resources
cd infrastructure-setup/iac/
terraform init && terraform apply
```

### Adding / Removing Resources

Resources are defined as **YAML files** under `iac/resources/`. No HCL changes needed:
- Add YAML → `terraform apply` creates resource
- Rename to `.archive` → `terraform apply` destroys resource

### Naming Conventions

| Type | Pattern | Example |
|---|---|---|
| BigQuery dataset | `ds_{env}_{name}` | `ds_prd_silver` |
| GCS bucket | `bkt-{env}-{name}-{version:03d}` | `bkt-prd-iqfeed-raw-files-001` |
| GCE instance | `vm-{env}-{name}` | `vm-prd-iqfeed-docker` |
| Workbench | `wb-{env}-{name}` | `wb-prd-ml-training` |
| Workflow SA | `sa-wf-{name}` | `sa-wf-ingest-tick-silver` |
| Eventarc trigger | `trg-gcs-{name}` | `trg-gcs-ingest-tick-silver` |

---

## 5. Data Ingestion Layer (IQFeed → GCS)

### The Sheets Reference ID — System Spine

Every batch is anchored to a **Sheets Reference ID** — a UUID-like string auto-generated by the Backfill Organizer Google Sheet. It appears in every layer:

```
Local:     data/tick/<SHEETS_ID>/AAPL.csv
GCS raw:   gs://bkt-prd-iqfeed-raw-files-001/raw/market-data/<SHEETS_ID>/<DATE>/
BigQuery:  ds_prd_silver.tick_1sec_001.batch_id = '<SHEETS_ID>'
adhoc:     uv run python main.py --file-id <SHEETS_ID>
```

### vm_batch_ingest.sh Flow

```
invoke: bash ~/vm_batch_ingest.sh 20260223 20260224 raw/market-data/87-1Lka...
   │
   ├── start_container()
   │     docker stop/rm iqfeed (cleanup)
   │     docker run -d --restart=always
   │       --cap-add SYS_ADMIN --device /dev/fuse (for gcsfuse)
   │       -e LOGIN/PASSWORD/PRODUCT_ID (from GCE metadata)
   │
   ├── wait_for_iqfeed()
   │     poll supervisor keepalive log every 5s, up to 120s
   │     look for "ping OK" → proceed
   │     timeout → restart container
   │
   ├── run_download()
   │     docker cp ~/symbols.txt iqfeed:/root/symbols.txt
   │     docker exec: gcsfuse mount → qdownload -p 32 → fusermount -u
   │     background monitor: poll keepalive every 10s
   │       3× "timed out" → kill qdownload → return 1 (triggers retry)
   │
   ├── on qdownload success:
   │     parse /tmp/qdownload.log → _FAILED.csv
   │     touch _SUCCESS
   │     fusermount -u
   │     break loop
   │
   └── on failure:
         ATTEMPT++ → back to start_container()
```

### IQFeed Connection Architecture

```
IQFeed Cloud Servers (DTN)
        ↕  (internet)
iqconnect.exe (Wine64, inside container)
        ↕  (localhost TCP)
Node.js proxy  (app/proxy.js)
  Port 9100 → 9101  (Lookup / historical data)
  Port 9300 → 9301  (Admin)
  Port 5010         (Level 1 real-time)
        ↕
qdownload  (Go binary, 32 parallel goroutines)
        ↕  (writes via gcsfuse)
gs://bkt-prd-iqfeed-raw-files-001/
```

### CSV Format

```csv
datetime,last,lastsize,totalsize,bid,ask,tickid,basis,market,cond
2026-02-23 09:30:00.123,152.34,100,100,152.33,152.35,8834729,C,Q,
```

---

## 6. Processing Layer (GCS → BigQuery)

### External Table Strategy

Each batch triggers creation of a **per-batch external table** pointing to exactly that batch's CSVs:

```sql
CREATE OR REPLACE EXTERNAL TABLE `ds_prd_iqfeed_raw_external.tick_raw_external`
OPTIONS (
  format = 'CSV',
  uris = ['gs://bkt-prd-iqfeed-raw-files-001/raw/market-data/{SHEETS_ID}/{DATE}/*.csv'],
  skip_leading_rows = 1
)
```

Single wildcard — always supported, no path enumeration needed.

### Silver Aggregation (1-second OHLCV)

```sql
INSERT INTO `ds_prd_silver.tick_1sec_001`
SELECT
  REGEXP_EXTRACT(_FILE_NAME, r'/([^/]+)\.csv$')         AS symbol,
  TIMESTAMP_TRUNC(PARSE_TIMESTAMP(..., datetime), SECOND) AS ts_1sec,
  -- OHLC via ARRAY_AGG ordered by timestamp
  ask_arr[OFFSET(0)]  AS ask_open,
  ask_arr[ORDINAL(ARRAY_LENGTH(ask_arr))] AS ask_close,
  MAX(ask) AS ask_high, MIN(ask) AS ask_low,
  -- same for bid and last ...
  SUM(SAFE_CAST(lastsize AS INT64)) AS volume,
  COUNT(*)                          AS tick_count
FROM `tick_raw_external`
GROUP BY symbol, ts_1sec
```

### Marker File State Machine

```
_SUCCESS
  → s1 processes → _SILVER_READY   (s1 deletes _SUCCESS)
      → s2 processes and invokes s3   (s2 deletes _SILVER_READY)
          → s3 writes _READY_TO_ARCHIVE
              → s4 processes → _ARCHIVED    (s4 deletes _READY_TO_ARCHIVE)
```

`_SUCCESS` lives in the raw bucket. `_SILVER_READY` and `_READY_TO_ARCHIVE` live in the markers bucket.

---

## 7. Cloud Workflows Pipeline

| Workflow | Trigger | Input | Output Table | Marker In | Marker Out |
|---|---|---|---|---|---|
| `s1-ingest-silver` | Eventarc raw `_SUCCESS` | Batch CSVs | `tick_1sec_001` | raw `_SUCCESS` | markers `_SILVER_READY` |
| `s2-ingest-failed` | Eventarc markers `_SILVER_READY` | `_FAILED.csv` | `failed_symbols` | markers `_SILVER_READY` | synchronous `s3` invocation |
| `s3-ingest-metadata` | invoked by `s2` | BQ queries | `batch_ingest_log` | synthetic `_SILVER_READY` payload | markers `_READY_TO_ARCHIVE` |
| `s4-archive-batch` | Eventarc markers `_READY_TO_ARCHIVE` | GCS object list | Archive bucket | markers `_READY_TO_ARCHIVE` | `_ARCHIVED` |

Each workflow has a **dedicated service account** (`sa-wf-*`) with least-privilege IAM roles. Input validation (regex on `sheets_id` and `upload_date`) guards against injection before any SQL is constructed.

---

## 8. Backfill Organizer (Google Sheets)

**Sheet URL:** `https://docs.google.com/spreadsheets/d/1Do9upOObzy9TN_MtgIa9u6aVXFbVPFYYi6eeBnM0ktI/`

### Key Columns

| Col | Field | Description |
|---|---|---|
| E | `status_code` | `0` = ready to download |
| I | `qdownload_cmd` | Pre-generated full command with start/end date and output path |

### Example Row

```
status_code: 0
qdownload_cmd: qdownload -o ../../data/tick/87-1LkaUcESGQR9sw2_OCiTTA0fMXRd2Nc4KpM1mTj0R4no -s 20260223 -e 20260224 tick symbols.txt
```

### How a Batch Is Processed

```
1. Open sheet → find row where Col E = 0
2. Copy command from Col I
3. Run on machine with IQFeed running (GCE VM or local)
4. After qdownload completes → run qupload <SHEETS_ID>
5. qupload writes _SUCCESS → pipeline auto-triggers
6. Update Col E = 1 (done) in sheet
```

---

## 9. IQFeed Docker Container

**Image:** `us-central1-docker.pkg.dev/wa-equity-trading/iqfeed/iqfeed-client:latest`
**Platform:** `linux/amd64` (forced — Wine64 requires x86-64)
**Base:** `ubuntu:22.04`

### Supervisor-Managed Services

| Service | Role | Key Detail |
|---|---|---|
| `xvfb` | Virtual display `:0` | Required for Wine/Windows GUI |
| `x11vnc` | VNC server port 5900 | Remote IQFeed UI access |
| `fluxbox` | Window manager | Lightweight, runs in Xvfb |
| `iqfeed-startup` | `iqconnect.exe` via Wine64 | Infinite restart loop (3s delay) |
| `iqfeed-proxy` | Node.js TCP proxy | Auth injection, reconnect logic |
| `iqfeed-keepalive` | Ping daemon | 15s pings to ports 9300 + 9100, prevents 2-min idle disconnect |

### Wine64 Configuration

```
WINEARCH=win64
WINEPREFIX=/root/.wine64
Drive C: → standard Windows C:
Drive Z: → /  (full Linux filesystem)
```

### Docker Run Flags Required

```bash
--cap-add SYS_ADMIN       # gcsfuse requires CAP_SYS_ADMIN
--device /dev/fuse         # FUSE device for gcsfuse
--security-opt apparmor=unconfined  # AppArmor would block FUSE
```

### Credentials

Credentials are **never baked into the image**. They are fetched at runtime from GCE instance metadata:

```bash
curl -sf 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/iqfeed-login' \
     -H 'Metadata-Flavor: Google'
```

---

## 10. Dataform & ML Subsets

Dataform is linked to the private GitHub repo `waet-data-transformation-layer` via a PAT stored in Secret Manager.

### Current Status

| Layer | Table | Status | Notes |
|---|---|---|---|
| Bronze | `ds_prd_iqfeed_raw.tick_raw` | ⚠️ Retired | Schema reference only — external table is sufficient |
| Silver | `ds_prd_silver.tick_1sec_001` | ✅ Active | Written by Cloud Workflow (not Dataform) |

### ML Subset Generation (`make_dataset.js`)

Dataform dynamically generates segmentation tables from `includes/constants.js`:

**Categorical parameters:** `market_cap`, `earnings_day`, `time_of_day`
**Numerical bins:** `rsi_1h`, `adx_1h`, `atr_1h_1d`, `rvol_1h`, `market_rsi_1h`, `market_adx_1h`

### adhoc-processing Pipeline

```bash
# Aggregate ticks to 1-second intervals + compute statistics
uv run python main.py \
  --file-id <SHEETS_ID> \
  --workbook-name "My Workbook" \
  --step convert          # or: peak_disagreement, fragility_proxy, quote_move_no_last_pct
```

Results written back to Google Sheets via `gspread`.

---

## 11. GCP Resource Inventory

| Resource | Type | Details |
|---|---|---|
| `wa-equity-trading` | GCP Project | Project number: 640425269363 |
| `vm-prd-iqfeed-docker` | GCE VM | e2-standard-2, 30 GB, us-central1-a, Container-Optimized OS |
| `wb-prd-ml-training` | Vertex AI Workbench | n1-standard-4, 150 GB boot SSD + 100 GB data SSD |
| `bkt-prd-iqfeed-raw-files-001` | GCS | STANDARD — landing zone for raw CSVs |
| `bkt-prd-iqfeed-raw-archive-001` | GCS | Autoclass, terminal=ARCHIVE, 365-day delete |
| `ds_prd_iqfeed_raw_external` | BigQuery Dataset | US multi-region — external tables over GCS |
| `ds_prd_silver` | BigQuery Dataset | US multi-region — `tick_1sec_001`, `failed_symbols`, `batch_ingest_log` |
| `ds_prd_diagnostics` | BigQuery Dataset | Pipeline health monitoring |
| `s1-ingest-silver` | Cloud Workflow | Silver ingestion |
| `s2-ingest-failed` | Cloud Workflow | Failed symbols tracking |
| `s3-ingest-metadata` | Cloud Workflow | Batch metrics recording |
| `s4-archive-batch` | Cloud Workflow | Raw → archive migration |
| `trg-gcs-ingest-tick-silver` | Eventarc Trigger | Fires on raw-bucket `_SUCCESS` |
| `trg-gcs-ingest-failed-symbols` | Eventarc Trigger | Fires on markers-bucket `_SILVER_READY` |
| `trg-gcs-archive-batch` | Eventarc Trigger | Fires on markers-bucket `_READY_TO_ARCHIVE` |
| `iqfeed` (Artifact Registry) | Docker Registry | `us-central1-docker.pkg.dev/wa-equity-trading/iqfeed/` |
| `data_transformation_layer` | Dataform Repo | Git: `waet-data-transformation-layer`, branch: `main` |
| `wa-equity-trading-tf-state` | GCS | Terraform remote state |

---

## 12. IAM & Security

### Service Account Isolation

Each Cloud Workflow has its own dedicated service account with **only the roles it needs**:

| SA | Roles |
|---|---|
| `sa-wf-ingest-tick-silver` | BQ jobUser, BQ dataEditor, GCS objectAdmin, logging.logWriter, eventarc.eventReceiver |
| `sa-wf-ingest-failed` | Same |
| `sa-wf-ingest-metadata` | Same |
| `sa-wf-archive-batch` | Same + storage.legacyBucketReader on archive bucket |

### Developer Access (hamzabouazza141@gmail.com)

- `storage.objectAdmin` on raw bucket
- `bigquery.user` + `bigquery.dataViewer` + `bigquery.dataEditor` + `bigquery.dataOwner`

### CI/CD — No Service Account Keys

GitHub Actions authenticates via **Workload Identity Federation (OIDC)** — no long-lived keys in the repo.

### Data Protection

- Buckets: `force_destroy = false`
- Datasets: `delete_contents_on_destroy = false`
- IQFeed credentials: GCE instance metadata (never in Docker image)
- GitHub PAT: Secret Manager (`dataform-git-token`)

### SQL Injection Guard

All Cloud Workflows validate `sheets_id` and `upload_date` with regex before constructing any BigQuery SQL.

---

## 13. Cost Model

### Per-Batch Costs

| Operation | Cost | Notes |
|---|---|---|
| External table DDL | $0.00 | Metadata only |
| Silver INSERT | ~$0.01 | Scans ~2 GB batch CSVs only |
| GCS copy to archive | ~$0.01 | ~1,040 copy operations |
| GCS STANDARD storage | ~$0.02/GB/month | Transient — archived quickly |
| GCS ARCHIVE storage | ~$0.001/GB/month | 365-day TTL |
| **Total per batch** | **~$0.02** | |

### Old vs New Approach

| Approach | Cost/batch | Annual (66 batches) |
|---|---|---|
| Dataform incremental | ~$12.00 | ~$792 |
| Direct Cloud Workflow INSERT | ~$0.01 | ~$0.66 |
| **Savings** | **$11.99** | **~$791/year** |

### Budget Controls

- **Monthly budget:** $2,000 (alerts at 25%, 50%, 75%, 100%)
- **BigQuery daily cap:** 20 TB scanned/day (~$100 at $5/TB)

---

## 14. Monitoring & Alerting

### Workflow Failure Alerts

Email alert fires when any ingest workflow records ≥1 failed execution in a 5-minute window.

Monitored workflows: `s1-ingest-silver`, `s2-ingest-failed`, `s4-archive-batch`

Alert auto-closes 30 minutes after condition clears.

### Ops Agent

Google Cloud Ops Agent deployed on all Compute Engine instances via OS Config policy — provides infrastructure metrics and log ingestion to Cloud Monitoring.

### Batch Health Checks

After each batch, `batch_ingest_log` records:
- `raw_tick_count` vs `silver_tick_count` — compression ratio sanity check
- `raw_to_silver_ratio` — spike detection
- `ingested_at` — latency tracking

---

## 15. Backfill Status

**As of 2026-03-12:**

| Batch Range | Count | Status | Notes |
|---|---|---|---|
| 15–78 (excl. 79, 80, 86) | 66 | ✅ Downloaded, uploaded, ingested, archived | 1.74B silver rows |
| 79, 81–85, 87–93 | ~14 | ⏸ Downloaded locally, pending upload | Blocked on slow internet |
| 94–100, 101 | ~8 | ⬜ Not downloaded | Needs IQFeed session |

**Silver table total:** 1.74 billion 1-second bars across 66 batches
**Notable batch:** Batch 63 — 70.6M bars (Christmas/New Year 2025–2026 window, ~2.5× typical)

---

## 16. Operational Runbook

### Run a New Batch (GCE VM)

```bash
# 1. SSH into GCE VM
gcloud compute ssh vm-prd-iqfeed-docker --zone=us-central1-a --project=wa-equity-trading

# 2. Ensure symbols file is current
cat ~/symbols.txt | wc -l   # should be ~1040

# 3. Run batch (dates from Backfill Organizer sheet, output path includes Sheets ID)
bash ~/vm_batch_ingest.sh 20260223 20260224 raw/market-data/87-1LkaUcES...

# 4. Monitor progress
docker logs -f iqfeed

# 5. Verify _SUCCESS was written
gsutil ls gs://bkt-prd-iqfeed-raw-files-001/raw/market-data/87-1LkaUcES.../
```

### Manually Trigger a Workflow (Backfill)

```bash
gcloud workflows run ingest \
  --location=us-central1 \
  --project=wa-equity-trading \
  --data='{"data":{"name":"raw/market-data/<SHEETS_ID>/<UPLOAD_DATE>/_SUCCESS"}}'
```

### Bulk Backfill (Sequential)

```bash
cd waet-data-layer/
./scripts/bulk_ingest.sh           # sequential, one at a time
./scripts/bulk_archive.sh --parallel 10  # parallel groups of 10
```

### Deploy Updated Docker Image

```bash
cd iqfeed-docker/
gcloud builds submit --tag us-central1-docker.pkg.dev/wa-equity-trading/iqfeed/iqfeed-client:latest
```

### Update vm_batch_ingest.sh on VM

```bash
gcloud compute scp vm_batch_ingest.sh vm-prd-iqfeed-docker:~/vm_batch_ingest.sh \
  --zone=us-central1-a --project=wa-equity-trading
```

### Check Silver Table

```sql
SELECT
  DATE(ts_1sec)    AS trade_date,
  COUNT(DISTINCT symbol) AS symbols,
  COUNT(*)         AS bars,
  MIN(ts_1sec)     AS first_tick,
  MAX(ts_1sec)     AS last_tick
FROM `wa-equity-trading.ds_prd_silver.tick_1sec_001`
GROUP BY 1
ORDER BY 1 DESC
LIMIT 30;
```

### Check Failed Symbols

```sql
SELECT batch_id, symbol, reason, COUNT(*) AS n
FROM `wa-equity-trading.ds_prd_silver.failed_symbols`
GROUP BY 1, 2, 3
ORDER BY batch_id DESC;
```

---

## 17. Key Design Decisions

| Decision | Rationale |
|---|---|
| **Cloud Workflow instead of Cloud Run** | Pure API orchestration — BigQuery Jobs API + GCS API. No custom compute, no container management. |
| **Direct BQ INSERT instead of Dataform** | Dataform scanned 1.7 TB/batch ($12). Direct INSERT reads only the 2 GB batch ($0.01). 99.9% cost reduction. |
| **No bronze layer** | External table already reads raw CSVs from GCS. Bronze was a redundant copy. Silver is the only managed layer needed. |
| **Single wildcard external table** | BigQuery supports a single `*` in GCS URIs. One DDL per batch, no path enumeration. |
| **Marker file state machine** | Decouples pipeline stages. Each stage is independently retriable. No message queue needed. |
| **Sheets Reference ID spine** | One UUID ties local data, GCS paths, BQ rows, and analysis workbooks together — zero ambiguity. |
| **gcsfuse in container** | qdownload writes directly to GCS with zero local disk — no intermediate storage, no second upload step. |
| **Wine64 over wine32** | wine32 triggers virtual memory errors on amd64 emulation. wine64 is stable. |
| **force amd64 image** | IQFeed's Windows binary only runs on x86-64. ARM Mac cross-compilation via Docker buildx. |
| **Keepalive daemon** | IQFeed disconnects after 2 minutes of inactivity. 15-second pings prevent this at zero cost. |
| **Eventarc Standard (not Advanced)** | GCS `object.finalized` events are only available in Standard Eventarc. Advanced uses Message Bus but doesn't support GCS finalization directly. |
| **Paginated archive** | 1,040 symbols = 1,040 GCS objects. Iterating all in one Workflow step exceeds memory limits. 50-object pages are safe. |
| **Autoclass archive bucket** | Automatic tiering to ARCHIVE storage class for cold data — no manual lifecycle rule management. |
| **WIF for CI/CD** | Workload Identity Federation eliminates long-lived service account keys in GitHub repos. |
