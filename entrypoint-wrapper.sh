#!/bin/sh
set -e

cd /app

PUID=${PUID:-1000}
PGID=${PGID:-1000}

# -----------------------------------------------------------------------------
# Inietta MEDIA_USER_TOKEN nell'apmyx-config.yaml (se passato dall'ambiente)
# -----------------------------------------------------------------------------
if [ -n "${MEDIA_USER_TOKEN}" ]; then
  echo "[entrypoint] Inietto MEDIA_USER_TOKEN nel config apmyx..."
  if grep -q '^media-user-token:' /app/apmyx-config.yaml; then
    # sostituisce la riga esistente (gestisce anche caratteri speciali)
    python3 - <<PYEOF
import re
with open("/app/apmyx-config.yaml", "r") as f:
    content = f.read()
content = re.sub(r'^media-user-token:.*$', 'media-user-token: "${MEDIA_USER_TOKEN}"', content, flags=re.MULTILINE)
with open("/app/apmyx-config.yaml", "w") as f:
    f.write(content)
PYEOF
  else
    echo "media-user-token: \"${MEDIA_USER_TOKEN}\"" >> /app/apmyx-config.yaml
  fi
fi

# Symlink config per apmyx
ln -sf /app/apmyx-config.yaml /app/config.yaml

TOKEN_DB_PATH="/app/rootfs/data/data/com.apple.android.music/files/mpl_db/kvs.sqlitedb"

if [ ! -d "/app/rootfs/data/data/com.apple.android.music/files" ]; then
  mkdir -p "/app/rootfs/data/data/com.apple.android.music/files"
fi

# Avvia la web UI in background
echo "[entrypoint] Avvio web UI sulla porta 8080..."
python3 /app/webui/app.py > /var/log/webui.log 2>&1 &
WEBUI_PID=$!

# Chown periodico per aprire i permessi sui file appena scaricati
(
  while true; do
    chown -R ${PUID}:${PGID} /downloads /app/rootfs/data 2>/dev/null || true
    sleep 5
  done
) &
CHOWN_PID=$!

cleanup() {
  kill $WEBUI_PID $CHOWN_PID 2>/dev/null || true
  chown -R ${PUID}:${PGID} /downloads /app/rootfs/data 2>/dev/null || true
}
trap cleanup TERM INT EXIT

# Avvia il wrapper (PID 1 del container, necessario per chroot + unshare)
if [ ! -f "$TOKEN_DB_PATH" ]; then
  echo "[entrypoint] Login required: account database not found."
  if [ -z "${USERNAME}" ] || [ -z "${PASSWORD}" ]; then
    echo "[entrypoint] ERROR: USERNAME and PASSWORD must be set for the first login." >&2
    exit 1
  fi
  echo "[entrypoint] Running login (2FA code expected in /app/rootfs/data/2fa.txt)..."
  exec ./wrapper \
    -L "${USERNAME}:${PASSWORD}" \
    -F \
    -H 0.0.0.0 \
    -M 20020 \
    "$@"
fi

echo "[entrypoint] Token found, starting wrapper in service mode..."
exec ./wrapper \
  -H 0.0.0.0 \
  -M 20020 \
  "$@"
