#!/bin/sh
# Shared functions for forager — MAM bonus point auto-spender

FORAGER_VERSION=$(cat /app/VERSION 2>/dev/null | tr -d '\n' || echo "unknown")
STATE_FILE="${FORAGER_STATE_DIR:-/srv/forager}/state.json"
LOCK_DIR="/var/run/forager.lock"
USER_AGENT="forager/${FORAGER_VERSION}"
MAM_BASE="${MAM_BASE:-https://www.myanonamouse.net}"
COOKIE_JAR="${FORAGER_STATE_DIR:-/srv/forager}/cookies.txt"
MBSC_FILE="${FORAGER_STATE_DIR:-/srv/forager}/mbsc.txt"
BROWSER_UA=""  # Set from state at runtime
SPEND_INTERVAL="${FORAGER_SPEND_INTERVAL:-86400}"
POINTS_PER_GB=500
VAULT_COST=2000
VIP_MAX_DAYS=90
VIP_POINTS_PER_4WEEKS=5000  # 5000 pts per 28 days (~178.57/day)
WEDGE_COST=50000
MAX_POINTS_HISTORY=48
MAX_SPEND_HISTORY_DAYS=90
VERIFY_DELAY=1  # seconds to wait before verifying purchase

# --- Timestamps ---

timestamp() {
  local ts tz
  ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
  tz="${TZ:-UTC}"
  printf '%s[%s]' "$ts" "$tz"
}

next_spend_timestamp() {
  local interval_hours interval_secs next_ts tz
  interval_hours=$(read_state | jq -r '.settings.spendIntervalHours // 24')
  interval_secs=$((interval_hours * 3600))
  next_ts=$(date -d "@$(($(date +%s) + interval_secs))" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)
  tz="${TZ:-UTC}"
  printf '%s[%s]' "$next_ts" "$tz"
}

epoch_from_timestamp() {
  local ts="$1"
  date -d "$(echo "$ts" | sed 's/\[.*\]//;s/T/ /;s/[+-][0-9]\{4\}$//')" +%s 2>/dev/null || echo 0
}

# --- Locking ---

acquire_lock() {
  local tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then
      rm -rf "$LOCK_DIR"
    fi
    sleep 0.1
  done
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

# --- State R/W ---

read_state() {
  if [ -f "$STATE_FILE" ]; then
    local content
    content=$(cat "$STATE_FILE")
    if [ -z "$content" ] || [ "$content" = "" ]; then
      echo '{}'
    else
      echo "$content"
    fi
  else
    echo '{}'
  fi
}

write_state() {
  local tmp="${STATE_FILE}.tmp"
  cat > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

get_cookie() {
  read_state | jq -r '.currentCookie // empty'
}

get_setting() {
  local key="$1" default="$2"
  local val
  val=$(read_state | jq -r ".settings.${key} // empty")
  if [ -z "$val" ]; then
    echo "$default"
  else
    echo "$val"
  fi
}

init_state() {
  local state
  state=$(read_state)
  echo "$state" | jq '
    .settings //= {
      pointsBuffer: 10000,
      autoVip: true,
      vaultMode: "off",
      spendIntervalHours: 24,
      wedgeMode: "off",
      minSpendGb: 50
    } |
    .settings.vaultMode //= "off" |
    .settings.wedgeMode //= "off" |
    .settings.minSpendGb //= 50 |
    .paused //= false |
    # Migrate old boolean vaultEnabled to vaultMode
    if .settings.vaultEnabled == true then .settings.vaultMode = "once" else . end |
    del(.settings.vaultEnabled) |
    # Migrate old wedgeIntervalHours to wedgeMode
    if (.settings.wedgeIntervalHours // 0) > 0 then .settings.wedgeMode = "before" else . end |
    del(.settings.wedgeIntervalHours) |
    .profile //= {} |
    .browserSession //= {mbsc: null, userAgent: null} |
    .vault //= {currentPotId: null, enteredCurrentPot: false, lastEntryAt: null, currentPotContributed: 0} |
    .lastSpend //= null |
    .spendHistory //= [] |
    .lifetime //= {totalGbPurchased: 0, totalPointsSpent: 0} |
    .pointsHistory //= [] |
    .nextSpendAt //= null
  ' | write_state
}

# --- MAM API ---

# Ensure cookie jar has a valid session. Bootstrap from mam_id if needed.
ensure_session() {
  local cookie
  cookie=$(get_cookie)

  # If jar exists and has content, test it
  if [ -f "$COOKIE_JAR" ] && [ -s "$COOKIE_JAR" ]; then
    local test_uid
    test_uid=$(curl -sf --max-time 15 \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H "User-Agent: $USER_AGENT" \
      "${MAM_BASE}/jsonLoad.php?snatch_summary" 2>/dev/null | jq -r '.uid // empty')
    if [ -n "$test_uid" ]; then
      return 0  # Session valid
    fi
    echo "[forager] Cookie jar session expired, re-bootstrapping..." >&2
  fi

  # Bootstrap from mam_id
  if [ -z "$cookie" ]; then
    echo "[forager] No mam_id cookie set" >&2
    return 1
  fi

  echo "[forager] Bootstrapping session from mam_id..." >&2
  local test_uid
  test_uid=$(curl -sf --max-time 15 \
    -b "mam_id=$cookie" -c "$COOKIE_JAR" \
    -H "User-Agent: $USER_AGENT" \
    "${MAM_BASE}/jsonLoad.php?snatch_summary" 2>/dev/null | jq -r '.uid // empty')
  if [ -n "$test_uid" ]; then
    echo "[forager] Session established for uid $test_uid" >&2
    return 0
  fi

  echo "[forager] Failed to establish session" >&2
  return 1
}

mam_request() {
  local path="$1" method="${2:-GET}" post_data="${3:-}"
  local url="${MAM_BASE}${path}"
  local ts
  ts=$(date +%s%3N)

  # Append cache-busting timestamp
  case "$url" in
    *"?"*) url="${url}&_=${ts}" ;;
    *)     url="${url}?_=${ts}" ;;
  esac

  local body
  if [ -n "$post_data" ]; then
    body=$(curl -sf --max-time 15 \
      -X "$method" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H "User-Agent: $USER_AGENT" \
      -d "$post_data" \
      "$url" 2>/dev/null)
  else
    body=$(curl -sf --max-time 15 \
      -X "$method" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H "User-Agent: $USER_AGENT" \
      "$url" 2>/dev/null)
  fi

  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    return 1
  fi

  printf '%s' "$body"
}

