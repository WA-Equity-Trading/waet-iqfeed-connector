# Force amd64 platform for Wine compatibility
FROM --platform=linux/amd64 ubuntu:22.04

# Set correct environment variables
ENV HOME /root
ENV DEBIAN_FRONTEND noninteractive
ENV LC_ALL C.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8
ENV DISPLAY :0
ENV WINE_MONO_VERSION 8.1.0
ENV IQFEED_INSTALLER="iqfeed_client_6_2_0_25.exe"

# Wine64 configuration (critical for ARM Mac compatibility)
ENV WINEARCH win64
ENV WINEPREFIX /root/.wine64

# Install basic dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git curl wget ca-certificates gnupg2 software-properties-common \
        x11vnc xvfb xdotool supervisor fluxbox \
        net-tools cabextract unzip p7zip-full zenity \
        python3 nodejs npm && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Add i386 architecture and install Wine from Ubuntu repos
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends wine wine32 wine64 winbind && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    # Install winetricks
    curl -SL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks -o /usr/local/bin/winetricks && \
    chmod +x /usr/local/bin/winetricks

WORKDIR /root/

# Add supervisor conf
ADD supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Download IQFeed installer
RUN wget -O /root/$IQFEED_INSTALLER http://www.iqfeed.net/$IQFEED_INSTALLER || \
    wget -O /root/$IQFEED_INSTALLER http://www.iqfeed.net/iqfeed_client_6_2_0_25.exe

# Add startup and keepalive scripts
ADD iqfeed_startup.sh /root/iqfeed_startup.sh
ADD iqfeed_keepalive.sh /root/iqfeed_keepalive.sh
RUN chmod +x /root/iqfeed_startup.sh /root/iqfeed_keepalive.sh

# Add iqfeed proxy app
ADD app /root/app

# Initialize Wine prefix with a display, fix drive mappings, and pre-install IQFeed
RUN Xvfb :1 -screen 0 1024x768x24 & \
    sleep 3 && \
    DISPLAY=:1 wineboot --init 2>&1 | head -n 10 || true && \
    sleep 3 && \
    mkdir -p /root/.wine64/dosdevices && \
    ln -sfn /root/.wine64/drive_c /root/.wine64/dosdevices/c: && \
    ln -sfn / /root/.wine64/dosdevices/z: && \
    DISPLAY=:1 wine64 /root/$IQFEED_INSTALLER /S 2>&1 | tail -n 5 || true && \
    sleep 30 && \
    kill %1 || true

# Install gcsfuse AFTER Wine init - prevent upgrading Wine dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends --no-upgrade fuse && \
    export GCSFUSE_REPO=gcsfuse-jammy && \
    echo "deb [signed-by=/usr/share/keyrings/gcsfuse-archive-keyring.gpg] https://packages.cloud.google.com/apt $GCSFUSE_REPO main" | \
    tee /etc/apt/sources.list.d/gcsfuse.list && \
    curl -sS https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
    gpg --dearmor -o /usr/share/keyrings/gcsfuse-archive-keyring.gpg && \
    apt-get update && \
    apt-get install -y --no-install-recommends --no-upgrade gcsfuse && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Go and qdownload
RUN wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz && \
    rm go1.22.0.linux-amd64.tar.gz && \
    /usr/local/go/bin/go install github.com/nhedlund/qdownload@latest

ENV PATH=$PATH:/usr/local/go/bin:/root/go/bin

# Add ingestion script
ADD ingest.sh /root/ingest.sh
RUN chmod +x /root/ingest.sh

CMD ["/usr/bin/supervisord"]

# Expose Ports
EXPOSE 5010
EXPOSE 9101
EXPOSE 9301
EXPOSE 5900
