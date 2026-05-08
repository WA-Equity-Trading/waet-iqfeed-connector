#!/bin/bash
# startup_with_poller.sh
# Extended VM startup script that:
#   1. Starts the IQFeed Docker container (existing behavior)
#   2. Downloads and starts the job poller (new automation)
#
# To deploy: replace the startup script in
#   infrastructure-setup/iac/resources/compute/scripts/iqfeed-docker/startup.sh
# Or set via: gcloud compute instances add-metadata vm-prd-iqfeed-docker \
#   --metadata-from-file startup-script=automation/startup_with_poller.sh

set -e

METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
METADATA_HEADER="Metadata-Flavor: Google"

# COS has read-only /root, use writable dir
export HOME=/home/chronos

# Wait for Docker daemon
while ! docker info > /dev/null 2>&1; do
  sleep 1
done

# Configure Docker auth for Artifact Registry
docker-credential-gcr configure-docker --registries=us-central1-docker.pkg.dev

# Read IQFeed credentials from instance metadata
LOGIN=$(curl -sf "${METADATA_URL}/iqfeed-login" -H "${METADATA_HEADER}")
PASSWORD=$(curl -sf "${METADATA_URL}/iqfeed-password" -H "${METADATA_HEADER}")
PRODUCT_ID=$(curl -sf "${METADATA_URL}/iqfeed-product-id" -H "${METADATA_HEADER}")

# Stop existing container if running
docker stop iqfeed 2>/dev/null || true
docker rm iqfeed 2>/dev/null || true

# Pull latest image
docker pull us-central1-docker.pkg.dev/wa-equity-trading/iqfeed/iqfeed-client:latest

# Run IQFeed container
docker run -d --restart=always \
  --name iqfeed \
  -e LOGIN="$LOGIN" \
  -e PASSWORD="$PASSWORD" \
  -e PRODUCT_ID="$PRODUCT_ID" \
  -p 5010:5010 \
  -p 9101:9101 \
  -p 9301:9301 \
  -p 5900:5900 \
  us-central1-docker.pkg.dev/wa-equity-trading/iqfeed/iqfeed-client:latest

# ── Job Poller Setup ────────────────────────────────────────────────────────
# Download vm_batch_ingest.sh and vm_job_poller.sh from GCS (or use metadata)
# These scripts should be pre-uploaded to the VM or stored in GCS.

SCRIPTS_BUCKET="bkt-prd-iqfeed-raw-files-001"
SCRIPTS_PREFIX="scripts"

# Get OAuth token for GCS access
TOKEN=$(curl -sf \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  -H "Metadata-Flavor: Google" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Download scripts from GCS
for SCRIPT in vm_batch_ingest.sh vm_job_poller.sh vm_queue_downloads.sh symbols.txt; do
  curl -sf \
    "https://storage.googleapis.com/storage/v1/b/${SCRIPTS_BUCKET}/o/$(python3 -c "import urllib.parse; print(urllib.parse.quote('${SCRIPTS_PREFIX}/${SCRIPT}', safe=''))")?alt=media" \
    -H "Authorization: Bearer ${TOKEN}" \
    -o "${HOME}/${SCRIPT}" 2>/dev/null && \
  chmod +x "${HOME}/${SCRIPT}" && \
  echo "Downloaded ${SCRIPT}" || \
  echo "Warning: could not download ${SCRIPT} from GCS"
done

# Start the job poller in the background
if [ -f "${HOME}/vm_job_poller.sh" ]; then
  echo "Starting job poller..."
  nohup bash "${HOME}/vm_job_poller.sh" > "${HOME}/job_poller.log" 2>&1 &
  echo "Job poller started (PID $!)."
else
  echo "Warning: vm_job_poller.sh not found. Job poller not started."
fi

# Start the queue downloader.
# The script self-throttles to once per day by default, and this wrapper
# sleeps for a day between invocations to avoid unnecessary wakeups.
if [ -f "${HOME}/vm_queue_downloads.sh" ]; then
  echo "Starting queue downloader..."
  nohup bash -c "while true; do bash ${HOME}/vm_queue_downloads.sh >> ${HOME}/queue_downloads.log 2>&1; sleep 86400; done" >> "${HOME}/queue_downloader_wrapper.log" 2>&1 &
  echo "Queue downloader started (PID $!)."
else
  echo "Warning: vm_queue_downloads.sh not found. Queue downloader not started."
fi
