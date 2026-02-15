# Steps to Run IQFeed Docker

## What's Different Now?

**Before:** You had to open VNC and manually click through the IQFeed installer.

**Now:** IQFeed installs automatically during the Docker build! Just build → run → use qdownload. VNC is optional.

---

## Step 1: Build the image

```bash
docker build --platform=linux/amd64 -t my-iqfeed:latest .
```

Wait 10-15 minutes for the build to complete.

**Important:** IQFeed installs automatically during this build step (no manual installation needed!).

## Step 2: Stop any old containers

```bash
docker stop iqfeed-modern
docker rm iqfeed-modern
```

## Step 3: Run the container

```bash
docker run -d \
  --name iqfeed-modern \
  --platform=linux/amd64 \
  -e LOGIN=####### \
  -e PASSWORD=###### \
  -p 5900:5900 \
  -p 9100:9101 \
  -p 9300:9301 \
  my-iqfeed:latest
```

## Step 4: Check the logs

```bash
docker logs -f iqfeed-modern
```

Press Ctrl+C to stop watching logs.

## Step 5: Check if IQFeed is working

```bash
docker exec iqfeed-modern python3 /root/is_iqfeed_running.py
```

Should show:
- Wine process running: True
- Admin port (9300) open: True
- Level1 port (9100) open: True

**Note:** IQFeed starts automatically when the container runs. No need to open VNC or manually start anything!

## Step 6: Test data collection

Make sure qdownload is installed:

```bash
export PATH=$PATH:$HOME/go/bin
which qdownload
```

If not found, install it:

```bash
go install github.com/nhedlund/qdownload@latest
```

Download test data:

```bash
mkdir -p data/test
qdownload -s 20251201 -e 20251210 -o data/test eod SPY,AAPL,MSFT
```

Check the data:

```bash
ls -la data/test/
cat data/test/SPY.csv
```

## Optional: Connect via VNC (for troubleshooting only)

VNC is **not required** for normal operation. IQFeed is already installed and running.

Use VNC only if you want to:
- See the IQFeed GUI
- Troubleshoot issues
- Check Wine desktop

Open VNC Viewer app and connect to:

```
localhost:5900
```

Or from terminal:

```bash
open vnc://localhost:5900
```

Use RealVNC Viewer (not macOS Screen Sharing) if you get password prompts.

## Useful Commands

Restart container:
```bash
docker restart iqfeed-modern
```

Stop container:
```bash
docker stop iqfeed-modern
```

View logs:
```bash
docker logs iqfeed-modern
```

Check if container is running:
```bash
docker ps | grep iqfeed
```

Get into container shell:
```bash
docker exec -it iqfeed-modern bash
```
