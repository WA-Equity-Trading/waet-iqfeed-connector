#!/bin/bash
# vm_batch_ingest.sh
# Runs on the GCP VM. Restarts container and resumes download until complete.
# Usage: bash ~/vm_batch_ingest.sh <start_date> <end_date> <output_path>
# Example: bash ~/vm_batch_ingest.sh 20260304 20260306 raw/market-data/my-batch

START_DATE="${1:?Usage: $0 <start_date> <end_date> <output_path>}"
END_DATE="${2:?Usage: $0 <start_date> <end_date> <output_path>}"
OUTPUT_PATH="${3:?Usage: $0 <start_date> <end_date> <output_path>}"
IMAGE="us-central1-docker.pkg.dev/wa-equity-trading/iqfeed/iqfeed-client:latest"
FAIL_COUNT=0
PARALLELISM=32
MAX_ATTEMPTS=5

start_container() {
  echo "=== Stopping old container ==="
  docker stop iqfeed 2>/dev/null || true
  docker rm iqfeed 2>/dev/null || true

  echo "=== Starting fresh container ==="
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
    $IMAGE
}

wait_for_iqfeed() {
  echo "=== Waiting for IQFeed to connect ==="
  for i in {1..24}; do
    STATUS=$(docker exec iqfeed tail -1 /var/log/supervisor/$(docker exec iqfeed ls /var/log/supervisor/ | grep keepalive-stdout) 2>/dev/null)
    if echo "$STATUS" | grep -q "ping OK"; then
      echo "=== IQFeed connected! ==="
      return 0
    fi
    echo "  Waiting... ($((i*5))/120s) - $STATUS"
    sleep 5
  done
  echo "IQFeed not ready after 120s, restarting container..."
  return 1
}

run_download() {
  INGEST_DATE=$(date +%Y-%m-%d)

  echo "=== Copying symbols file ==="
  docker cp ~/symbols.txt iqfeed:/root/symbols.txt

  echo "=== Running download ==="
  docker exec iqfeed bash -c "
    mkdir -p /mnt/gcs && \
    gcsfuse --implicit-dirs --log-severity WARNING bkt-prd-iqfeed-raw-files-001 /mnt/gcs 2>/dev/null && \
    mkdir -p /mnt/gcs/$OUTPUT_PATH/$INGEST_DATE && \
    SYMBOLS=\$(cat /root/symbols.txt | tr '\n' ',' | sed 's/,\$//') && \
    qdownload -p $PARALLELISM \
      -o /mnt/gcs/$OUTPUT_PATH/$INGEST_DATE \
      -s $START_DATE -e $END_DATE \
      tick \$SYMBOLS 2>&1 | tee /tmp/qdownload.log
    fusermount -u /mnt/gcs || true
  " &
  QDOWNLOAD_PID=$!

  # Monitor IQFeed health while qdownload runs
  while kill -0 $QDOWNLOAD_PID 2>/dev/null; do
    STATUS=$(docker exec iqfeed tail -1 /var/log/supervisor/$(docker exec iqfeed ls /var/log/supervisor/ | grep keepalive-stdout) 2>/dev/null)
    if echo "$STATUS" | grep -q "timed out"; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo "IQFeed unhealthy ($FAIL_COUNT/3)..."
      if [ $FAIL_COUNT -ge 3 ]; then
        echo "=== IQFeed down, killing qdownload and retrying ==="
        docker exec iqfeed bash -c "pkill qdownload 2>/dev/null; fusermount -u /mnt/gcs 2>/dev/null || true"
        kill $QDOWNLOAD_PID 2>/dev/null
        FAIL_COUNT=0
        return 1
      fi
    else
      FAIL_COUNT=0
    fi
    sleep 10
  done

  wait $QDOWNLOAD_PID
  local EXIT_CODE=$?
  [ $EXIT_CODE -ne 0 ] && return $EXIT_CODE

  echo "=== Parsing failures and writing _FAILED.csv ==="
  docker exec iqfeed bash -c "
    mkdir -p /mnt/gcs && \
    gcsfuse --implicit-dirs --log-severity WARNING bkt-prd-iqfeed-raw-files-001 /mnt/gcs 2>/dev/null

    echo 'symbol,reason,date' > /mnt/gcs/$OUTPUT_PATH/$INGEST_DATE/_FAILED.csv

    grep -oP '(?<=Map row error).*' /tmp/qdownload.log | while IFS= read -r line; do
      SYM=\$(echo \"\$line\" | grep -oP 'symbol=\K\S+')
      REASON=\$(echo \"\$line\" | grep -oP '!\K\w+(?=!)')
      [ -n \"\$SYM\" ] && echo \"\${SYM},!\${REASON}!,$START_DATE\"
    done >> /mnt/gcs/$OUTPUT_PATH/$INGEST_DATE/_FAILED.csv

    grep -oP '(?<=Could not create output file).*' /tmp/qdownload.log | while IFS= read -r line; do
      SYM=\$(echo \"\$line\" | grep -oP 'symbol=\K\S+')
      [ -n \"\$SYM\" ] && echo \"\${SYM},could not create output file,$START_DATE\"
    done >> /mnt/gcs/$OUTPUT_PATH/$INGEST_DATE/_FAILED.csv

    # _SUCCESS is the uploader-owned raw-bucket trigger marker for s1.
    touch /mnt/gcs/$OUTPUT_PATH/$INGEST_DATE/_SUCCESS

    fusermount -u /mnt/gcs || true
  "

  echo "=== _FAILED.csv and _SUCCESS written ==="
  return 0
}

# Main loop with max attempts
ATTEMPT=0
while true; do
  ATTEMPT=$((ATTEMPT + 1))
  echo ""
  echo "========================================="
  echo "=== ATTEMPT $ATTEMPT / $MAX_ATTEMPTS ==="
  echo "========================================="

  if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
    echo "=== FAILED: Max attempts ($MAX_ATTEMPTS) exceeded ==="
    exit 1
  fi

  start_container
  wait_for_iqfeed || continue

  run_download && break

  echo "=== Download interrupted, retrying... ==="
  sleep 10
done

echo "=== All symbols downloaded! gs://bkt-prd-iqfeed-raw-files-001/$OUTPUT_PATH ==="
