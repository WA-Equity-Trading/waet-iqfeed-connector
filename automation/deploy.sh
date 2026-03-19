#!/bin/bash
# deploy.sh
# Uploads automation scripts to GCS and optionally updates the VM startup script.
#
# Usage:
#   bash automation/deploy.sh              # upload scripts to GCS only
#   bash automation/deploy.sh --startup    # also update VM startup script

set -euo pipefail

PROJECT="wa-equity-trading"
ZONE="us-central1-a"
VM="vm-prd-iqfeed-docker"
BUCKET="bkt-prd-iqfeed-raw-files-001"
SCRIPTS_PREFIX="scripts"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Uploading scripts to gs://${BUCKET}/${SCRIPTS_PREFIX}/ ==="

gsutil cp "${REPO_DIR}/vm_batch_ingest.sh"       "gs://${BUCKET}/${SCRIPTS_PREFIX}/vm_batch_ingest.sh"
gsutil cp "${SCRIPT_DIR}/vm_job_poller.sh"        "gs://${BUCKET}/${SCRIPTS_PREFIX}/vm_job_poller.sh"
gsutil cp "${REPO_DIR}/symbols.txt"               "gs://${BUCKET}/${SCRIPTS_PREFIX}/symbols.txt"

echo "=== Scripts uploaded. ==="

if [ "${1:-}" = "--startup" ]; then
  echo "=== Updating VM startup script ==="
  gcloud compute instances add-metadata "$VM" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --metadata-from-file startup-script="${SCRIPT_DIR}/startup_with_poller.sh"
  echo "=== Startup script updated. Restart VM to apply: ==="
  echo "    gcloud compute instances reset $VM --project=$PROJECT --zone=$ZONE"
fi

echo ""
echo "=== To start the poller manually (without VM restart): ==="
echo "    gcloud compute ssh $VM --project=$PROJECT --zone=$ZONE --command=\""
echo "      curl -sf 'https://storage.googleapis.com/storage/v1/b/${BUCKET}/o/$(python3 -c "import urllib.parse; print(urllib.parse.quote('scripts/vm_job_poller.sh', safe=''))")?alt=media' \\"
echo "        -H 'Authorization: Bearer \$(curl -sf http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token -H Metadata-Flavor:Google | python3 -c \"import sys,json;print(json.load(sys.stdin)[\\\"access_token\\\"])\")' \\"
echo "        -o ~/vm_job_poller.sh && chmod +x ~/vm_job_poller.sh && \\"
echo "      nohup bash ~/vm_job_poller.sh > ~/job_poller.log 2>&1 &\""
echo ""
echo "=== Done ==="
