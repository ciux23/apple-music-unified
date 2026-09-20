#!/bin/sh
set -e

cd /app

PUID=${PUID:-1000}
PGID=${PGID:-1000}

LOGIN_REQ="/app/.login-request"
TOKEN_REQ="/app/.token-input"
LOGIN_STATUS="/app/.login-status"
CONFIG_APMYX="/app/apmyx-config.yaml"
WRAPPER_LOG="/tmp/wrapper.log"
LOGIN_DONE_MARKER="/app/rootfs/data/.login_done"
TOKEN_FILE="/app/rootfs/data/.media_user_token"

inject_token() {
  python3 - "$1" <<'PYEOF'
import re, sys
token = sys.argv[1]
with open("/app/apmyx-config.yaml", "r") as f:
    content = f.read()
content = re.sub(r'^media-user-token:.*$', 'media-user-token: "%s"' % token, content, flags=re.MULTILINE)
with open("/app/apmyx-config.yaml", "w") as f:
    f.write(content)
PYEOF
}

mkdir -p "/app/rootfs/data/data/com.apple.android.music/files"

# Se c'è un MEDIA_USER_TOKEN da env, salvalo nel volume (persistente)
if [ -n "${MEDIA_USER_TOKEN}" ]; then
  echo "[entrypoint] MEDIA_USER_TOKEN da env: salvo nel volume."
  echo "$MEDIA_USER_TOKEN" > "$TOKEN_FILE"
fi

# Se il token è nel volume, iniettalo nel config apmyx
if [ -f "$TOKEN_FILE" ]; then
  echo "[entrypoint] Token trovato nel volume, inietto nel config."
  inject_token "$(cat "$TOKEN_FILE")"
fi

ln -sf "$CONFIG_APMYX" /app/config.yaml

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

# Modalità servizio se login fatto E token disponibile
if [ -f "$LOGIN_DONE_MARKER" ] && [ -f "$TOKEN_FILE" ]; then
  echo "[entrypoint] Setup già completato. Avvio servizio."
  echo "ok" > "$LOGIN_STATUS"
  exec ./wrapper -H 0.0.0.0 -M 20020 "$@"
fi

# Setup
rm -f "$LOGIN_REQ" "$TOKEN_REQ" "$WRAPPER_LOG"
echo "waiting" > "$LOGIN_STATUS"

# STEP 1: email+password (solo se kvs.sqlitedb assente)
if [ ! -f "$LOGIN_DONE_MARKER" ]; then
  echo "[entrypoint] Attendo email+password..."
  while [ ! -f "$LOGIN_REQ" ]; do sleep 2; done
  CREDS=$(cat "$LOGIN_REQ")
  EMAIL=$(echo "$CREDS" | cut -d: -f1)
  PASS=$(echo "$CREDS" | cut -d: -f2-)
  rm -f "$LOGIN_REQ"
  rm -f /app/rootfs/data/2fa.txt

  echo "[entrypoint] Avvio login in background..."
  ./wrapper -L "${EMAIL}:${PASS}" -F -H 0.0.0.0 -M 20020 > "$WRAPPER_LOG" 2>&1 &
  WRAPPER_PID=$!

  for i in $(seq 1 60); do
    if grep -q "2FA: true" "$WRAPPER_LOG" 2>/dev/null; then
      echo "[entrypoint] Prompt 2FA rilevato."
      echo "2fa" > "$LOGIN_STATUS"
      break
    fi
    sleep 1
  done

  for i in $(seq 1 90); do
    if [ -f /app/rootfs/data/2fa.txt ]; then
      echo "[entrypoint] Codice 2FA ricevuto."
      break
    fi
    sleep 1
  done

  if [ ! -f /app/rootfs/data/2fa.txt ]; then
    echo "[entrypoint] Timeout 2FA."
    echo "error: timeout 2FA" > "$LOGIN_STATUS"
    kill $WRAPPER_PID 2>/dev/null || true
    exit 1
  fi

  for i in $(seq 1 90); do
    if grep -q "listening 0.0.0.0:10020" "$WRAPPER_LOG" 2>/dev/null; then
      echo "[entrypoint] Login completato."
      break
    fi
    sleep 1
  done

  if ! grep -q "listening 0.0.0.0:10020" "$WRAPPER_LOG" 2>/dev/null; then
    echo "[entrypoint] Login fallito."
    echo "error: login fallito" > "$LOGIN_STATUS"
    kill $WRAPPER_PID 2>/dev/null || true
    exit 1
  fi

  touch "$LOGIN_DONE_MARKER"
fi

# STEP 2: token apmyx (solo se manca nel volume)
if [ ! -f "$TOKEN_FILE" ]; then
  echo "token" > "$LOGIN_STATUS"
  echo "[entrypoint] Attendo token apmyx dal wizard..."
  while [ ! -f "$TOKEN_REQ" ]; do sleep 2; done
  TOKEN_VAL=$(cat "$TOKEN_REQ")
  rm -f "$TOKEN_REQ"
  if [ -n "$TOKEN_VAL" ]; then
    echo "$TOKEN_VAL" > "$TOKEN_FILE"
    inject_token "$TOKEN_VAL"
    echo "[entrypoint] Token apmyx salvato e iniettato."
  fi
fi

echo "ok" > "$LOGIN_STATUS"

# Se il wrapper di login è già in esecuzione, resta in attesa
if [ -n "${WRAPPER_PID:-}" ] && kill -0 "$WRAPPER_PID" 2>/dev/null; then
  wait $WRAPPER_PID
else
  exec ./wrapper -H 0.0.0.0 -M 20020 "$@"
fi
