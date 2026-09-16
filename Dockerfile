# =============================================================================
# STAGE 1: Compila il launcher wrapper (C, nativo Linux ARM64)
# =============================================================================
FROM debian:trixie-slim AS launcher-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        file \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY wrapper-src/wrapper.c wrapper-src/cmdline.c wrapper-src/cmdline.h ./
RUN gcc -O3 -Wall -s -o wrapper wrapper.c cmdline.c && file wrapper

# =============================================================================
# STAGE 2: Compila il backend apmyx (Go, nativo ARM64)
# =============================================================================
FROM golang:1.26-trixie AS apmyx-builder
RUN git clone --depth 1 https://github.com/rwnk-12/apmyx-gui.git /src
WORKDIR /src/backend
RUN go build -o /out/apmyx .

# =============================================================================
# STAGE 3: Immagine finale unificata ARM64
# =============================================================================
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        python3 \
        python3-pip \
        supervisor \
        curl \
        ca-certificates \
        procps \
        git \
        sudo \
        file \
    && rm -rf /var/lib/apt/lists/*

# Homebrew + MP4Box ARM64 nativo
RUN useradd -m -s /bin/bash linuxbrew && \
    echo 'linuxbrew ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers && \
    su - linuxbrew -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' && \
    su - linuxbrew -c '/home/linuxbrew/.linuxbrew/bin/brew install gpac'
RUN ln -s /home/linuxbrew/.linuxbrew/bin/MP4Box /usr/local/bin/MP4Box

# Launcher wrapper compilato in Stage 1
COPY --from=launcher-builder /build/wrapper /app/wrapper
RUN chmod +x /app/wrapper

# Rootfs ARM64 precompilato (main + linker64 + librerie Apple Music)
COPY rootfs /app/rootfs

# apmyx Go backend compilato in Stage 2
COPY --from=apmyx-builder /out/apmyx /app/apmyx
RUN chmod +x /app/apmyx

# Config apmyx
COPY apmyx-config.yaml /app/apmyx-config.yaml

# Web UI Flask
RUN pip3 install --no-cache-dir --break-system-packages flask
COPY webui/ /app/webui/

# Supervisor

# Entrypoint wrapper
COPY entrypoint-wrapper.sh /app/entrypoint-wrapper.sh
RUN chmod +x /app/entrypoint-wrapper.sh

VOLUME ["/downloads", "/app/rootfs/data"]
ENV PUID=1000
ENV PGID=1000
EXPOSE 8080

CMD ["/app/entrypoint-wrapper.sh"]
