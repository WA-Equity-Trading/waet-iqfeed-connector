# IQFeed GCP Data Ingestion Pipeline

**Technical Guide & Operations Manual**  
Version 1.0 | March 2026

---

## 1. Overview

This document describes the IQFeed market data ingestion pipeline built on Google Cloud Platform. The pipeline downloads historical tick, EOD, and minute bar data from DTN IQFeed and stores it in Google Cloud Storage for downstream processing.

### 1.1 Architecture Summary

The pipeline consists of the following layers:

- **IQFeed Docker Container** running on a GCE VM (Wine64 + Ubuntu 22.04)
- **gcsfuse** mounting GCS bucket directly as a local filesystem
- **qdownload** CLI tool writing data directly to GCS via the mount
- **vm_batch_ingest.sh** script with auto-restart loop on IQFeed disconnects

Marker ownership:

- This repo writes `_SUCCESS` to the raw bucket when batch upload/download completes.
- This repo does not write workflow-owned downstream markers.
- `_SILVER_READY` and `_READY_TO_ARCHIVE` are written later by Cloud Workflows to the markers bucket.

### 1.2 Data Flow

```
DTN IQFeed Servers
        ↓  (TCP connection via Wine64)
IQFeed Client (iqconnect.exe inside container)
        ↓  (port 9100/9300 → proxy 9101/9301)
qdownload CLI (Go binary inside container)
        ↓  (writes via gcsfuse mount)
GCS: gs://<bucket>/raw/market-data/<job-id>/
```

---

## 2. Infrastructure

### 2.1 GCP Resources

| Resource | Details |
|----------|---------|
| Region | us-central1 |
| GCE VM | vm-prd-zt-iqfeed-docker (e2-standard-2, zone: us-central1-a) |
| VM OS | Container-Optimized OS (COS) |
| GCS Bucket | bkt-prd-iqfeed-raw-files-001 |
| Artifact Registry | us-central1-docker.pkg.dev/wa-equity-trading/iqfeed/iqfeed-client |

### 2.2 Docker Container

| Component | Details |
|-----------|---------|
| Base Image | ubuntu:22.04 (--platform=linux/amd64) |
| Wine | Wine64 (WINEARCH=win64, WINEPREFIX=/root/.wine64) |
| IQFeed Client | iqconnect.exe v6.2.0.25 |
| Process Manager | Supervisor (6 services) |
| gcsfuse | For direct GCS writes |
| qdownload | github.com/nhedlund/qdownload@latest |
| Go | go1.22.0 (linux-amd64) |
| Ports | 5010, 9101, 9301, 5900 (VNC) |

### 2.3 Supervisor Services

The container runs 6 supervisor-managed services:

- **X11 (Xvfb)** — Virtual display required by Wine/IQFeed
- **fluxbox** — Lightweight window manager
- **x11vnc** — VNC server on port 5900 for remote GUI access
- **iqfeed-startup** — IQFeed launcher with auto-restart loop
- **iqfeed-proxy** — Node.js proxy (ports 9101/9301 → 9100/9300)
- **iqfeed-keepalive** — Pings IQFeed every 15s to prevent idle timeout

---

## 3. Container Startup

### 3.1 Docker Login (required after token expiry ~1hr)

```bash
docker login -u oauth2accesstoken \
  -p "$(curl -sf 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
  -H 'Metadata-Flavor: Google' | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')" \
  us-central1-docker.pkg.dev
```

### 3.2 Start Container

```bash
docker run -d --restart=always \
  --name iqfeed \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  --security-opt apparmor=unconfined \
  -e LOGIN="$(curl -sf 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/iqfeed-login' -H 'Metadata-Flavor: Google')" \
  -e PASSWORD="$(curl -sf 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/iqfeed-password' -H 'Metadata-Flavor: Google')" \
  -e PRODUCT_ID="$(curl -sf 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/iqfeed-product-id' -H 'Metadata-Flavor: Google')" \
  -e SYMBOLS="SPY,AAPL,MSFT" \
  -p 5010:5010 -p 9101:9101 -p 9301:9301 -p 5900:5900 \
  us-central1-docker.pkg.dev/wa-equity-trading/iqfeed/iqfeed-client:latest
```

> **Note:** `--cap-add SYS_ADMIN` and `--device /dev/fuse` are required for gcsfuse. Do NOT use `--privileged`.
>
> **Note:** IQFeed credentials are stored in GCE instance metadata, never in the image.

