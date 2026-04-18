#!/bin/sh
set -e

. /app/lib.sh

# Create runtime directory
mkdir -p /var/run/forager

# Initialize state file if missing or empty
if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
  echo '{}' > "$STATE_FILE"
fi
init_state

# Clean up stale lock
rm -rf "$LOCK_DIR"

# Auth mode: session-based (HTML login) when FORAGER_USER/PASS set, none otherwise
if [ -n "$FORAGER_USER" ] && [ -n "$FORAGER_PASS" ]; then
  echo "[forager] Session auth enabled (user: $FORAGER_USER)"
else
  echo "[forager] No auth configured (set FORAGER_USER and FORAGER_PASS to enable)"
fi

# Save env vars for CGI scripts (lighttpd CGI runs in a clean environment)
env | grep -E '^(FORAGER_|MAM_BASE|TZ|BROWSER_URL|NOTIFY_URL)=' | sed 's/^/export /' > /var/run/forager/env.sh

LISTEN_PORT="${FORAGER_PORT:-5011}"

cat > /var/run/forager/lighttpd.conf <<CONF
server.document-root = "/www"
server.port = ${LISTEN_PORT}
server.modules = ("mod_cgi", "mod_rewrite")

cgi.assign = (".cgi" => "")

url.rewrite-once = (
  "^/state\$"       => "/cgi-bin/state.cgi",
  "^/spend\$"       => "/cgi-bin/spend.cgi",
  "^/dry-spend\$"   => "/cgi-bin/dry-spend.cgi",
  "^/refresh\$"     => "/cgi-bin/refresh.cgi",
  "^/health\$"      => "/cgi-bin/health.cgi",
  "^/history\$"     => "/cgi-bin/history.cgi",
  "^/notify-test\$" => "/cgi-bin/notify-test.cgi",
  "^/login\$"       => "/cgi-bin/login.cgi",
  "^/logout\$"      => "/cgi-bin/logout.cgi"
)

mimetype.assign = (
  ".html" => "text/html",
  ".css"  => "text/css",
  ".js"   => "application/javascript",
  ".json" => "application/json",
  ".svg"  => "image/svg+xml",
  ".ico"  => "image/x-icon"
)

index-file.names = ("index.html")
CONF

echo "[forager] Starting spender..."
/app/spender.sh &
SPENDER_PID=$!

echo "[forager] Starting lighttpd on port ${LISTEN_PORT}..."
lighttpd -f /var/run/forager/lighttpd.conf -D &
HTTPD_PID=$!

# Restart children if they die
trap "kill $SPENDER_PID $HTTPD_PID 2>/dev/null; exit 0" TERM INT

while true; do
  if ! kill -0 "$HTTPD_PID" 2>/dev/null; then
    echo "[forager] lighttpd died, restarting..."
    lighttpd -f /var/run/forager/lighttpd.conf -D &
    HTTPD_PID=$!
  fi
  if ! kill -0 "$SPENDER_PID" 2>/dev/null; then
    echo "[forager] spender died, restarting..."
    /app/spender.sh &
    SPENDER_PID=$!
  fi
  sleep 5
done