# mam_request variant that falls back to mam_id header (for test mocks without jar)
mam_request_init() {
  local cookie="$1" path="$2"
  local url="${MAM_BASE}${path}"

  curl -sf --max-time 15 \
    -b "mam_id=$cookie" -c "$COOKIE_JAR" \
    -H "User-Agent: $USER_AGENT" \
    "$url" 2>/dev/null
}

# --- Browser Session (mbsc) for HTML pages ---

# Load mbsc cookie and UA from state into runtime vars
load_browser_session() {
  local state
  state=$(read_state)
  local mbsc ua
  mbsc=$(echo "$state" | jq -r '.browserSession.mbsc // empty')
  ua=$(echo "$state" | jq -r '.browserSession.userAgent // empty')
  if [ -z "$mbsc" ] || [ -z "$ua" ]; then
    return 1
  fi
  # Strip "mbsc=" prefix if user pasted the full cookie string
  mbsc=$(echo "$mbsc" | sed 's/^mbsc=//')
  # Write mbsc to file for curl -b
  printf '.myanonamouse.net\tTRUE\t/\tTRUE\t0\tmbsc\t%s\n' "$mbsc" > "$MBSC_FILE"
  BROWSER_UA="$ua"
  return 0
}

# Make an HTML page request using the browser session (mbsc cookie + UA)
# Updates the mbsc cookie in state from the response Set-Cookie
# Returns 1 on failure, 2 if session is expired/invalid
mam_html_request() {
  local path="$1"
  local post_data="$2"  # Optional: if set, sends POST with this data
  local url="${MAM_BASE}${path}"

  if [ -z "$BROWSER_UA" ]; then
    load_browser_session || return 1
  fi

  local out_jar="${MBSC_FILE}.new"
  local http_code body
  # Don't use -f or -L — we need to detect 302 redirects to login
  if [ -n "$post_data" ]; then
    body=$(curl -s --max-time 15 \
      -b "$MBSC_FILE" \
      -c "$out_jar" \
      -w '\n%{http_code}' \
      -H "User-Agent: $BROWSER_UA" \
      -d "$post_data" \
      "$url" 2>/dev/null)
  else
    body=$(curl -s --max-time 15 \
      -b "$MBSC_FILE" \
      -c "$out_jar" \
      -w '\n%{http_code}' \
      -H "User-Agent: $BROWSER_UA" \
      "$url" 2>/dev/null)
  fi

  # Extract HTTP code from last line
  http_code=$(echo "$body" | tail -1)
  body=$(echo "$body" | sed '$d')

  # Detect session expiry: 302 redirect to login, or deleted mbsc cookie
  if [ "$http_code" = "302" ] || [ "$http_code" = "403" ]; then
    echo "[forager] Browser session expired (HTTP $http_code on $path)" >&2
    mark_browser_session_expired
    rm -f "$out_jar"
    return 2
  fi

  if [ "$http_code" != "200" ]; then
    echo "[forager] HTML request failed: $path (HTTP $http_code)" >&2
    rm -f "$out_jar"
    return 1
  fi

  # Check if the response contains a login redirect (sometimes 200 with JS redirect)
  if echo "$body" | grep -q 'login.php?returnto='; then
    echo "[forager] Browser session expired (login redirect in body for $path)" >&2
    mark_browser_session_expired
    rm -f "$out_jar"
    return 2
  fi

  # Capture rotated mbsc from response cookie jar
  local new_mbsc
  new_mbsc=$(grep 'mbsc' "$out_jar" 2>/dev/null | awk '{print $NF}')
  if [ -n "$new_mbsc" ]; then
    # Check for "mbsc=deleted" which means session was killed
    if [ "$new_mbsc" = "deleted" ]; then
      echo "[forager] Browser session invalidated (mbsc deleted by server)" >&2
      mark_browser_session_expired
      rm -f "$out_jar"
      return 2
    fi
    # Update state with new mbsc and clear any expired flag
    acquire_lock
    local state
    state=$(read_state)
    echo "$state" | jq --arg m "$new_mbsc" '
      .browserSession.mbsc = $m |
      .browserSession.expired = false
    ' | write_state
    release_lock
    # Update mbsc file for next request
    mv -f "$out_jar" "$MBSC_FILE"
  else
    rm -f "$out_jar"
    echo "[forager] Warning: no mbsc cookie in response for $path" >&2
  fi

  printf '%s' "$body"
}

# Mark browser session as expired in state so the UI can show a warning
mark_browser_session_expired() {
  acquire_lock
  local state
  state=$(read_state)
  local now
  now=$(timestamp)
  echo "$state" | jq --arg at "$now" '
    .browserSession.expired = true |
    .browserSession.expiredAt = $at
  ' | write_state
  release_lock
  echo "[forager] Browser session marked as expired — user must provide a fresh mbsc cookie" >&2
}