### 3.3 Verify IQFeed Connected

```bash
sleep 120 && docker exec iqfeed tail -5 /var/log/supervisor/$(docker exec iqfeed ls /var/log/supervisor/ | grep keepalive-stdout)
```

Expected output when connected:

```
[keepalive] Admin ping OK: S,STATS,...,Connect
```

---

## 4. SSH & VNC Access

### 4.1 SSH into VM

```bash
gcloud compute ssh vm-prd-zt-iqfeed-docker --zone=us-central1-a -- -L 5900:localhost:5900
```

The `-L` flag tunnels VNC port 5900 to your local machine.

### 4.2 VNC Access (GUI)

After SSH with port forwarding, on your Mac run:

```bash
open vnc://localhost:5900
```

---

## 5. Data Ingestion

### 5.1 GCS Bucket Structure

```
gs://bkt-prd-iqfeed-raw-files-001/
  raw/
    market-data/
      <job-id>/          ← each download job
        AAPL.csv
        MSFT.csv
        SPY.csv
        ...
  eod/
    YYYY/MM/DD/          ← daily EOD data
      SPY.csv
```

### 5.2 gcsfuse Mount

gcsfuse mounts the GCS bucket as a local filesystem inside the container, allowing qdownload to write directly to GCS without local storage.

```bash
gcsfuse --implicit-dirs --log-severity WARNING bkt-prd-iqfeed-raw-files-001 /mnt/gcs 2>/dev/null
```

> **Note:** Always use `--implicit-dirs` flag to handle subdirectories correctly.

### 5.3 Manual Download (Single Run)

Copy symbols file into container then run qdownload:

```bash
docker cp ~/symbols.txt iqfeed:/root/symbols.txt
docker exec iqfeed bash -c "
  mkdir -p /mnt/gcs && \
  gcsfuse --implicit-dirs --log-severity WARNING bkt-prd-iqfeed-raw-files-001 /mnt/gcs 2>/dev/null && \
  SYMBOLS=\$(cat /root/symbols.txt | tr '\n' ',' | sed 's/,\$//') && \
  qdownload -p 2 -o /mnt/gcs/raw/market-data/<job-id> -s <start> -e <end> tick \$SYMBOLS && \
  fusermount -u /mnt/gcs || true
"
```

### 5.4 Automated Batch Download (Recommended)

Use `vm_batch_ingest.sh` which automatically restarts IQFeed and resumes downloads when connection drops:

```bash
bash ~/vm_batch_ingest.sh <start_date> <end_date> <output_path>
```

Example:

```bash
bash ~/vm_batch_ingest.sh 20260304 20260306 raw/market-data/<job-id>
```

- qdownload automatically skips already-downloaded symbols. Safe to re-run multiple times.
- The script monitors IQFeed health every 10 seconds and kills/restarts qdownload if IQFeed is down for 30+ seconds.

### 5.5 vm_batch_ingest.sh Logic

The script runs an infinite loop:

1. Start fresh container with proper gcsfuse permissions
2. Wait for IQFeed to connect (checks keepalive log for 'ping OK')
3. Copy symbols.txt into container
4. Run qdownload in background
5. Monitor IQFeed health every 10s in parallel
6. If IQFeed down for 3 consecutive checks → kill qdownload → go to step 1
7. If qdownload exits successfully → break loop → done

---

## 6. Symbols File

### 6.1 Location

The symbols file lives on the VM: `~/symbols.txt` (must be copied to container before each run).

### 6.2 Copy to VM

```bash
gcloud compute scp /path/to/symbols.txt vm-prd-zt-iqfeed-docker:~ --zone=us-central1-a
```

### 6.3 Known Symbol Issues

- **CFG/PI** — Slash in symbol name causes path issue in gcsfuse. qdownload skips it with an error. This is expected.
- **NO_DATA** — Some symbols return `!NO_DATA!` for certain date ranges (delisted, halted, or no trading that day). This is normal.

---

## 7. Known Issues & Solutions

### 7.1 IQFeed Crashes Every ~2 Minutes

**Root cause:** Wine compatibility on amd64 GCE VM. iqconnect.exe may crash.

**Solution:** The iqfeed-startup supervisor service auto-restarts IQFeed in a loop. The vm_batch_ingest.sh script detects disconnects and restarts the container automatically.

