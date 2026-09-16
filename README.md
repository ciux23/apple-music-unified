# Apple Music Unified (ARM64)

Container Docker **ARM64 nativo** che scarica musica da Apple Music in **ALAC / Hi-Res Lossless / Dolby Atmos / AAC** tramite una **interfaccia web** accessibile dal browser.

## Caratteristiche

- 🍎 **Apple Music download** in ALAC, Hi-Res 24/192, Atmos, AAC
- 🌐 **Web UI** integrata (porta 8080): incolla URL, scegli qualità, guarda il progresso in tempo reale
- 🎯 **Supporto artisti**: risolve la discografia e permette di selezionare quali album scaricare
- 💾 **Organizzazione automatica**: `Artista/Album/NN. Titolo.m4a` con copertina incorporata e tag completi
- ⚡ **ARM64 nativo**: nessuna emulazione QEMU (Raspberry Pi 4/5, Apple Silicon, server ARM)
- 📦 **Single container**: wrapper + downloader + web UI in un'unica immagine
- 🔐 **Credenziali a runtime**: nessun token o password nell'immagine, tutto via variabili d'ambiente
- 🐳 **Deploy con un compose**: pronto per Portainer, OMV, qualsiasi host Docker

## Stack tecnico

- **Wrapper**: `WorldObservationLog/wrapper` compilato da sorgente per ARM64
- **Downloader**: [apmyx](https://github.com/rwnk-12/apmyx-gui) (Go, backend ARM64 nativo)
- **Web UI**: Flask + JavaScript
- **Post-processing**: FFmpeg + MP4Box (GPAC via Homebrew)

## Utilizzo rapido

```yaml
services:
  apple-music:
    image: ghcr.io/ciux23/apple-music-unified:arm64
    privileged: true
    security_opt:
      - seccomp:unconfined
      - apparmor:unconfined
    environment:
      - MEDIA_USER_TOKEN=il_tuo_token
      - PUID=1000
      - PGID=1000
    ports:
      - "8080:8080"
    volumes:
      - ./wrapper-data:/app/rootfs/data
      - /percorso/musica:/downloads