fetch_profile() {
  local raw
  raw=$(mam_request "/jsonLoad.php?snatch_summary")
  if [ -z "$raw" ]; then
    return 1
  fi
  # Extract fields from MAM response
  local username uid bonus uploaded downloaded ratio vip_until
  username=$(echo "$raw" | jq -r '.username // empty')
  uid=$(echo "$raw" | jq -r '.uid // empty')

  if [ -z "$username" ] || [ -z "$uid" ]; then
    echo "[forager] Profile fetch failed: missing username/uid" >&2
    return 1
  fi

  bonus=$(echo "$raw" | jq -r '.seedbonus // 0')
  uploaded=$(echo "$raw" | jq -r '.uploaded // "0"')
  downloaded=$(echo "$raw" | jq -r '.downloaded // "0"')
  local uploaded_bytes downloaded_bytes
  uploaded_bytes=$(echo "$raw" | jq -r '.uploaded_bytes // 0')
  downloaded_bytes=$(echo "$raw" | jq -r '.downloaded_bytes // 0')
  # Compute ratio from raw bytes for full precision
  if [ "$downloaded_bytes" -gt 0 ] 2>/dev/null; then
    ratio=$(awk "BEGIN {printf \"%.9f\", $uploaded_bytes / $downloaded_bytes}")
  else
    ratio=$(echo "$raw" | jq -r '.ratio // 0')
  fi
  vip_until=$(echo "$raw" | jq -r '.vip_until // empty')

  local now
  now=$(timestamp)

  jq -n \
    --arg username "$username" \
    --argjson uid "${uid:-0}" \
    --argjson bonusPoints "$(echo "$bonus" | awk '{printf "%.0f", $1}')" \
    --arg uploaded "$uploaded" \
    --arg downloaded "$downloaded" \
    --arg ratio "$ratio" \
    --arg vipUntil "$vip_until" \
    --arg fetchedAt "$now" \
    '{
      username: $username,
      uid: $uid,
      bonusPoints: $bonusPoints,
      uploaded: $uploaded,
      downloaded: $downloaded,
      ratio: ($ratio | tonumber),
      vipUntil: $vipUntil,
      fetchedAt: $fetchedAt
    }'
}

buy_upload() {
  local gb="$1"
  mam_request "/json/bonusBuy.php/?spendtype=upload&amount=${gb}"
}

buy_vip() {
  mam_request "/json/bonusBuy.php/?spendtype=VIP&duration=max"
}

buy_wedge() {
  mam_request "/json/bonusBuy.php/?spendtype=wedges&source=points"
}

fetch_vault_page() {
  mam_html_request "/millionaires/pot.php"
}

# Parse vault page HTML for pot info
parse_vault_page() {
  local html="$1"
  if [ -z "$html" ]; then
    return 1
  fi

  # Check if we got a real page (not a redirect/error)
  if echo "$html" | grep -q 'login.php'; then
    echo "[forager] Vault page returned login redirect — mbsc session may be invalid" >&2
    return 1
  fi

  local pot_amount pot_max start_date donated_today user_total_donated
  # "vault: 18,613,000 points" in nav bar
  pot_amount=$(echo "$html" | grep -o 'vault: [0-9,]* points' | grep -o '[0-9,]*' | tr -d ',')
  # "reaches 20,000,000 bonus points" — the pot target
  pot_max=$(echo "$html" | grep -o 'reaches.*[0-9,]*.*bonus points' | grep -o '[0-9][0-9,]*' | tr -d ',')
  # "started on the 3rd of March 2026"
  start_date=$(echo "$html" | grep -o 'started on the [^<]*' | head -1 | sed 's/started on the //')
  # "You have not donated today" or absence thereof
  if echo "$html" | grep -q 'have not donated today'; then
    donated_today="false"
  else
    donated_today="true"
  fi
  # Sum all donation amounts from the user's donation table
  # Each row has <td>2,000</td> for the amount column
  user_total_donated=0
  for amt in $(echo "$html" | grep -o '<td>[0-9,]*</td>' | grep -o '[0-9,]*' | tr -d ','); do
    user_total_donated=$((user_total_donated + amt))
  done

  jq -n \
    --arg potAmount "${pot_amount:-0}" \
    --arg potMax "${pot_max:-20000000}" \
    --arg startDate "$start_date" \
    --arg donatedToday "$donated_today" \
    --arg userTotalDonated "$user_total_donated" \
    '{
      potAmount: ($potAmount | tonumber),
      potMax: ($potMax | tonumber),
      startDate: $startDate,
      donatedToday: ($donatedToday == "true"),
      userTotalDonated: ($userTotalDonated | tonumber)
    }'
}

# Scrape user profile page for points/hour and other stats
# Uses uid from state to build the URL (/u/<uid>)
parse_profile_page() {
  local html="$1"
  if [ -z "$html" ]; then return 1; fi
  if echo "$html" | grep -q 'login.php'; then return 1; fi

  local points_per_hour satisfied unsatisfied leeching wedges
  points_per_hour=$(echo "$html" | grep -o 'worth [0-9,.]*  *per hour' | grep -o '[0-9,.]*' | tr -d ',')
  satisfied=$(echo "$html" | grep -o '[0-9,]* satisfied torrents' | grep -o '[0-9,]*' | tr -d ',')
  unsatisfied=$(echo "$html" | grep -o '[0-9]* seeding unsatisfied' | grep -o '[0-9]*')
  leeching=$(echo "$html" | grep -o '[0-9]* leeching torrents' | grep -o '[0-9]*')
  wedges=$(echo "$html" | grep -o 'FL wedges</td><td[^>]*>[0-9,]*' | grep -o '[0-9,]*$' | tr -d ',')

  jq -n \
    --arg pph "${points_per_hour:-0}" \
    --arg sat "${satisfied:-0}" \
    --arg unsat "${unsatisfied:-0}" \
    --arg leech "${leeching:-0}" \
    --arg wedges "${wedges:-0}" \
    '{
      pointsPerHour: ($pph | tonumber),
      satisfiedTorrents: ($sat | tonumber),
      unsatisfiedTorrents: ($unsat | tonumber),
      leechingTorrents: ($leech | tonumber),
      flWedges: ($wedges | tonumber)
    }'
}

