#!/bin/bash
# vm_job_poller.sh
# Runs on the GCP VM (COS host). Polls GCS for pending job files and
# executes vm_batch_ingest.sh for each one.
#
# Deployed via startup script as a background process.
# Uses curl + GCS JSON API + instance metadata token (no gsutil needed on COS).
#
# GCS job queue layout:
#   jobs/pending/<job_id>.json    ← written by Apps Script
#   jobs/running/<job_id>.json    ← moved here while ingesting
#   jobs/completed/<job_id>.json  ← moved here after _SUCCESS

set -euo pipefail

BUCKET="bkt-prd-iqfeed-raw-files-001"
PENDING_PREFIX="jobs/pending/"
RUNNING_PREFIX="jobs/running/"
COMPLETED_PREFIX="jobs/completed/"
POLL_INTERVAL=60
LOCK_FILE="/tmp/iqfeed_job_poller.lock"
LOG_TAG="[job-poller]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG $*"; }

# ── GCS helpers (COS has curl but not gsutil) ────────────────────────────────

get_token() {
  curl -sf \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    -H "Metadata-Flavor: Google" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null \
  || curl -sf \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    -H "Metadata-Flavor: Google" | grep -oP '"access_token":"\K[^"]*'
}

gcs_list() {
  local token="$1" prefix="$2"
  curl -sf \
    "https://storage.googleapis.com/storage/v1/b/${BUCKET}/o?prefix=${prefix}&fields=items/name" \
    -H "Authorization: Bearer ${token}"
}

gcs_read() {
  local token="$1" object="$2"
  curl -sf \
    "https://storage.googleapis.com/storage/v1/b/${BUCKET}/o/$(urlencode "$object")?alt=media" \
    -H "Authorization: Bearer ${token}"
}

gcs_upload() {
  local token="$1" object="$2" content="$3"
  curl -sf -X POST \
    "https://storage.googleapis.com/upload/storage/v1/b/${BUCKET}/o?uploadType=media&name=$(urlencode "$object")" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$content" > /dev/null
}

gcs_delete() {
  local token="$1" object="$2"
  curl -sf -X DELETE \
    "https://storage.googleapis.com/storage/v1/b/${BUCKET}/o/$(urlencode "$object")" \
    -H "Authorization: Bearer ${token}" > /dev/null 2>&1 || true
}

gcs_move() {
  local token="$1" from="$2" to="$3"
  local content
  content=$(gcs_read "$token" "$from")
  gcs_upload "$token" "$to" "$content"
  gcs_delete "$token" "$from"
}

urlencode() {
  python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))" 2>/dev/null \
  || echo "$1" | sed 's|/|%2F|g'
}

# ── Market hours check ───────────────────────────────────────────────────────

is_market_hours() {
  local utc_hour utc_min dow month offset et_hour time_min
  utc_hour=$(date -u +%H | sed 's/^0*//' ); utc_hour=${utc_hour:-0}
  utc_min=$(date -u +%M | sed 's/^0*//' );  utc_min=${utc_min:-0}
  dow=$(date -u +%u)   # 1=Mon … 7=Sun
  month=$(date -u +%m | sed 's/^0*//' ); month=${month:-1}

  # Weekend → not market hours
  [ "$dow" -ge 6 ] && return 1

  # EDT (UTC-4) March–November, EST (UTC-5) otherwise
  offset=5
  [ "$month" -ge 3 ] && [ "$month" -le 11 ] && offset=4

  et_hour=$(( (utc_hour - offset + 24) % 24 ))
  time_min=$(( et_hour * 60 + utc_min ))

  # Market hours: 9:30 (570) – 16:00 (960) ET
  [ "$time_min" -ge 570 ] && [ "$time_min" -lt 960 ] && return 0
  return 1
}

# ── Main loop ────────────────────────────────────────────────────────────────

# Prevent multiple instances
if [ -f "$LOCK_FILE" ]; then
  OTHER_PID=$(cat "$LOCK_FILE" 2>/dev/null)
  if kill -0 "$OTHER_PID" 2>/dev/null; then
    log "Another instance running (PID $OTHER_PID). Exiting."
    exit 0
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log "Starting job poller (poll every ${POLL_INTERVAL}s)."

while true; do
  sleep "$POLL_INTERVAL"

  # Skip during market hours
  if is_market_hours; then
    continue
  fi

  TOKEN=$(get_token)
  if [ -z "$TOKEN" ]; then
    log "Failed to get metadata token. Retrying..."
    continue
  fi

  # List pending jobs
  RESPONSE=$(gcs_list "$TOKEN" "$PENDING_PREFIX")
  JOB_FILES=$(echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item['name']
    if name.endswith('.json'):
        print(name)
" 2>/dev/null || true)

  [ -z "$JOB_FILES" ] && continue

  # Process one job at a time
  JOB_FILE=$(echo "$JOB_FILES" | head -1)
  JOB_ID=$(basename "$JOB_FILE" .json)

  log "Found pending job: $JOB_ID"

  # Read job details
  JOB_JSON=$(gcs_read "$TOKEN" "$JOB_FILE")
  START_DATE=$(echo "$JOB_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['start_date'])")
  END_DATE=$(echo "$JOB_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['end_date'])")
  OUTPUT_PATH=$(echo "$JOB_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['output_path'])")

  log "Job $JOB_ID: start=$START_DATE end=$END_DATE output=$OUTPUT_PATH"

  # Move to running
  gcs_move "$TOKEN" "$JOB_FILE" "${RUNNING_PREFIX}${JOB_ID}.json"
  log "Moved $JOB_ID to running."

  # Execute vm_batch_ingest.sh (blocking — one job at a time)
  log "Starting vm_batch_ingest.sh for $JOB_ID..."
  if bash ~/vm_batch_ingest.sh "$START_DATE" "$END_DATE" "$OUTPUT_PATH" >> ~/ingest_${JOB_ID}.log 2>&1; then
    log "Job $JOB_ID completed successfully."
    # Refresh token (ingestion can take hours)
    TOKEN=$(get_token)
    gcs_move "$TOKEN" "${RUNNING_PREFIX}${JOB_ID}.json" "${COMPLETED_PREFIX}${JOB_ID}.json"
  else
    log "Job $JOB_ID failed. Leaving in running/ for manual review."
    # Move back to pending for retry? Or leave in running for investigation.
    # Leaving in running — operator can move back to pending/ to retry.
  fi

done
