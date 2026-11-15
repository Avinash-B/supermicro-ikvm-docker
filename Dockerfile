# Runs the legacy Supermicro/ATEN Java iKVM console inside a Linux container.
#
# The viewer ships Linux x86_64 native libraries that only work on x86_64, so
# this image is linux/amd64. On Apple Silicon run it under Docker Desktop with
# Rosetta enabled (Settings -> General -> "Use Rosetta for x86/amd64 emulation")
# for acceptable speed.
FROM --platform=linux/amd64 eclipse-temurin:8-jre

ENV DEBIAN_FRONTEND=noninteractive

# - xvfb/x11vnc/fluxbox: a headless X display exported over VNC
# - xdotool/imagemagick: let a human or an agent send keys and grab screenshots
# - libx*/libstdc++/freetype/fontconfig/fonts: what the AWT viewer + natives need
# - curl/unzip: fetch and unpack the viewer from the BMC at runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11vnc fluxbox x11-utils xdotool imagemagick \
      libx11-6 libxext6 libxrender1 libxtst6 libxi6 libxkbfile1 \
      libstdc++6 libfreetype6 fontconfig fonts-dejavu-core \
      curl ca-certificates unzip procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ikvm
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# VNC port exposed to the host
EXPOSE 5901

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