# Fetch and scrape the user profile page, save stats to state
refresh_profile_page() {
  local state
  state=$(read_state)
  local uid
  uid=$(echo "$state" | jq -r '.profile.uid // empty')
  if [ -z "$uid" ]; then
    echo "[forager] No uid in state, cannot fetch profile page" >&2
    return 1
  fi

  local html
  html=$(mam_html_request "/u/${uid}")
  if [ $? -ne 0 ] || [ -z "$html" ]; then
    echo "[forager] Failed to fetch profile page" >&2
    return 1
  fi

  local info
  info=$(parse_profile_page "$html")
  if [ -z "$info" ]; then
    echo "[forager] Failed to parse profile page" >&2
    return 1
  fi

  local now
  now=$(timestamp)
  acquire_lock
  state=$(read_state)
  state=$(echo "$state" | jq --argjson i "$info" --arg at "$now" '
    .profile.pointsPerHour = $i.pointsPerHour |
    .profile.satisfiedTorrents = $i.satisfiedTorrents |
    .profile.unsatisfiedTorrents = $i.unsatisfiedTorrents |
    .profile.leechingTorrents = $i.leechingTorrents |
    .profile.flWedges = $i.flWedges |
    .profile.profileScrapedAt = $at
  ')
  echo "$state" | write_state
  release_lock

  echo "[forager] Profile page scraped: $(echo "$info" | jq -r '.pointsPerHour') pts/hr, $(echo "$info" | jq -r '.satisfiedTorrents') satisfied" >&2
  printf '%s' "$info"
}

# Donate to the vault via the donate page (two-step: fetch form, then POST)
donate_to_vault() {
  local amount="${1:-2000}"

  # Step 1: GET the donate page to extract the CSRF 'time' token
  local form_html
  form_html=$(mam_html_request "/millionaires/donate.php")
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "[forager] Failed to fetch donate form (rc=$rc)" >&2
    return $rc
  fi

  # Extract the hidden 'time' field value
  local csrf_time
  csrf_time=$(echo "$form_html" | sed -n 's/.*name="time" value="\([^"]*\)".*/\1/p')
  if [ -z "$csrf_time" ]; then
    echo "[forager] Could not extract CSRF time token from donate form" >&2
    return 1
  fi

  echo "[forager] Donating $amount points to vault (csrf time=$csrf_time)" >&2

  # Step 2: POST the donation form
  local post_data="Donation=${amount}&time=${csrf_time}&submit=Donate+Points"
  local result_html
  result_html=$(mam_html_request "/millionaires/donate.php" "$post_data")
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "[forager] Donate POST failed (rc=$rc)" >&2
    return $rc
  fi

  # Verify donation succeeded by checking response content
  if echo "$result_html" | grep -q 'have not donated today'; then
    echo "[forager] Donation may have failed — page still says 'have not donated today'" >&2
    return 1
  fi

  printf '%s' "$result_html"
}

# --- Points History ---

append_points_history() {
  local state="$1" points="$2"
  local now
  now=$(timestamp)
  echo "$state" | jq \
    --argjson points "$points" \
    --arg at "$now" \
    --argjson max "$MAX_POINTS_HISTORY" \
    '.pointsHistory += [{points: $points, at: $at}] |
     .pointsHistory = .pointsHistory[-$max:]'
}

calc_points_per_hour() {
  local state="$1"
  echo "$state" | jq -r '.profile.pointsPerHour // 0'
}

# --- Spend Cycle ---

# Read current points from a bonusBuy response, or re-fetch profile
get_current_points() {
  local buy_response="$1"
  local pts
  pts=$(echo "$buy_response" | jq -r '.seedbonus // empty' 2>/dev/null)
  if [ -n "$pts" ]; then
    echo "$pts" | awk '{printf "%.0f", $1}'
  else
    # Fallback: re-fetch profile
    local profile
    profile=$(fetch_profile)
    if [ -n "$profile" ]; then
      echo "$profile" | jq -r '.bonusPoints'
    fi
  fi
}

# Verify a purchase succeeded by checking balance decreased
# Returns new balance on success, empty on failure
verify_purchase() {
  local before="$1" buy_response="$2" label="$3"
  sleep "$VERIFY_DELAY"
  local after
  after=$(get_current_points "$buy_response")
  if [ -z "$after" ]; then
    echo "[forager] $label: could not read balance after purchase" >&2
    return 1
  fi
  if [ "$after" -ge "$before" ]; then
    echo "[forager] $label: balance did not decrease ($before -> $after), purchase may have failed" >&2
    return 1
  fi
  echo "[forager] $label: verified ($before -> $after, -$((before - after)))" >&2
  echo "$after"
}

run_spend() {
  local trigger="${1:-manual}"

  # Check if paused
  local is_paused
  is_paused=$(read_state | jq -r '.paused // false')
  if [ "$is_paused" = "true" ]; then
    echo '{"error":"Spending is paused"}' >&2
    return 1
  fi

  # Ensure we have a valid session
  ensure_session
  if [ $? -ne 0 ]; then
    echo '{"error":"No valid session"}' >&2
    return 1
  fi

  # 1. Fetch profile
  local profile
  profile=$(fetch_profile)
  if [ -z "$profile" ]; then
    echo '{"error":"Failed to fetch profile"}' >&2
    return 1
  fi

  local now
  now=$(timestamp)
  local points_before
  points_before=$(echo "$profile" | jq -r '.bonusPoints')
  local current_points="$points_before"

  # 2. Update profile in state, append to pointsHistory
  acquire_lock
  local state
  state=$(read_state)
  state=$(echo "$state" | jq --argjson p "$profile" '.profile = (.profile // {}) * $p')
  state=$(append_points_history "$state" "$points_before")
  echo "$state" | write_state
  release_lock

  local vip_purchased="false"
  local vault_entered="false"
  local wedge_purchased="false"
  local upload_gb=0
  local total_points_spent=0

  # 3. Auto VIP
  local auto_vip
  auto_vip=$(echo "$state" | jq -r '.settings.autoVip // false')
  if [ "$auto_vip" = "true" ]; then
    local vip_until
    vip_until=$(echo "$profile" | jq -r '.vipUntil // empty')
    if [ -n "$vip_until" ]; then
      local vip_epoch now_epoch days_remaining
      vip_epoch=$(date -d "$vip_until" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      days_remaining=$(( (vip_epoch - now_epoch) / 86400 ))
      # Only top off when at least 1 full day below max VIP
      if [ "$days_remaining" -lt $((VIP_MAX_DAYS - 1)) ]; then
        local days_to_buy=$((VIP_MAX_DAYS - days_remaining))
        local est_cost=$(awk "BEGIN {printf \"%.0f\", $days_to_buy * $VIP_POINTS_PER_4WEEKS / 28}")
        echo "[forager] VIP has ${days_remaining}d, buying ${days_to_buy}d (~${est_cost} pts)..." >&2
        local vip_result
        vip_result=$(buy_vip)
        if [ -n "$vip_result" ]; then
          local vip_success
          vip_success=$(echo "$vip_result" | jq -r '.success // false')
          if [ "$vip_success" = "true" ]; then
            local verified_pts
            verified_pts=$(verify_purchase "$current_points" "$vip_result" "VIP")
            if [ -n "$verified_pts" ]; then
              vip_purchased="true"
              current_points="$verified_pts"
            fi
          fi
        fi
      fi
    fi
  fi

  # 4. Wedge purchase (off / before upload / FL-only)
  local wedge_mode
  wedge_mode=$(echo "$state" | jq -r '.settings.wedgeMode // "off"')
  if [ "$wedge_mode" != "off" ] && [ "$current_points" -ge "$WEDGE_COST" ]; then
    echo "[forager] Buying wedge (${WEDGE_COST} points)..." >&2
    local wedge_result
    wedge_result=$(buy_wedge)
    if [ -n "$wedge_result" ]; then
      local wedge_success
      wedge_success=$(echo "$wedge_result" | jq -r '.success // false')
      if [ "$wedge_success" = "true" ]; then
        local verified_pts
        verified_pts=$(verify_purchase "$current_points" "$wedge_result" "Wedge")
        if [ -n "$verified_pts" ]; then
          wedge_purchased="true"
          total_points_spent=$((total_points_spent + (current_points - verified_pts)))
          current_points="$verified_pts"
          acquire_lock
          state=$(read_state)
          echo "$state" | jq --arg at "$now" '.lastWedgeAt = $at' | write_state
          release_lock
        fi
      fi
    fi
  fi

  # 5. Vault contribution (off / once per pot / daily)
  local vault_mode
  vault_mode=$(echo "$state" | jq -r '.settings.vaultMode // "off"')
  local has_browser_session="false"
  if [ -n "$(echo "$state" | jq -r '.browserSession.mbsc // empty')" ]; then
    has_browser_session="true"
  fi

  if [ "$vault_mode" != "off" ] && [ "$has_browser_session" = "true" ]; then
    # Scrape vault page for pot info
    local vault_html
    vault_html=$(fetch_vault_page)
    if [ -n "$vault_html" ]; then
      local vault_info
      vault_info=$(parse_vault_page "$vault_html")
      if [ -n "$vault_info" ]; then
        local pot_amount pot_max start_date donated_today user_total_donated
        pot_amount=$(echo "$vault_info" | jq -r '.potAmount')
        pot_max=$(echo "$vault_info" | jq -r '.potMax')
        start_date=$(echo "$vault_info" | jq -r '.startDate // empty')
        donated_today=$(echo "$vault_info" | jq -r '.donatedToday')
        user_total_donated=$(echo "$vault_info" | jq -r '.userTotalDonated')

        # Use start_date as pot ID
        local pot_id="$start_date"
        local current_pot_id
        current_pot_id=$(echo "$state" | jq -r '.vault.currentPotId // empty')

        acquire_lock
        state=$(read_state)

        # Check for new pot FIRST (resets contribution tracking)
        if [ -n "$pot_id" ] && [ "$pot_id" != "$current_pot_id" ]; then
          echo "[forager] New pot detected: $pot_id (was: ${current_pot_id:-none})" >&2
          state=$(echo "$state" | jq --arg pid "$pot_id" '
            .vault.currentPotId = $pid |
            .vault.enteredCurrentPot = false |
            .vault.currentPotContributed = 0
          ')
        fi

        # Then update pot info and contribution data from scrape
        if [ -n "$pot_amount" ] && [ "$pot_amount" != "0" ]; then
          state=$(echo "$state" | jq --argjson amt "$pot_amount" --argjson max "$pot_max" '
            .vault.currentPotAmount = $amt |
            .vault.potMax = $max
          ')
        fi
        if [ -n "$start_date" ]; then
          state=$(echo "$state" | jq --arg sd "$start_date" '.vault.potStartDate = $sd')
        fi
        if [ -n "$user_total_donated" ] && [ "$user_total_donated" != "0" ]; then
          state=$(echo "$state" | jq --argjson d "$user_total_donated" '
            .vault.currentPotContributed = $d |
            .vault.enteredCurrentPot = true
          ')
        fi
        echo "$state" | write_state
        release_lock

        # Determine if we should contribute
        local should_contribute="false"
        if [ "$vault_mode" = "once" ]; then
          local entered
          entered=$(echo "$state" | jq -r '.vault.enteredCurrentPot // false')
          if [ "$entered" = "true" ] || [ "$user_total_donated" -gt 0 ] 2>/dev/null; then
            should_contribute="false"
          else
            should_contribute="true"
          fi
        elif [ "$vault_mode" = "daily" ]; then
          if [ "$donated_today" = "false" ]; then
            should_contribute="true"
          fi
        fi

        # Contribute if conditions met and we have enough points
        if [ "$should_contribute" = "true" ] && [ "$current_points" -ge "$VAULT_COST" ]; then
          echo "[forager] Contributing to vault (${VAULT_COST} points)..." >&2
          local donate_html
          donate_html=$(donate_to_vault "$VAULT_COST")
          local donate_rc=$?
          if [ $donate_rc -eq 0 ] && [ -n "$donate_html" ]; then
            vault_entered="true"
            total_points_spent=$((total_points_spent + VAULT_COST))
            current_points=$((current_points - VAULT_COST))
            acquire_lock
            state=$(read_state)
            state=$(echo "$state" | jq --arg at "$now" --argjson cost "$VAULT_COST" '
              .vault.enteredCurrentPot = true |
              .vault.lastEntryAt = $at |
              .vault.currentPotContributed = ((.vault.currentPotContributed // 0) + $cost)
            ')
            echo "$state" | write_state
            release_lock
          fi
        fi
      fi
    fi
  elif [ "$vault_mode" != "off" ] && [ "$has_browser_session" = "false" ]; then
    echo "[forager] Vault mode is $vault_mode but no browser session configured — skipping" >&2
  fi

  # 6. Buy upload credit (skip if wedge mode is "only")
  local buffer min_spend_gb
  buffer=$(echo "$state" | jq -r '.settings.pointsBuffer // 10000')
  min_spend_gb=$(echo "$state" | jq -r '.settings.minSpendGb // 50')

  if [ "$min_spend_gb" -eq 0 ]; then
    echo "[forager] Upload purchasing disabled (minSpendGb=0)" >&2
  elif [ "$wedge_mode" = "only" ]; then
    echo "[forager] Wedge-only mode, skipping upload purchase" >&2
  else
    # MAM enforces a minimum of 50 GB per API call
    local mam_min_gb=50
    if [ "$min_spend_gb" -lt "$mam_min_gb" ]; then
      min_spend_gb=$mam_min_gb
    fi

    local spendable_pts=$((current_points - buffer))
    local min_spend_pts=$((min_spend_gb * POINTS_PER_GB))
    if [ "$spendable_pts" -lt "$min_spend_pts" ]; then
      echo "[forager] Only $((spendable_pts / POINTS_PER_GB)) GB available, below minimum ${min_spend_gb} GB — skipping upload" >&2
    else
      # Buy in a single call: floor(spendable / cost_per_gb)
      local buy_gb=$((spendable_pts / POINTS_PER_GB))
      echo "[forager] Buying ${buy_gb} GB upload..." >&2
      local buy_result
      buy_result=$(buy_upload "$buy_gb")
      if [ -n "$buy_result" ]; then
        local buy_success
        buy_success=$(echo "$buy_result" | jq -r '.success // false')
        if [ "$buy_success" = "true" ]; then
          local verified_pts
          verified_pts=$(verify_purchase "$current_points" "$buy_result" "Upload ${buy_gb}GB")
          if [ -n "$verified_pts" ]; then
            local spent_this=$((current_points - verified_pts))
            upload_gb=$((upload_gb + buy_gb))
            total_points_spent=$((total_points_spent + spent_this))
            current_points="$verified_pts"
          else
            echo "[forager] Upload verification failed" >&2
          fi
        else
          echo "[forager] Upload purchase rejected: $(echo "$buy_result" | jq -r '.error // "unknown"')" >&2
        fi
      else
        echo "[forager] Upload purchase failed" >&2
      fi
    fi
  fi

  local points_after="$current_points"

  # Re-fetch profile to get updated balances (VIP expiry, points, upload)
  if [ "$vip_purchased" = "true" ] || [ "$upload_gb" -gt 0 ]; then
    echo "[forager] Re-fetching profile after purchases..." >&2
    local updated_profile
    updated_profile=$(fetch_profile)
    if [ -n "$updated_profile" ]; then
      local new_pts
      new_pts=$(echo "$updated_profile" | jq -r '.bonusPoints // empty')
      if [ -n "$new_pts" ]; then
        points_after="$new_pts"
        current_points="$new_pts"
      fi
      acquire_lock
      state=$(read_state)
      state=$(echo "$state" | jq --argjson p "$updated_profile" '.profile = (.profile // {}) * $p')
      echo "$state" | write_state
      release_lock
      echo "[forager] Profile updated: ${points_after} pts, VIP: $(echo "$updated_profile" | jq -r '.vipUntil // "unknown"')" >&2
    fi
  fi

  # 7-9. Update state: lastSpend, spendHistory, lifetime, nextSpendAt
  local next_at
  next_at=$(next_spend_timestamp)

  # Prune old spend history using shell date (jq strptime is unreliable with %z)
  local cutoff_epoch
  cutoff_epoch=$(($(date +%s) - MAX_SPEND_HISTORY_DAYS * 86400))

  acquire_lock
  state=$(read_state)

  state=$(echo "$state" | jq \
    --arg at "$now" \
    --argjson vip "$vip_purchased" \
    --argjson vault "$vault_entered" \
    --argjson wedge "$wedge_purchased" \
    --argjson gb "$upload_gb" \
    --argjson spent "$total_points_spent" \
    --argjson ptsBefore "$points_before" \
    --argjson ptsAfter "$points_after" \
    --arg trigger "$trigger" \
    --arg nextAt "$next_at" \
    '
    .lastSpend = {
      at: $at,
      vipPurchased: $vip,
      vaultEntered: $vault,
      wedgePurchased: $wedge,
      uploadGbPurchased: $gb,
      pointsSpent: $spent
    } |
    .spendHistory += [{
      at: $at,
      pointsBefore: $ptsBefore,
      pointsAfter: $ptsAfter,
      vipPurchased: $vip,
      vaultEntered: $vault,
      wedgePurchased: $wedge,
      uploadGbPurchased: $gb,
      pointsSpent: $spent,
      trigger: $trigger
    }] |
    .lifetime.totalGbPurchased += $gb |
    .lifetime.totalPointsSpent += $spent |
    .nextSpendAt = $nextAt
  ')

  # Prune old entries using shell date instead of jq strptime
  local pruned_history
  pruned_history=$(echo "$state" | jq -c '.spendHistory[]' | while IFS= read -r entry; do
    local entry_at
    entry_at=$(echo "$entry" | jq -r '.at')
    local entry_epoch
    entry_epoch=$(epoch_from_timestamp "$entry_at")
    if [ "$entry_epoch" -ge "$cutoff_epoch" ]; then
      echo "$entry"
    fi
  done | jq -s '.')
  state=$(echo "$state" | jq --argjson h "$pruned_history" '.spendHistory = $h')

  echo "$state" | write_state
  release_lock

  # Return summary
  jq -n \
    --arg at "$now" \
    --argjson vip "$vip_purchased" \
    --argjson vault "$vault_entered" \
    --argjson wedge "$wedge_purchased" \
    --argjson gb "$upload_gb" \
    --argjson spent "$total_points_spent" \
    --argjson ptsBefore "$points_before" \
    --argjson ptsAfter "$points_after" \
    --arg trigger "$trigger" \
    '{
      at: $at,
      vipPurchased: $vip,
      vaultEntered: $vault,
      wedgePurchased: $wedge,
      uploadGbPurchased: $gb,
      pointsSpent: $spent,
      pointsBefore: $ptsBefore,
      pointsAfter: $ptsAfter,
      trigger: $trigger
    }'
}

# --- Dry Run (simulate spend, no side effects) ---

run_dry_spend() {
  # Ensure we have a valid session
  ensure_session
  if [ $? -ne 0 ]; then
    echo '{"error":"No valid session"}' >&2
    return 1
  fi

  # Fetch fresh profile from MAM
  local profile
  profile=$(fetch_profile)
  if [ -z "$profile" ]; then
    echo '{"error":"Failed to fetch profile"}' >&2
    return 1
  fi

  local bonus_points
  bonus_points=$(echo "$profile" | jq -r '.bonusPoints')

  acquire_lock
  local state
  state=$(read_state)
  release_lock

  local buffer auto_vip vault_mode
  buffer=$(echo "$state" | jq -r '.settings.pointsBuffer // 10000')
  auto_vip=$(echo "$state" | jq -r '.settings.autoVip // false')
  vault_mode=$(echo "$state" | jq -r '.settings.vaultMode // "off"')

  local would_vip="false"
  local vip_reason=""
  local vip_cost=0
  local remaining="$bonus_points"

  # Check VIP
  if [ "$auto_vip" = "true" ]; then
    local vip_until
    vip_until=$(echo "$profile" | jq -r '.vipUntil // empty')
    if [ -n "$vip_until" ]; then
      local vip_epoch now_epoch days_remaining
      vip_epoch=$(date -d "$vip_until" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      days_remaining=$(( (vip_epoch - now_epoch) / 86400 ))
      if [ "$days_remaining" -lt $((VIP_MAX_DAYS - 1)) ]; then
        local days_to_buy=$((VIP_MAX_DAYS - days_remaining))
        vip_cost=$(awk "BEGIN {printf \"%.0f\", $days_to_buy * $VIP_POINTS_PER_4WEEKS / 28}")
        if [ "$vip_cost" -gt 0 ]; then
          would_vip="true"
          vip_reason="VIP has ${days_remaining}d remaining — would buy ${days_to_buy}d for ~${vip_cost} pts"
          remaining=$((remaining - vip_cost))
        else
          vip_reason="VIP has ${days_remaining} days remaining (at cap)"
        fi
      else
        vip_reason="VIP has ${days_remaining} days remaining (within 1d of ${VIP_MAX_DAYS}d cap)"
      fi
    else
      vip_reason="No VIP expiry date found"
    fi
  else
    vip_reason="Auto VIP is disabled"
  fi

  # Check Wedge
  local would_wedge="false"
  local wedge_reason=""
  local wedge_cost_val=0
  local wedge_mode_val
  wedge_mode_val=$(echo "$state" | jq -r '.settings.wedgeMode // "off"')
  if [ "$wedge_mode_val" != "off" ]; then
    if [ "$remaining" -ge "$WEDGE_COST" ]; then
      would_wedge="true"
      wedge_reason="Would buy wedge (${WEDGE_COST} points, mode: ${wedge_mode_val})"
      wedge_cost_val=$WEDGE_COST
      remaining=$((remaining - WEDGE_COST))
    else
      wedge_reason="Not enough points for wedge (need ${WEDGE_COST})"
    fi
  else
    wedge_reason="Wedge buying is disabled"
  fi

  # Check Vault (off / once per pot / daily)
  local would_vault="false"
  local vault_reason=""
  local vault_cost_val=0
  local has_mbsc
  has_mbsc=$(echo "$state" | jq -r '.browserSession.mbsc // empty')
  if [ "$vault_mode" != "off" ] && [ -z "$has_mbsc" ]; then
    vault_reason="Browser session (mbsc) not configured"
  elif [ "$vault_mode" != "off" ]; then
    local should_vault="false"
    local entered
    entered=$(echo "$state" | jq -r '.vault.enteredCurrentPot // false')

    local contributed
    contributed=$(echo "$state" | jq -r '.vault.currentPotContributed // 0')

    if [ "$vault_mode" = "once" ]; then
      if [ "$entered" = "true" ] || [ "$contributed" -gt 0 ] 2>/dev/null; then
        vault_reason="Already entered current pot"
      else
        should_vault="true"
      fi
    elif [ "$vault_mode" = "daily" ]; then
      # Check donatedToday from last vault page scrape if available
      local last_vault_at
      last_vault_at=$(echo "$state" | jq -r '.vault.lastEntryAt // empty')
      if [ -z "$last_vault_at" ]; then
        should_vault="true"
      else
        local vault_epoch
        vault_epoch=$(date -d "$(echo "$last_vault_at" | sed 's/\[.*\]$//')" +%s 2>/dev/null || echo 0)
        if [ $(($(date +%s) - vault_epoch)) -ge $((24 * 3600 - 600)) ]; then
          should_vault="true"
        else
          vault_reason="Already contributed today"
        fi
      fi
    fi
    if [ "$should_vault" = "true" ] && [ "$remaining" -ge "$VAULT_COST" ]; then
      would_vault="true"
      vault_reason="Would donate ${VAULT_COST} points (mode: ${vault_mode})"
      vault_cost_val=$VAULT_COST
      remaining=$((remaining - VAULT_COST))
    elif [ "$should_vault" = "true" ]; then
      vault_reason="Not enough points for vault donation (need ${VAULT_COST})"
    fi
  else
    vault_reason="Vault is disabled"
  fi

  # Calculate upload purchase
  local upload_gb=0 upload_cost=0 upload_reason=""
  local min_spend_gb
  min_spend_gb=$(echo "$state" | jq -r '.settings.minSpendGb // 50')
  # MAM enforces a minimum of 50 GB per API call
  local mam_min_gb=50
  if [ "$min_spend_gb" -lt "$mam_min_gb" ]; then
    min_spend_gb=$mam_min_gb
  fi
  if [ "$min_spend_gb" -eq 0 ]; then
    upload_reason="Upload purchasing disabled"
  elif [ "$wedge_mode_val" = "only" ]; then
    upload_reason="Wedge-only mode, no upload"
  else
    local spendable=$((remaining - buffer))
    local min_spend_pts=$((min_spend_gb * POINTS_PER_GB))
    if [ "$spendable" -ge "$min_spend_pts" ]; then
      upload_gb=$((spendable / POINTS_PER_GB))
      upload_cost=$((upload_gb * POINTS_PER_GB))
    elif [ "$spendable" -ge "$POINTS_PER_GB" ]; then
      upload_reason="Only $((spendable / POINTS_PER_GB)) GB available, below minimum ${min_spend_gb} GB"
    fi
  fi

  local total_cost=$((vip_cost + upload_cost + vault_cost_val + wedge_cost_val))
  local points_after=$((bonus_points - total_cost))

  jq -n \
    --argjson bonusPoints "$bonus_points" \
    --argjson buffer "$buffer" \
    --argjson wouldVip "$would_vip" \
    --arg vipReason "$vip_reason" \
    --argjson wouldWedge "$would_wedge" \
    --arg wedgeReason "$wedge_reason" \
    --argjson wedgeCost "$wedge_cost_val" \
    --argjson wouldVault "$would_vault" \
    --arg vaultReason "$vault_reason" \
    --argjson vaultCost "$vault_cost_val" \
    --argjson uploadGb "$upload_gb" \
    --argjson uploadCost "$upload_cost" \
    --arg uploadReason "$upload_reason" \
    --argjson totalCost "$total_cost" \
    --argjson pointsAfter "$points_after" \
    '{
      dryRun: true,
      bonusPoints: $bonusPoints,
      buffer: $buffer,
      vip: {would: $wouldVip, reason: $vipReason},
      wedge: {would: $wouldWedge, reason: $wedgeReason, cost: $wedgeCost},
      vault: {would: $wouldVault, reason: $vaultReason, cost: $vaultCost},
      upload: {gb: $uploadGb, cost: $uploadCost, reason: $uploadReason},
      totalCost: $totalCost,
      pointsAfter: $pointsAfter
    }'
}

# --- Refresh (stats only, no spending) ---

run_refresh() {
  # Ensure we have a valid session
  ensure_session
  if [ $? -ne 0 ]; then
    echo '{"error":"No valid session"}' >&2
    return 1
  fi

  local profile
  profile=$(fetch_profile)
  if [ -z "$profile" ]; then
    echo '{"error":"Failed to fetch profile"}' >&2
    return 1
  fi

  local points
  points=$(echo "$profile" | jq -r '.bonusPoints')

  acquire_lock
  local state
  state=$(read_state)
  state=$(echo "$state" | jq --argjson p "$profile" '.profile = (.profile // {}) * $p')
  state=$(append_points_history "$state" "$points")
  echo "$state" | write_state
  release_lock

  # Also scrape profile page for points/hour if browser session is available
  local has_mbsc
  has_mbsc=$(echo "$state" | jq -r '.browserSession.mbsc // empty')
  local is_expired
  is_expired=$(echo "$state" | jq -r '.browserSession.expired // false')
  if [ -n "$has_mbsc" ] && [ "$is_expired" != "true" ]; then
    refresh_profile_page 2>&1 >/dev/null
  fi

  # Return profile with points/hour from state
  state=$(read_state)
  echo "$state" | jq '.profile'
}

# --- CGI helpers ---

read_body() {
  if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
    head -c "$CONTENT_LENGTH"
  fi
}

respond() {
  local status="${1:-200}"
  local body="$2"
  printf "Status: %s\r\n" "$status"
  printf "Content-Type: application/json\r\n"
  printf "Access-Control-Allow-Origin: *\r\n"
  printf "Access-Control-Allow-Methods: GET, PUT, POST, OPTIONS\r\n"
  printf "Access-Control-Allow-Headers: Content-Type\r\n"
  printf "\r\n"
  printf "%s" "$body"
}

handle_cors() {
  if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    respond "204"
    exit 0
  fi
}
