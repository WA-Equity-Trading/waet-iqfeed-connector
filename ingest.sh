#!/bin/bash
set -e
BUCKET="bkt-prd-iqfeed-raw-files-001"
MOUNT="/mnt/gcs"
DATE=$(date +%Y/%m/%d)
SYMBOLS="${SYMBOLS:-SPY,AAPL,MSFT}"
echo "=== Starting ingestion for $DATE ==="
mkdir -p $MOUNT
gcsfuse --implicit-dirs --log-severity WARNING $BUCKET $MOUNT 2>/dev/null
mkdir -p $MOUNT/eod/$DATE
qdownload -s $(date +%Y%m%d) -e $(date +%Y%m%d) -o $MOUNT/eod/$DATE eod $SYMBOLS
fusermount -u $MOUNT || true
echo "=== Done! ==="
