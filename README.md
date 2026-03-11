# IQFeed Docker - Market Data Collection

A Docker-based solution for running IQFeed (DTN market data feed) on Linux/macOS and downloading historical market data.

## Features

- ✅ Run IQFeed Windows client in Docker via Wine
- ✅ Automated installation and authentication
- ✅ Keepalive mechanism to prevent idle timeouts
- ✅ Auto-restart on crashes (important for ARM Macs)
- ✅ Download EOD, minute, and tick data with `qdownload`
- ✅ VNC access for troubleshooting

## Prerequisites

- Docker Desktop (for Mac/Windows) or Docker Engine (for Linux)
- IQFeed account with valid credentials
- Go 1.18+ (for `qdownload` tool)
- VNC Viewer (for installation - RealVNC recommended)

## Quick Start

### 1. Clone and Setup

```bash
git clone <your-repo-url>
cd iqfeed-docker

# Create .env file with your credentials
cp .env.example .env
# Edit .env and add your IQFeed credentials
```

### 2. Install qdownload Tool

```bash
go install github.com/nhedlund/qdownload@latest

# Add Go bin to PATH (if not already)
export PATH=$PATH:$HOME/go/bin

# Or add to ~/.zshrc or ~/.bashrc permanently:
echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.zshrc
```

### 3. Build Docker Image

```bash
docker build --platform=linux/amd64 -t my-iqfeed:latest .
```

**Note**: Build takes 5-10 minutes. Use `--platform=linux/amd64` even on ARM Macs.

### 4. Run Container and Download Data

```bash
# Option A: Automated script (recommended)
./start_and_download.sh

# Option B: Manual control
docker run -d --name iqfeed-modern --platform=linux/amd64 \
  -e LOGIN=<your_login> \
  -e PASSWORD=<your_password> \
  -e PRODUCT_ID=<your_product_id> \
  -p 5900:5900 -p 5009:5010 -p 9100:9101 -p 9300:9301 \
  my-iqfeed:latest
```

### 5. Complete IQFeed Installation (First Time Only)

On the **first container startup**, you need to complete the IQFeed installation:

```bash
# Connect to VNC
open -a "VNC Viewer" --args localhost:5900
# Or: vncviewer localhost:5900
```

In the VNC window:
1. Click through the IQFeed installer (Next → Accept → Install)
2. Click "OK" on any "Internal error" dialogs (normal with Wine)
3. Click "Finish" when installation completes
4. The client will automatically start with your credentials

**After installation**, the container will remember IQFeed and auto-start it on future runs.

### 6. Download Market Data

```bash
# EOD (daily) bars
qdownload -s 20251201 -e 20251210 -o data/eod eod SPY,AAPL,MSFT

# Minute bars
qdownload -s 20251209 -e 20251210 -o data/minute minute SPY

# Tick data (intraday)
qdownload -s 20251210 -e 20251210 -o data/tick -z America/New_York tick SPY
```

Data will be saved in the `data/` directory as CSV files.

## Configuration

### Environment Variables (.env)

Create a `.env` file with your IQFeed credentials:

```bash
IQFEED_LOGIN=your_login_id
IQFEED_PASSWORD=your_password
IQFEED_PRODUCT_ID=YOUR_PRODUCT_ID
```

### Port Mappings

| Container Port | Host Port | Service |
|---------------|-----------|---------|
| 5900 | 5900 | VNC Server |
| 5010 | 5009 | IQFeed Level 1 |
| 9101 | 9100 | IQFeed Lookup |
| 9301 | 9300 | IQFeed Admin |

## Usage Examples

### Basic EOD Download

```bash
qdownload -s 20251201 -e 20251210 -o data/eod eod SPY,AAPL,MSFT,GOOG
```

### Multiple Symbols from File

```bash
# Create symbols.txt with one symbol per line
echo -e "SPY\nAAPL\nMSFT\nGOOG\nAMZN" > symbols.txt

qdownload -s 20251201 -e 20251210 -o data/eod eod symbols.txt
```

### Intraday Minute Bars

```bash
qdownload -s 20251209 -e 20251210 -o data/minute minute SPY
```

### Tick Data with Timezone

```bash
qdownload -s 20251210 -e 20251210 -o data/tick -z America/New_York tick SPY
```

## Troubleshooting

### Container stops immediately / 0 rows downloaded

**Problem**: IQFeed not installed yet, or crashed  
**Solution**: Connect via VNC and complete installation (first time), or check logs:

```bash
docker logs iqfeed-modern --tail 50
```

### "connection reset by peer" errors

**Problem**: IQFeed client crashed or not running  
**Solution**: 

```bash
# Check if IQFeed is running
docker exec iqfeed-modern ps aux | grep iqconnect

# Check if ports are listening
docker exec iqfeed-modern netstat -tlnp | grep -E '9100|9300'

# Restart container if needed
docker stop iqfeed-modern && docker rm iqfeed-modern
./start_and_download.sh
```

### Authentication errors

**Problem**: Wrong credentials or product ID  
**Solution**: Verify `.env` file has correct `IQFEED_LOGIN`, `IQFEED_PASSWORD`, and `IQFEED_PRODUCT_ID`

### VNC shows black screen

**Problem**: Normal - this is the Fluxbox desktop  
**Solution**: Right-click to access menu, or wait for IQFeed installer to appear automatically

### On ARM Macs (M1/M2/M3): Frequent crashes

**Problem**: Wine + x86 emulation is unstable on ARM  
**Known issue**: IQFeed may crash every 30-60 seconds  
**Workaround**: 
- The startup script automatically restarts IQFeed
- The keepalive script pings IQFeed every 15 seconds
- Download data immediately after container starts
- For production use, consider running on an x86 Linux server

## Container Management

```bash
# Stop container
docker stop iqfeed-modern

# Remove container
docker rm iqfeed-modern

# View logs
docker logs iqfeed-modern -f

# Access container shell
docker exec -it iqfeed-modern bash

# Restart services inside container
docker exec iqfeed-modern supervisorctl restart all
```

## GCP Data Ingestion

For production deployment on Google Cloud Platform with GCS storage, see:

- **[docs/INGESTION_GUIDE.md](docs/INGESTION_GUIDE.md)** — Full technical guide covering:
  - Container startup with gcsfuse
  - `vm_batch_ingest.sh` for automated batch downloads
  - GCS bucket structure and manual downloads
  - Troubleshooting and known issues

## Project Structure

```
.
├── Dockerfile              # Docker image definition
├── supervisord.conf        # Process manager config
├── iqfeed_startup.sh       # IQFeed launcher (auto-restart)
├── iqfeed_keepalive.sh     # Keepalive pings (prevents timeout)
├── start_and_download.sh   # Local automation script
├── ingest.sh               # EOD ingestion to GCS
├── vm_batch_ingest.sh      # GCP VM batch download script
├── docs/
│   └── INGESTION_GUIDE.md  # GCP ingestion operations manual
├── app/
│   ├── proxy.js            # IQFeed connection proxy
│   └── iqfeed.conf         # IQFeed configuration
└── data/                   # Downloaded market data (not in git)
```

## Credits

Based on:
- [bratchenko/docker-iqfeed](https://github.com/bratchenko/docker-iqfeed)
- [jaikumarm/docker-iqfeed](https://github.com/jaikumarm/docker-iqfeed)
- [nhedlund/qdownload](https://github.com/nhedlund/qdownload)

## License

MIT License - See LICENSE file for details

## Support

For IQFeed account issues, contact [DTN Support](https://www.iqfeed.net/support.cfm)

For issues with this Docker setup, please open a GitHub issue.
