#!/bin/sh
# Test suite for forager

export FORAGER_STATE_DIR="/tmp/forager-test"
export TZ="America/Los_Angeles"

mkdir -p "$FORAGER_STATE_DIR" /var/run/forager

. /app/lib.sh

# --- Helpers ---

reset_state() {
  echo '{}' > "$STATE_FILE"
  rm -f "$COOKIE_JAR" "$MBSC_FILE" "${MBSC_FILE}.new"
  init_state
}

# --- Unit Tests ---

test_timestamp_format() {
  local ts
  ts=$(timestamp)
  echo "timestamp: $ts"
  # Should match ISO 8601 with timezone suffix
  echo "$ts" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}\[' \
    || fail "timestamp format invalid: $ts"
  echo "$ts" | grep -q '\[America/Los_Angeles\]' \
    || fail "timestamp missing TZ suffix: $ts"
}

test_state_roundtrip() {
  reset_state
  local state
  state=$(read_state)
  # Should have default settings
  local buffer
  buffer=$(echo "$state" | jq -r '.settings.pointsBuffer')
  assertEquals "10000" "$buffer"
  local auto_vip
  auto_vip=$(echo "$state" | jq -r '.settings.autoVip')
  assertEquals "true" "$auto_vip"
}

test_lock_acquire_release() {
  rm -rf "$LOCK_DIR"
  acquire_lock
  assertTrue "Lock dir should exist" "[ -d '$LOCK_DIR' ]"
  release_lock
  assertFalse "Lock dir should not exist" "[ -d '$LOCK_DIR' ]"
}

test_init_state_defaults() {
  echo '{}' > "$STATE_FILE"
  init_state
  local state
  state=$(read_state)
  assertEquals "10000" "$(echo "$state" | jq -r '.settings.pointsBuffer')"
  assertEquals "true" "$(echo "$state" | jq -r '.settings.autoVip')"
  assertEquals "off" "$(echo "$state" | jq -r '.settings.vaultMode')"
  assertEquals "24" "$(echo "$state" | jq -r '.settings.spendIntervalHours')"
  assertEquals "off" "$(echo "$state" | jq -r '.settings.wedgeMode')"
  assertEquals "50" "$(echo "$state" | jq -r '.settings.minSpendGb')"
  assertEquals "false" "$(echo "$state" | jq -r '.paused')"
  assertEquals "null" "$(echo "$state" | jq -r '.browserSession.mbsc')"
  assertEquals "null" "$(echo "$state" | jq -r '.browserSession.userAgent')"
  assertEquals "0" "$(echo "$state" | jq -r '.lifetime.totalGbPurchased')"
  assertEquals "0" "$(echo "$state" | jq -r '.lifetime.totalPointsSpent')"
}

test_init_state_preserves_existing() {
  echo '{"currentCookie":"abc123","settings":{"pointsBuffer":5000,"autoVip":false,"vaultMode":"daily","spendIntervalHours":12}}' > "$STATE_FILE"
  init_state
  local state
  state=$(read_state)
  assertEquals "abc123" "$(echo "$state" | jq -r '.currentCookie')"
  assertEquals "5000" "$(echo "$state" | jq -r '.settings.pointsBuffer')"
  assertEquals "false" "$(echo "$state" | jq -r '.settings.autoVip')"
  assertEquals "daily" "$(echo "$state" | jq -r '.settings.vaultMode')"
}

test_append_points_history() {
  reset_state
  local state
  state=$(read_state)
  state=$(append_points_history "$state" 1000)
  state=$(append_points_history "$state" 2000)
  local count
  count=$(echo "$state" | jq '.pointsHistory | length')
  assertEquals "2" "$count"
}

test_points_history_max() {
  reset_state
  local state
  state=$(read_state)
  local i=0
  while [ "$i" -lt 55 ]; do
    state=$(append_points_history "$state" "$((i * 100))")
    i=$((i + 1))
  done
  local count
  count=$(echo "$state" | jq '.pointsHistory | length')
  assertEquals "$MAX_POINTS_HISTORY" "$count"
}

test_empty_state_file() {
  # Empty file should be treated as {}
  printf '' > "$STATE_FILE"
  local state
  state=$(read_state)
  assertEquals "{}" "$state"

  # init_state should work on empty file
  printf '' > "$STATE_FILE"
  init_state
  state=$(read_state)
  assertEquals "10000" "$(echo "$state" | jq -r '.settings.pointsBuffer')"
}

test_get_cookie_empty() {
  reset_state
  local cookie
  cookie=$(get_cookie)
  assertEquals "" "$cookie"
}

