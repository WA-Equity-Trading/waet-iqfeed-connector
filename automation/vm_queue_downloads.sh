#!/bin/bash
# vm_queue_downloads.sh
# Runs on the GCP VM. Reads batch_action_queue for DOWNLOAD batches and
# writes a job JSON to GCS jobs/pending/ for each one.
#
# The existing vm_job_poller.sh picks up jobs from jobs/pending/ and
# executes vm_batch_ingest.sh for each one.
#
# Usage:
#   bash ~/vm_queue_downloads.sh            # queue all pending DOWNLOAD batches
#   bash ~/vm_queue_downloads.sh --dry-run  # print what would be queued, no writes
#
# Schedule: run daily after midnight (after diagnostics-daily refreshes batch_action_queue).
# Example cron (runs at 00:30 ET = 04:30 UTC):
#   30 4 * * * bash ~/vm_queue_downloads.sh >> ~/queue_downloads.log 2>&1
#
# Job JSON format (read by vm_job_poller.sh):
#   {"start_date":"YYYYMMDD","end_date":"YYYYMMDD","output_path":"raw/market-data/<batch_id>"}

set -euo pipefail

BUCKET="bkt-prd-iqfeed-raw-files-001"
PENDING_PREFIX="jobs/pending/"
RUNNING_PREFIX="jobs/running/"
COMPLETED_PREFIX="jobs/completed/"
LOG_TAG="[queue-downloads]"
DRY_RUN=false

[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG $*"; }

# ── GCS helpers (same pattern as vm_job_poller.sh) ───────────────────────────

get_token() {
  curl -sf \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    -H "Metadata-Flavor: Google" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null \
  || curl -sf \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    -H "Metadata-Flavor: Google" | grep -oP '"access_token":"\K[^"]*'
}

urlencode() {
  python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))" 2>/dev/null \
  || echo "$1" | sed 's|/|%2F|g'
}

gcs_object_exists() {
  local token="$1" object="$2"
  local status
  status=$(curl -sf -o /dev/null -w "%{http_code}" \
    "https://storage.googleapis.com/storage/v1/b/${BUCKET}/o/$(urlencode "$object")" \
    -H "Authorization: Bearer ${token}")
  [ "$status" = "200" ]
}

gcs_upload() {
  local token="$1" object="$2" content="$3"
  curl -sf -X POST \
    "https://storage.googleapis.com/upload/storage/v1/b/${BUCKET}/o?uploadType=media&name=$(urlencode "$object")" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$content" > /dev/null
}

# ── Query BQ for DOWNLOAD batches (BQ REST API — no bq CLI needed on COS) ───
#
# Reads from the most recent partition of batch_action_queue.
# Returns lines of: batch_id,start_date_raw,end_date_raw

query_download_batches() {
  local token="$1"
  local project="wa-equity-trading"

  # Use heredoc for SQL to avoid backtick/quoting issues in shell
  local sql
  sql=$(cat <<'ENDSQL'
SELECT batch_id, start_date_raw, end_date_raw
FROM `wa-equity-trading.ds_prd_diagnostics.diag_batch_action_queue_v001`
WHERE recommended_action = 'DOWNLOAD'
  AND DATE(refreshed_at) = (SELECT MAX(DATE(refreshed_at)) FROM `wa-equity-trading.ds_prd_diagnostics.diag_batch_action_queue_v001`)
ORDER BY start_date_raw ASC
ENDSQL
)

  # Build JSON payload via python3 stdin to avoid shell quoting of backticks
  local payload
  payload=$(echo "$sql" | python3 -c "
import json, sys
sql = sys.stdin.read().strip()
print(json.dumps({'query': sql, 'useLegacySql': False, 'timeoutMs': 30000}))
")

  local response
  response=$(curl -sf -X POST \
    "https://bigquery.googleapis.com/bigquery/v2/projects/${project}/queries" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  # Parse rows → "batch_id,start_date,end_date" lines
  echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for row in data.get('rows', []):
    vals = [f.get('v', '') or '' for f in row.get('f', [])]
    print(','.join(vals))
"
}

# ── Main ─────────────────────────────────────────────────────────────────────

log "Querying batch_action_queue for DOWNLOAD batches..."

# Get token once
TOKEN=$(get_token)
if [ -z "$TOKEN" ]; then
  log "ERROR: Failed to get metadata token."
  exit 1
fi

# Run BQ query
ROWS=$(query_download_batches "$TOKEN")

if [ -z "$ROWS" ]; then
  log "No DOWNLOAD batches found in batch_action_queue. Nothing to queue."
  exit 0
fi

QUEUED=0
SKIPPED=0

while IFS=',' read -r BATCH_ID START_DATE END_DATE; do
  # Strip any quotes that BQ CSV may add
  BATCH_ID="${BATCH_ID//\"/}"
  START_DATE="${START_DATE//\"/}"
  END_DATE="${END_DATE//\"/}"

  [ -z "$BATCH_ID" ] && continue

  PENDING_KEY="${PENDING_PREFIX}${BATCH_ID}.json"
  RUNNING_KEY="${RUNNING_PREFIX}${BATCH_ID}.json"
  COMPLETED_KEY="${COMPLETED_PREFIX}${BATCH_ID}.json"

  # Skip if already in any queue state
  if gcs_object_exists "$TOKEN" "$PENDING_KEY"; then
    log "SKIP $BATCH_ID — already in jobs/pending/"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  if gcs_object_exists "$TOKEN" "$RUNNING_KEY"; then
    log "SKIP $BATCH_ID — already in jobs/running/"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  if gcs_object_exists "$TOKEN" "$COMPLETED_KEY"; then
    log "SKIP $BATCH_ID — already in jobs/completed/"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  JOB_JSON="{\"start_date\":\"${START_DATE}\",\"end_date\":\"${END_DATE}\",\"output_path\":\"raw/market-data/${BATCH_ID}\"}"

  if $DRY_RUN; then
    log "DRY-RUN would queue: $BATCH_ID ($START_DATE → $END_DATE) → $PENDING_KEY"
  else
    gcs_upload "$TOKEN" "$PENDING_KEY" "$JOB_JSON"
    log "Queued: $BATCH_ID ($START_DATE → $END_DATE)"
  fi

  QUEUED=$((QUEUED + 1))
done <<< "$ROWS"

log "Done. Queued=$QUEUED Skipped=$SKIPPED"
