#!/bin/bash
set -e

echo "=== IQFeed Startup Script ==="

# Check if IQFeed client is installed
iqconnect_patched="/root/.wine/drive_c/Program Files/DTN/IQFeed/iqconnect_patched.exe"
iqconnect_orig="/root/.wine/drive_c/Program Files/DTN/IQFeed/iqconnect.exe"

if [ -f "$iqconnect_patched" ] || [ -f "$iqconnect_orig" ]; then
    echo "✓ IQFeed client is installed"
    
    # Wait a bit for X11 to be ready
    sleep 2
    
    # Launch using Python script with credentials from environment
    echo "Launching IQFeed client..."
    exec python3 /root/launch_iqfeed.py
else
    echo "✗ ERROR: IQFeed client not found!"
    echo "Expected locations:"
    echo "  - $iqconnect_patched"
    echo "  - $iqconnect_orig"
    echo ""
    echo "The Docker build should have installed IQFeed."
    echo "Please rebuild the image."
    exit 1
fi
