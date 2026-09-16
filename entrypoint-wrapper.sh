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
  python3 - <<PYEOF
import re
with open("/app/apmyx-config.yaml", "r") as f:
    content = f.read()
content = re.sub(r'^media-user-token:.*$', 'media-user-token: "${MEDIA_USER_TOKEN}"', content, flags=re.MULTILINE)
with open("/app/apmyx-config.yaml", "w") as f:
    f.write(content)
PYEOF
fi

ln -sf /app/apmyx-config.yaml /app/config.yaml

TOKEN_DB_PATH="/app/rootfs/data/data/com.apple.android.music/files/mpl_db/kvs.sqlitedb"
LOGIN_REQ="/app/.login-request"
LOGIN_STATUS="/app/.login-status"

mkdir -p "/app/rootfs/data/data/com.apple.android.music/files"

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

# -----------------------------------------------------------------------------
# Modalità servizio: se il DB dei token esiste, avvia subito il wrapper
# -----------------------------------------------------------------------------
if [ -f "$TOKEN_DB_PATH" ]; then
  echo "[entrypoint] Token trovati, avvio wrapper in modalità servizio..."
  echo "ok" > "$LOGIN_STATUS"
  exec ./wrapper -H 0.0.0.0 -M 20020 "$@"
fi

# -----------------------------------------------------------------------------
# Modalità setup: aspetta che la web UI fornisca email/password via file
# -----------------------------------------------------------------------------
echo "[entrypoint] Nessun token. In attesa di credenziali dalla web UI..."
echo "waiting" > "$LOGIN_STATUS"
rm -f "$LOGIN_REQ"

# Loop: aspetta il file di richiesta di login
while [ ! -f "$LOGIN_REQ" ]; do
  sleep 2
done

# Legge email e password
CREDS=$(cat "$LOGIN_REQ")
EMAIL=$(echo "$CREDS" | cut -d: -f1)
PASS=$(echo "$CREDS" | cut -d: -f2-)
rm -f "$LOGIN_REQ"

echo "[entrypoint] Credenziali ricevute, avvio login..."
echo "2fa" > "$LOGIN_STATUS"

# Pulisce eventuali 2FA vecchi
rm -f /app/rootfs/data/2fa.txt

# Avvia il wrapper in modalità login (bloccante, esce quando finisce)
./wrapper -L "${EMAIL}:${PASS}" -F -H 0.0.0.0 -M 20020 || true

if [ -f "$TOKEN_DB_PATH" ]; then
  echo "[entrypoint] Login riuscito, avvio wrapper in modalità servizio..."
  echo "ok" > "$LOGIN_STATUS"
  exec ./wrapper -H 0.0.0.0 -M 20020 "$@"
else
  echo "[entrypoint] Login fallito."
  echo "error: login fallito" > "$LOGIN_STATUS"
  exit 1
fi
