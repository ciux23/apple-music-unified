# Apple Music Unified (ARM64)

Container Docker **ARM64 nativo** che scarica musica da Apple Music in **ALAC / Hi-Res Lossless / Dolby Atmos / AAC** tramite una **interfaccia web**.

Nessuna emulazione QEMU. Nessun wrapper x86. Tutto gira nativo su ARM64 (Raspberry Pi 4/5, Apple Silicon, server ARM, OMV).

---

## Caratteristiche

- 🍎 **Download Apple Music** in ALAC, Hi-Res 24/192, Dolby Atmos, AAC
- 🌐 **Web UI integrata** (porta 8080): incolla URL, scegli qualità, guarda il progresso in tempo reale
- 🎯 **Supporto artisti**: risolve la discografia e permette di selezionare quali album scaricare
- 💾 **Organizzazione automatica**: `Artista/Album/NN. Titolo.m4a` con copertina e tag completi
- ⚡ **ARM64 nativo**: compilato da sorgente per aarch64, nessuna emulazione
- 📦 **Single container**: wrapper + downloader + web UI in un'unica immagine
- 🔐 **Setup guidato da browser**: al primo avvio un wizard chiede email, password, 2FA e token
- 💿 **Persistenza dei token**: dopo il primo login, i riavvii non richiedono più credenziali
- 🐳 **Deploy con un compose**: pronto per Portainer, OMV, qualsiasi host Docker

---

## Stack tecnico

| Componente | Descrizione |
|------------|-------------|
| **Wrapper** | WorldObservationLog/wrapper compilato da sorgente per ARM64 |
| **Downloader** | apmyx (Go, backend ARM64 nativo) |
| **Web UI** | Flask + JavaScript |
| **Post-processing** | FFmpeg + MP4Box (GPAC via Homebrew) |
| **Build** | GitHub Actions su runner ARM64 nativo |

---

## Requisiti

- Docker con supporto ARM64 (Docker 20+, kernel Linux aarch64)
- Host ARM64 (Raspberry Pi 4/5, Apple Silicon, VPS ARM, server ARM)
- Abbonamento Apple Music attivo
- Almeno 3 GB di spazio per l'immagine

---

## Deploy

### docker-compose.yml

```yaml
services:
  apple-music:
    image: ghcr.io/ciux23/apple-music-unified:arm64
    container_name: apple-music
    restart: unless-stopped

    privileged: true
    security_opt:
      - seccomp:unconfined
      - apparmor:unconfined

    ports:
      - "8080:8080"

    environment:
      - PUID=1000
      - PGID=1000

    volumes:
      - ./wrapper-data:/app/rootfs/data
      - /percorso/musica:/downloads

### Avvio

```bash
docker compose up -d
```

Poi apri `http://IP_DEL_SERVER:8080` nel browser.

---

## Primo avvio — Setup Wizard

Al primo avvio il container mostra un **wizard nel browser** in tre step:

### Step 1 — Email e password Apple ID

Inserisci le credenziali del tuo account Apple Music. Vengono usate **solo** per il login iniziale e non vengono salvate.

### Step 2 — Codice 2FA

Apple invia un codice a 6 cifre sui tuoi dispositivi. Inseriscilo nel campo che appare nel wizard. **Hai 90 secondi** per farlo.

### Step 3 — Token apmyx (media-user-token)

Incolla il tuo `media-user-token`, che trovi nei cookie di Apple Music:

1. Apri music.apple.com nel browser (già loggato)
2. Apri DevTools (F12 o Cmd+Opt+I)
3. Vai su **Application → Cookies → music.apple.com**
4. Cerca il cookie `media-user-token`
5. Copia il valore (inizia con `0.Ajsn7...`) e incollalo nel wizard

Al termine, il container parte in modalità servizio e i token vengono salvati in `wrapper-data/`. Ai riavvii successivi **non verranno più chieste le credenziali**.


---

## Uso

Nella Web UI puoi:

- **Incollare un URL Apple Music** (brano, album, playlist o artista)
- **Scegliere la qualità**: Lossless, Hi-Res 24/192, AAC 256k, Dolby Atmos
- **Per gli artisti**: selezionare dalla lista quali album scaricare
- **Vedere il progresso** in tempo reale con barra e log completo

I file vengono salvati in `/downloads/ALAC/Artista/Album/NN. Titolo.m4a` con copertina incorporata, tag ID3 completi e permessi `1000:1000` (o i valori `PUID`/`PGID` configurati).

---

## Aggiornamenti

L'immagine viene **buildata automaticamente** ad ogni push su `main` tramite GitHub Actions. Con watchtower attivo sull'host:

```yaml
services:
  watchtower:
    image: nickfedor/watchtower:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=86400
```

Oppure aggiornamento manuale:

```bash
docker compose pull && docker compose up -d
```

---

## Note legali e disclaimer

Questo progetto scarica contenuti protetti da DRM. Funziona **solo** con un abbonamento Apple Music attivo e per **uso personale**.

**Scopo didattico.** Il codice è fornito esclusivamente a scopo educativo e di studio, per comprendere il funzionamento dei sistemi DRM, dei wrapper di decrittografia e delle architetture Docker multi-stage. Non è inteso come strumento per la pirateria o la distribuzione illecita di contenuti.

**Nessuna responsabilità.** L'autore non si assume alcuna responsabilità per:

- Uso improprio, illegale o non autorizzato del software
- Violazioni di termini di servizio, copyright o leggi locali da parte degli utenti
- Danni diretti o indiretti derivanti dall'utilizzo del codice
- Eventuali conseguenze sul proprio account Apple Music

**Responsabilità dell'utente.** Chi utilizza questo progetto è l'unico responsabile del rispetto delle leggi vigenti nel proprio paese, dei termini di servizio di Apple e dei diritti d'autore. Se non sei sicuro della legalità del suo utilizzo nella tua giurisdizione, **non usarlo**.

**Nessuna ridistribuzione.** I contenuti scaricati **non devono** essere condivisi, ridistribuiti, venduti o pubblicati in alcuna forma. Questo software è pensato per uso strettamente privato.

**Nessuna affiliazione.** Questo progetto non è affiliato, approvato o sponsorizzato da Apple Inc., da WorldObservationLog, da itouakirai o da rwnk-12. Tutti i marchi citati appartengono ai rispettivi proprietari.

**Licenza MIT.** Il codice è rilasciato sotto licenza MIT. Vedi il file LICENSE per i dettagli.

---

## Crediti

- WorldObservationLog/wrapper — wrapper FPS per la decrittografia
- itouakirai/wrapper — fork con adattamenti ARM64
- rwnk-12/apmyx-gui — downloader apmyx
- glomatico/gamdl — ispirazione per la struttura di configurazione