### 7.2 Docker Login Token Expiry

**Root cause:** GCE metadata service tokens expire after ~1 hour.

**Solution:** Re-authenticate before pulling images (see section 3.1).

### 7.3 gcsfuse Verbose Logs

gcsfuse logs full JSON config on every mount. Suppress with:

```bash
gcsfuse --implicit-dirs --log-severity WARNING <bucket> <mount> 2>/dev/null
```

### 7.4 Two qdownload Processes Running

Can happen if script is run twice. Fix:

```bash
docker exec iqfeed bash -c "pkill qdownload; fusermount -u /mnt/gcs 2>/dev/null || true"
```

### 7.5 Weekend / Holiday NO_DATA Errors

IQFeed returns `!NO_DATA!` for dates when markets are closed. This is expected behavior, not an error.

---

## 8. Build & Deploy

### 8.1 Rebuild Docker Image

```bash
cd iqfeed-docker
gcloud builds submit \
  --tag us-central1-docker.pkg.dev/wa-equity-trading/iqfeed/iqfeed-client:latest \
  .
```

> **Note:** gcsfuse must be installed AFTER Wine in the Dockerfile using `--no-upgrade` flag to prevent library conflicts.

### 8.2 Update vm_batch_ingest.sh on VM

```bash
gcloud compute scp iqfeed-docker/vm_batch_ingest.sh vm-prd-zt-iqfeed-docker:~ --zone=us-central1-a
```

### 8.3 Key Dockerfile Requirements

- `FROM --platform=linux/amd64 ubuntu:22.04` — force x86 for Wine
- `WINEARCH=win64` — use 64-bit Wine prefix
- `--cap-add SYS_ADMIN --device /dev/fuse` — minimum permissions for gcsfuse
- gcsfuse installed with `--no-upgrade` to protect Wine libraries
- Credentials via GCE metadata, never baked into image

---

## 9. Planned: Google Sheets → Pub/Sub Automation

### 9.1 Architecture

The next phase will allow users to trigger downloads directly from Google Sheets:

```
Google Sheets (user fills: start_date, end_date, job_id)
        ↓  Apps Script publishes on button click
Pub/Sub Topic: iqfeed-download-requests
        ↓  Cloud Run subscribes
Cloud Run SSHs into VM and runs vm_batch_ingest.sh
        ↓
Data lands in GCS
```

### 9.2 Pub/Sub Message Format

```json
{
  "start_date": "20260306",
  "end_date": "20260310",
  "output_path": "raw/market-data/<job-id>",
  "symbols_file": "gs://bkt-prd-iqfeed-raw-files-001/config/symbols.txt"
}
```

---

## 10. Repository Structure

| Path | Description |
|------|-------------|
| `Dockerfile` | Container definition (Wine + IQFeed + gcsfuse + qdownload) |
| `supervisord.conf` | Supervisor service definitions |
| `iqfeed_startup.sh` | IQFeed auto-restart loop script |
| `iqfeed_keepalive.sh` | IQFeed keepalive ping script |
| `ingest.sh` | Simple EOD ingestion script |
| `vm_batch_ingest.sh` | VM-level batch download with auto-restart |
| `app/proxy.js` | Node.js connection proxy |
| `docs/INGESTION_GUIDE.md` | This document |

---

## 11. Quick Reference

### 11.1 Daily Operations Checklist

1. SSH into VM: `gcloud compute ssh vm-prd-zt-iqfeed-docker --zone=us-central1-a -- -L 5900:localhost:5900`
2. Re-authenticate Docker if needed (token expires ~1hr)
3. Copy latest symbols.txt to VM if updated
4. Run vm_batch_ingest.sh with correct date range and job ID
5. Monitor progress — script auto-retries on IQFeed disconnect
6. Verify data in GCS console after completion

### 11.2 Useful Commands

| Command | Purpose |
|---------|---------|
| `docker exec iqfeed supervisorctl status` | Check all 6 services running |
| `docker stats iqfeed --no-stream` | Check container resource usage |
| `docker exec iqfeed ps aux \| grep qdownload` | Check if download is running |
| `gcloud storage ls gs://bkt-prd-iqfeed-raw-files-001/raw/market-data/<job-id>/ \| wc -l` | Count downloaded files |
| `docker restart iqfeed` | Restart container if IQFeed stuck |
