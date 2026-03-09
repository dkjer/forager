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
  assertEquals "true" "$(echo "$state" | jq -r '.settings.autoRefresh')"
  assertEquals "5" "$(echo "$state" | jq -r '.settings.autoRefreshMinutes')"
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

# --- Simulation Tests ---

# Helper: create state with profile and settings for simulation testing
make_sim_state() {
  local points="$1" vip_days_left="$2" buffer="$3"
  local auto_vip="${4:-true}" wedge_mode="${5:-off}" vault_mode="${6:-off}"
  local min_spend_gb="${7:-50}"
  local vip_until
  local future_epoch=$(($(date +%s) + vip_days_left * 86400))
  vip_until=$(date -d "@${future_epoch}" '+%Y-%m-%d 00:00:00' 2>/dev/null)

  reset_state
  acquire_lock
  local state
  state=$(read_state)
  state=$(echo "$state" | jq \
    --argjson pts "$points" \
    --arg vip "$vip_until" \
    --argjson buf "$buffer" \
    --argjson av "$auto_vip" \
    --arg wm "$wedge_mode" \
    --arg vm "$vault_mode" \
    --argjson msg "$min_spend_gb" \
    '
    .profile.bonusPoints = $pts |
    .profile.vipUntil = $vip |
    .profile.username = "testuser" |
    .settings.pointsBuffer = $buf |
    .settings.autoVip = $av |
    .settings.wedgeMode = $wm |
    .settings.vaultMode = $vm |
    .settings.minSpendGb = $msg
    ')
  echo "$state" | write_state
  release_lock
}

test_sim_no_profile() {
  reset_state
  local state sim
  state=$(read_state)
  sim=$(calc_simulation "$state")
  assertEquals "null" "$sim"
}

test_sim_upload_only() {
  # 100k points, 10k buffer, VIP at cap (90d), no wedge, no vault
  make_sim_state 100000 90 10000 false off off 50
  local state sim
  state=$(read_state)
  sim=$(calc_simulation "$state")
  assertEquals "false" "$(echo "$sim" | jq -r '.vip.would')"
  assertEquals "false" "$(echo "$sim" | jq -r '.wedge.would')"
  assertEquals "false" "$(echo "$sim" | jq -r '.vault.would')"
  # spendable = 100000 - 10000 = 90000 / 500 = 180 GB
  assertEquals "180" "$(echo "$sim" | jq -r '.upload.gb')"
  assertEquals "90000" "$(echo "$sim" | jq -r '.upload.cost')"
  assertEquals "10000" "$(echo "$sim" | jq -r '.pointsAfter')"
}

test_sim_buffer_prevents_upload() {
  # 30k points, 25k buffer → only 5k spendable = 10 GB, below 50 GB min
  make_sim_state 30000 90 25000 false off off 50
  local state sim
  state=$(read_state)
  sim=$(calc_simulation "$state")
  assertEquals "0" "$(echo "$sim" | jq -r '.upload.gb')"
  assertEquals "0" "$(echo "$sim" | jq -r '.totalCost')"
  assertEquals "30000" "$(echo "$sim" | jq -r '.pointsAfter')"
}

test_sim_vip_respects_buffer() {
  # 12k points, 10k buffer, VIP needs top-off (50 days left → 40 days to buy ≈ 7143 pts)
  # 12000 - 7143 = 4857 < 10000 buffer → should NOT buy VIP
  make_sim_state 12000 50 10000 true off off 50
  local state sim
  state=$(read_state)
  sim=$(calc_simulation "$state")
  assertEquals "false" "$(echo "$sim" | jq -r '.vip.would')"
  echo "$sim" | jq -r '.vip.reason' | grep -q "breach buffer" \
    || fail "VIP reason should mention buffer breach: $(echo "$sim" | jq -r '.vip.reason')"
}

test_sim_vip_affordable() {
  # 50k points, 10k buffer, VIP needs top-off (80 days left → 10 days ≈ 1786 pts)
  # 50000 - 1786 = 48214 > 10000 buffer → should buy VIP
  make_sim_state 50000 80 10000 true off off 50
  local state sim
  state=$(read_state)
  sim=$(calc_simulation "$state")
  assertEquals "true" "$(echo "$sim" | jq -r '.vip.would')"
}

test_sim_wedge_respects_buffer() {
  # 55k points, 10k buffer, wedge costs 50k
  # 55000 - 50000 = 5000 < 10000 buffer → should NOT buy wedge
  make_sim_state 55000 90 10000 false before off 50
  local state sim
  state=$(read_state)
  sim=$(calc_simulation "$state")
  assertEquals "false" "$(echo "$sim" | jq -r '.wedge.would')"
  echo "$sim" | jq -r '.wedge.reason' | grep -q "breach buffer" \
    || fail "Wedge reason should mention buffer breach: $(echo "$sim" | jq -r '.wedge.reason')"
}

test_sim_wedge_affordable() {
  # 70k points, 10k buffer, wedge costs 50k
  # 70000 - 50000 = 20000 > 10000 buffer → should buy wedge
  make_sim_state 70000 90 10000 false before off 50
  local state sim
  state=$(read_state)
  sim=$(calc_simulation "$state")
  assertEquals "true" "$(echo "$sim" | jq -r '.wedge.would')"
  assertEquals "50000" "$(echo "$sim" | jq -r '.wedge.cost')"
}

test_sim_vault_respects_buffer() {
  # 11k points, 10k buffer, vault costs 2k
  # 11000 - 2000 = 9000 < 10000 buffer → should NOT enter vault
  make_sim_state 11000 90 10000 false off once 50
  acquire_lock
  local state
  state=$(read_state)
  echo "$state" | jq '.browserSession.mbsc = "test" | .browserSession.userAgent = "test"' | write_state
  release_lock
  state=$(read_state)
  local sim
  sim=$(calc_simulation "$state")
  assertEquals "false" "$(echo "$sim" | jq -r '.vault.would')"
  echo "$sim" | jq -r '.vault.reason' | grep -q "above buffer" \
    || fail "Vault reason should mention buffer: $(echo "$sim" | jq -r '.vault.reason')"
}

test_sim_vault_affordable() {
  # 15k points, 10k buffer, vault costs 2k
  # 15000 - 2000 = 13000 > 10000 buffer → should enter vault
  make_sim_state 15000 90 10000 false off once 50
  acquire_lock
  local state
  state=$(read_state)
  echo "$state" | jq '.browserSession.mbsc = "test" | .browserSession.userAgent = "test"' | write_state
  release_lock
  state=$(read_state)
  local sim
  sim=$(calc_simulation "$state")
  assertEquals "true" "$(echo "$sim" | jq -r '.vault.would')"
  assertEquals "2000" "$(echo "$sim" | jq -r '.vault.cost')"
}

test_sim_all_purchases() {
  # 200k points, 10k buffer, VIP 80d, wedge before, vault once
  # VIP: ~1786 pts, wedge: 50000, vault: 2000
  # remaining after VIP+wedge+vault ≈ 146214, spendable = 146214 - 10000 = 136214
  # upload = 136214/500 = 272 GB
  make_sim_state 200000 80 10000 true before once 50
  acquire_lock
  local state
  state=$(read_state)
  echo "$state" | jq '.browserSession.mbsc = "test" | .browserSession.userAgent = "test"' | write_state
  release_lock
  state=$(read_state)
  local sim
  sim=$(calc_simulation "$state")
  assertEquals "true" "$(echo "$sim" | jq -r '.vip.would')"
  assertEquals "true" "$(echo "$sim" | jq -r '.wedge.would')"
  assertEquals "true" "$(echo "$sim" | jq -r '.vault.would')"
  # Upload GB should be > 0
  local gb
  gb=$(echo "$sim" | jq -r '.upload.gb')
  assertTrue "Upload should be > 0, got $gb" "[ $gb -gt 0 ]"
  # Points after should be close to buffer
  local after
  after=$(echo "$sim" | jq -r '.pointsAfter')
  assertTrue "Points after ($after) should be near buffer (10000)" "[ $after -ge 10000 ] && [ $after -lt 11000 ]"
}

test_sim_min_spend_gb_threshold() {
  # 35k points, 10k buffer → 25k spendable = 50 GB, exactly at min
  make_sim_state 35000 90 10000 false off off 50
  local state sim
  state=$(read_state)
  sim=$(calc_simulation "$state")
  assertEquals "50" "$(echo "$sim" | jq -r '.upload.gb')"
  assertEquals "25000" "$(echo "$sim" | jq -r '.upload.cost')"
}

test_sim_min_spend_gb_below_threshold() {
  # 34k points, 10k buffer → 24k spendable = 48 GB, below 50 GB min
  make_sim_state 34000 90 10000 false off off 50
  local state sim
  state=$(read_state)
  sim=$(calc_simulation "$state")
  assertEquals "0" "$(echo "$sim" | jq -r '.upload.gb')"
}

test_sim_wedge_only_mode() {
  # wedge=only should skip upload entirely
  make_sim_state 200000 90 10000 false only off 50
  local state sim
  state=$(read_state)
  sim=$(calc_simulation "$state")
  assertEquals "true" "$(echo "$sim" | jq -r '.wedge.would')"
  assertEquals "0" "$(echo "$sim" | jq -r '.upload.gb')"
  echo "$sim" | jq -r '.upload.reason' | grep -q "Wedge-only" \
    || fail "Upload reason should mention wedge-only: $(echo "$sim" | jq -r '.upload.reason')"
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
