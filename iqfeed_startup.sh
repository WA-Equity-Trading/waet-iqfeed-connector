#!/bin/bash

export WINEARCH=win64
export WINEPREFIX=/root/.wine64
export DISPLAY=:0
export WINEDEBUG=-all

INSTALLER="/root/${IQFEED_INSTALLER:-iqfeed_client_6_2_0_25.exe}"

# Check multiple possible install locations
iqconnect_exe=""
for path in \
  "/root/.wine64/drive_c/Program Files/DTN/IQFeed/iqconnect.exe" \
  "/root/.wine64/drive_c/Program Files (x86)/DTN/IQFeed/iqconnect.exe" \
  "/root/.wine/drive_c/Program Files/DTN/IQFeed/iqconnect.exe" \
  "/root/.wine/drive_c/Program Files (x86)/DTN/IQFeed/iqconnect.exe"; do
  if [ -f "$path" ]; then
    iqconnect_exe="$path"
    break
  fi
done

if [ -n "$iqconnect_exe" ]; then
  echo "IQFeed found at: $iqconnect_exe"
  echo "Launching IQFeed client with autoconnect..."

  # Run iqconnect in a loop - if it crashes, restart it immediately
  while true; do
    echo "[$(date)] Starting iqconnect.exe..."
    wine64 "$iqconnect_exe" \
      -autoconnect \
      -product "${PRODUCT_ID:-IQFEED_DEMO}" \
      -version 6.2.0.25 \
      -login "${LOGIN:-523028}" \
      -password "${PASSWORD:-}" 2>&1

    EXIT_CODE=$?
    echo "[$(date)] iqconnect.exe exited with code $EXIT_CODE. Restarting in 3 seconds..."
    sleep 3
  done
else
  echo "IQFeed not installed. Running installer: $INSTALLER"
  # Initialize Wine prefix and fix drive mappings
  wineboot --init 2>&1 | head -n 5 || true
  sleep 3
  mkdir -p "$WINEPREFIX/dosdevices"
  ln -sfn "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices/c:"
  ln -sfn / "$WINEPREFIX/dosdevices/z:"
  # Run installer silently
  wine64 "$INSTALLER" /S 2>&1
  echo "Installer finished. Restarting startup script..."
  # After installation, re-run this script to find and launch iqconnect
  exec "$0"
fi
