# Force amd64 platform for Wine compatibility
FROM --platform=linux/amd64 ubuntu:22.04

WORKDIR /root/
ENV HOME /root
ENV DEBIAN_FRONTEND noninteractive
ENV LC_ALL C.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8
ENV WINEPREFIX /root/.wine
ENV DISPLAY :0
ENV IQFEED_INSTALLER="iqfeed_client_6_2_0_25.exe"
ENV IQFEED_LOG_LEVEL 0xB222
ENV WINEDEBUG -all

# Install basic dependencies including Python and bbe for binary patching
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git curl wget ca-certificates gnupg2 software-properties-common \
        x11vnc xvfb xdotool supervisor fluxbox \
        net-tools cabextract unzip p7zip-full zenity bbe netcat-openbsd \
        python3 python3-pip \
        nodejs npm && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Add i386 architecture and install Wine from Ubuntu repos
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends wine wine32 wine64 winbind winetricks && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Download IQFeed installer
RUN wget -nv http://www.iqfeed.net/$IQFEED_INSTALLER -O /root/$IQFEED_INSTALLER || \
    wget -nv http://www.iqfeed.net/iqfeed_client_6_2_0_25.exe -O /root/$IQFEED_INSTALLER

# Install IQFeed silently during build (not at runtime)
RUN xvfb-run -s "-noreset" -a wine64 /root/$IQFEED_INSTALLER /S && wineserver --wait

# Set IQFeed log level via registry
RUN wine64 reg add "HKEY_CURRENT_USER\\Software\\DTN\\IQFeed\\Startup" /t REG_DWORD /v LogLevel /d $IQFEED_LOG_LEVEL /f && wineserver --wait

# Patch IQFeed to listen on all interfaces (0.0.0.0 instead of 127.0.0.1)
RUN bbe -e 's/127.0.0.1/000.0.0.0/g' "/root/.wine/drive_c/Program Files/DTN/IQFeed/iqconnect.exe" > "/root/.wine/drive_c/Program Files/DTN/IQFeed/iqconnect_patched.exe" || \
    echo "Binary patching failed, will use original iqconnect.exe"

# Add Python helper scripts
ADD launch_iqfeed.py /root/launch_iqfeed.py
ADD is_iqfeed_running.py /root/is_iqfeed_running.py
RUN chmod +x /root/launch_iqfeed.py /root/is_iqfeed_running.py

# Add startup script and proxy
ADD iqfeed_startup.sh /root/iqfeed_startup.sh
RUN chmod +x /root/iqfeed_startup.sh
ADD app /root/app

# Add supervisor configuration
ADD supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create IQFeed data directory
RUN mkdir -p /root/DTN/IQFeed

# Expose Ports
EXPOSE 5010 9101 9301 5900
EXPOSE 9100 9300

CMD ["/usr/bin/supervisord"]
