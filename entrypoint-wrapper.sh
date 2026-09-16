#!/bin/sh
set -e

cd /app

PUID=${PUID:-1000}
PGID=${PGID:-1000}

LOGIN_REQ="/app/.login-request"
TOKEN_REQ="/app/.token-input"
LOGIN_STATUS="/app/.login-status"
TOKEN_DB_PATH="/app/rootfs/data/data/com.apple.android.music/files/mpl_db/kvs.sqlitedb"
CONFIG_APMYX="/app/apmyx-config.yaml"

inject_token() {
  local tok="$1"
  python3 - "$tok" <<'PYEOF'
import re, sys
token = sys.argv[1]
with open("/app/apmyx-config.yaml", "r") as f:
    content = f.read()
content = re.sub(r'^media-user-token:.*$', 'media-user-token: "%s"' % token, content, flags=re.MULTILINE)
with open("/app/apmyx-config.yaml", "w") as f:
    f.write(content)
PYEOF
}

# Se c'è un token passato come variabile d'ambiente, ha precedenza
if [ -n "${MEDIA_USER_TOKEN}" ]; then
  echo "[entrypoint] MEDIA_USER_TOKEN presente come env: inietto nel config."
  inject_token "$MEDIA_USER_TOKEN"
fi

ln -sf "$CONFIG_APMYX" /app/config.yaml

mkdir -p "/app/rootfs/data/data/com.apple.android.music/files"

echo "[entrypoint] Avvio web UI sulla porta 8080..."
python3 /app/webui/app.py > /var/log/webui.log 2>&1 &
WEBUI_PID=$!

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

# ---------------------------------------------------------------------------
# Modalità servizio (token già presenti + token apmyx già iniettato)
# ---------------------------------------------------------------------------
if [ -f "$TOKEN_DB_PATH" ] && grep -q '^media-user-token: "[^"]\+"' "$CONFIG_APMYX"; then
  echo "[entrypoint] Token wrapper e token apmyx presenti. Avvio servizio."
  echo "ok" > "$LOGIN_STATUS"
  exec ./wrapper -H 0.0.0.0 -M 20020 "$@"
fi

# ---------------------------------------------------------------------------
# Modalità setup
# ---------------------------------------------------------------------------
echo "[entrypoint] Setup richiesto. Attendo input dal wizard..."
rm -f "$LOGIN_REQ" "$TOKEN_REQ"

# STEP 1: se manca il kvs.sqlitedb, aspetta email+password
if [ ! -f "$TOKEN_DB_PATH" ]; then
  echo "waiting" > "$LOGIN_STATUS"
  echo "[entrypoint] Attendo email+password..."
  while [ ! -f "$LOGIN_REQ" ]; do sleep 2; done

  CREDS=$(cat "$LOGIN_REQ")
  EMAIL=$(echo "$CREDS" | cut -d: -f1)
  PASS=$(echo "$CREDS" | cut -d: -f2-)
  rm -f "$LOGIN_REQ"

  echo "[entrypoint] Credenziali ricevute, avvio login in background..."
  echo "2fa" > "$LOGIN_STATUS"
  rm -f /app/rootfs/data/2fa.txt

  ./wrapper -L "${EMAIL}:${PASS}" -F -H 0.0.0.0 -M 20020 &
  WRAPPER_PID=$!

  for i in $(seq 1 60); do
    if [ -f "$TOKEN_DB_PATH" ]; then
      echo "[entrypoint] Login completato."
      break
    fi
    sleep 2
  done

  if [ ! -f "$TOKEN_DB_PATH" ]; then
    echo "[entrypoint] Login fallito (timeout)."
    echo "error: login fallito" > "$LOGIN_STATUS"
    kill $WRAPPER_PID 2>/dev/null || true
    exit 1
  fi
fi

# STEP 2: chiedi il token se manca nel config apmyx
if ! grep -q '^media-user-token: "[^"]\+"' "$CONFIG_APMYX"; then
  echo "[entrypoint] In attesa del token apmyx dal wizard..."
  echo "token" > "$LOGIN_STATUS"
  while [ ! -f "$TOKEN_REQ" ]; do sleep 2; done
  TOKEN_VAL=$(cat "$TOKEN_REQ")
  rm -f "$TOKEN_REQ"
  if [ -n "$TOKEN_VAL" ]; then
    inject_token "$TOKEN_VAL"
    echo "[entrypoint] Token apmyx iniettato."
  fi
fi

echo "ok" > "$LOGIN_STATUS"

# Se il wrapper di login è già in esecuzione, aspetta che termini (resta in listening)
if [ -n "${WRAPPER_PID:-}" ] && kill -0 "$WRAPPER_PID" 2>/dev/null; then
  wait $WRAPPER_PID
else
  # Altrimenti avvia il wrapper in servizio
  exec ./wrapper -H 0.0.0.0 -M 20020 "$@"
fi