test_get_cookie_set() {
  reset_state
  acquire_lock
  local state
  state=$(read_state)
  echo "$state" | jq '.currentCookie = "test_cookie_123"' | write_state
  release_lock
  local cookie
  cookie=$(get_cookie)
  assertEquals "test_cookie_123" "$cookie"
}

# --- Integration Tests (HTTP) ---

MOCK_PORT=9999
TEST_PORT=5019

setup_mock_server() {
  mkdir -p /tmp/mock-www/cgi-bin

  # Mock profile endpoint
  cat > /tmp/mock-www/cgi-bin/profile.cgi <<'MOCKEOF'
#!/bin/sh
printf "Content-Type: application/json\r\n\r\n"
cat /tmp/mock-data/profile.json
MOCKEOF

  # Mock buy endpoint
  cat > /tmp/mock-www/cgi-bin/buy.cgi <<'MOCKEOF'
#!/bin/sh
printf "Content-Type: application/json\r\n\r\n"
echo '{"Success":true}'
MOCKEOF

  chmod +x /tmp/mock-www/cgi-bin/*.cgi

  mkdir -p /tmp/mock-data
  cat > /tmp/mock-data/profile.json <<'DATAEOF'
{
  "username": "testuser",
  "uid": 12345,
  "seedbonus": 50000,
  "uploaded": "1.00 GiB",
  "uploaded_bytes": 1073741824,
  "downloaded": "512.00 MiB",
  "downloaded_bytes": 536870912,
  "ratio": 2.0,
  "vip_until": "2026-06-15 00:00:00"
}
DATAEOF

  cat > /tmp/mock-lighttpd.conf <<CONF
server.document-root = "/tmp/mock-www"
server.port = $MOCK_PORT
server.modules = ("mod_cgi", "mod_rewrite")
cgi.assign = (".cgi" => "")
url.rewrite-once = (
  "^/jsonLoad.php.*" => "/cgi-bin/profile.cgi",
  "^/json/bonusBuy.php.*" => "/cgi-bin/buy.cgi"
)
CONF

  lighttpd -f /tmp/mock-lighttpd.conf -D &
  MOCK_PID=$!
  sleep 0.5
}

teardown_mock_server() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  [ -n "$TEST_PID" ] && kill "$TEST_PID" 2>/dev/null
  rm -rf /tmp/mock-www /tmp/mock-data /tmp/mock-lighttpd.conf
  rm -f "$COOKIE_JAR" "$MBSC_FILE" "${MBSC_FILE}.new"
}

setup_test_server() {
  cat > /tmp/test-lighttpd.conf <<CONF
server.document-root = "/www"
server.port = $TEST_PORT
server.modules = ("mod_cgi", "mod_rewrite", "mod_setenv")
cgi.assign = (".cgi" => "")
url.rewrite-once = (
  "^/state\$"   => "/cgi-bin/state.cgi",
  "^/spend\$"      => "/cgi-bin/spend.cgi",
  "^/dry-spend\$" => "/cgi-bin/dry-spend.cgi",
  "^/refresh\$"   => "/cgi-bin/refresh.cgi",
  "^/health\$"  => "/cgi-bin/health.cgi",
  "^/history\$" => "/cgi-bin/history.cgi"
)
setenv.add-environment = (
  "MAM_BASE" => "http://127.0.0.1:${MOCK_PORT}",
  "FORAGER_STATE_DIR" => "${FORAGER_STATE_DIR}",
  "TZ" => "America/Los_Angeles"
)
mimetype.assign = (
  ".html" => "text/html"
)
index-file.names = ("index.html")
CONF

  lighttpd -f /tmp/test-lighttpd.conf -D &
  TEST_PID=$!
  sleep 0.5
}

test_health_endpoint() {
  setup_mock_server
  setup_test_server
  reset_state

  local resp
  resp=$(curl -sf http://127.0.0.1:${TEST_PORT}/health)
  echo "health: $resp"
  assertEquals "true" "$(echo "$resp" | jq -r '.ok')"
  assertNotNull "$(echo "$resp" | jq -r '.version')"

  teardown_mock_server
}

test_state_get() {
  setup_mock_server
  setup_test_server
  reset_state

  acquire_lock
  state=$(read_state)
  echo "$state" | jq '.currentCookie = "test123"' | write_state
  release_lock

  local resp
  resp=$(curl -sf http://127.0.0.1:${TEST_PORT}/state)
  echo "state GET: $resp"
  assertEquals "test123" "$(echo "$resp" | jq -r '.currentCookie')"
  assertEquals "10000" "$(echo "$resp" | jq -r '.settings.pointsBuffer')"

  teardown_mock_server
}

test_state_put_cookie() {
  setup_mock_server
  setup_test_server
  reset_state

  local resp
  resp=$(curl -sf -X PUT -d '{"currentCookie":"newcookie456"}' http://127.0.0.1:${TEST_PORT}/state)
  echo "state PUT: $resp"
  assertEquals "newcookie456" "$(echo "$resp" | jq -r '.currentCookie')"

  teardown_mock_server
}

test_state_put_settings() {
  setup_mock_server
  setup_test_server
  reset_state

  local resp
  resp=$(curl -sf -X PUT -d '{"settings":{"pointsBuffer":5000,"autoVip":false}}' http://127.0.0.1:${TEST_PORT}/state)
  echo "state PUT settings: $resp"
  assertEquals "5000" "$(echo "$resp" | jq -r '.settings.pointsBuffer')"
  assertEquals "false" "$(echo "$resp" | jq -r '.settings.autoVip')"
  # Unchanged settings preserved
  assertEquals "off" "$(echo "$resp" | jq -r '.settings.vaultMode')"
  assertEquals "24" "$(echo "$resp" | jq -r '.settings.spendIntervalHours')"

  teardown_mock_server
}

test_history_endpoint() {
  setup_mock_server
  setup_test_server
  reset_state

  local resp
  resp=$(curl -sf http://127.0.0.1:${TEST_PORT}/history)
  echo "history: $resp"
  assertEquals "[]" "$(echo "$resp" | jq -c '.spendHistory')"

  teardown_mock_server
}

test_refresh_endpoint() {
  setup_mock_server
  setup_test_server
  reset_state

  # Set cookie first
  curl -sf -X PUT -d '{"currentCookie":"test_refresh"}' http://127.0.0.1:${TEST_PORT}/state > /dev/null

  export MAM_BASE="http://127.0.0.1:${MOCK_PORT}"
  local resp
  resp=$(curl -s -X POST -d '' http://127.0.0.1:${TEST_PORT}/refresh)
  echo "refresh: $resp"
  local username
  username=$(echo "$resp" | jq -r '.username // empty')
  if [ -z "$username" ]; then
    # Debug: try direct mock call
    local direct
    direct=$(curl -s -H "Cookie: mam_id=test_refresh" "http://127.0.0.1:${MOCK_PORT}/jsonLoad.php?snatch_summary")
    echo "direct mock: $direct"
  fi
  assertEquals "testuser" "$username"

  teardown_mock_server
}

test_dry_run_endpoint() {
  setup_mock_server
  setup_test_server
  reset_state

  # Set cookie first
  curl -sf -X PUT -d '{"currentCookie":"test_dry"}' http://127.0.0.1:${TEST_PORT}/state > /dev/null

  export MAM_BASE="http://127.0.0.1:${MOCK_PORT}"
  local resp
  resp=$(curl -s -w '\nHTTP_CODE:%{http_code}' -X POST -d '' "http://127.0.0.1:${TEST_PORT}/dry-spend")
  echo "dry run resp: $resp"
  # Extract body (everything before last line)
  local body
  body=$(echo "$resp" | sed '$d')
  echo "dry run body: $body"
  assertEquals "true" "$(echo "$body" | jq -r '.dryRun')"
  assertEquals "50000" "$(echo "$body" | jq -r '.bonusPoints')"
  assertEquals "10000" "$(echo "$body" | jq -r '.buffer')"
  # With 50000 points and 10000 buffer, spendable = 40000, upload = 80 GB
  assertEquals "80" "$(echo "$body" | jq -r '.upload.gb')"
  assertEquals "40000" "$(echo "$body" | jq -r '.upload.cost')"
  assertEquals "40000" "$(echo "$body" | jq -r '.totalCost')"
  assertEquals "10000" "$(echo "$body" | jq -r '.pointsAfter')"

  # Verify no state mutation (no lastSpend, no spendHistory)
  local state_resp
  state_resp=$(curl -sf http://127.0.0.1:${TEST_PORT}/state)
  assertEquals "null" "$(echo "$state_resp" | jq -r '.lastSpend')"
  assertEquals "0" "$(echo "$state_resp" | jq '.spendHistory | length')"

  teardown_mock_server
}

test_index_html() {
  setup_mock_server
  setup_test_server

  local status
  status=$(curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:${TEST_PORT}/)
  assertEquals "200" "$status"

  local content_type
  content_type=$(curl -sf -o /dev/null -w '%{content_type}' http://127.0.0.1:${TEST_PORT}/)
  echo "$content_type" | grep -q "text/html" || fail "Expected text/html, got: $content_type"

  teardown_mock_server
}

# Load shunit2
. shunit2
