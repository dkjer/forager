#!/bin/sh
# Background spender — runs spend cycle on configured interval
. /app/lib.sh

KEEPALIVE_INTERVAL=14400  # 4 hours — keep mbsc session alive

echo "[spender] Starting background spender"

last_keepalive=0

while true; do
  # Read interval from state (may change at runtime)
  interval_hours=$(read_state | jq -r '.settings.spendIntervalHours // 24')
  interval_secs=$((interval_hours * 3600))

  # Update next spend time
  next_at=$(next_spend_timestamp)
  acquire_lock
  state=$(read_state)
  echo "$state" | jq --arg at "$next_at" '.nextSpendAt = $at' | write_state
  release_lock

  echo "[spender] Next spend in ${interval_hours}h (${interval_secs}s)"

  # Sleep in chunks so we can run keepalives between spend cycles
  elapsed=0
  while [ "$elapsed" -lt "$interval_secs" ]; do
    # Sleep in 1-hour chunks
    chunk=3600
    remaining=$((interval_secs - elapsed))
    if [ "$chunk" -gt "$remaining" ]; then
      chunk=$remaining
    fi
    sleep "$chunk"
    elapsed=$((elapsed + chunk))

    # Periodic mbsc keepalive: hit vault page to rotate cookie
    now_epoch=$(date +%s)
    since_keepalive=$((now_epoch - last_keepalive))
    if [ "$since_keepalive" -ge "$KEEPALIVE_INTERVAL" ]; then
      state=$(read_state)
      has_mbsc=$(echo "$state" | jq -r '.browserSession.mbsc // empty')
      is_expired=$(echo "$state" | jq -r '.browserSession.expired // false')
      if [ -n "$has_mbsc" ] && [ "$is_expired" != "true" ]; then
        echo "[spender] Keepalive: refreshing browser session..." >&2
        load_browser_session

        # Scrape profile page for points/hour stats (also rotates mbsc)
        refresh_profile_page 2>&1

        # Also refresh vault stats
        vault_mode=$(echo "$state" | jq -r '.settings.vaultMode // "off"')
        if [ "$vault_mode" != "off" ]; then
          keepalive_html=$(mam_html_request "/millionaires/pot.php")
          rc=$?
          if [ $rc -eq 0 ]; then
            vault_info=$(parse_vault_page "$keepalive_html" 2>/dev/null)
            if [ -n "$vault_info" ]; then
              pot_amount=$(echo "$vault_info" | jq -r '.potAmount')
              pot_max=$(echo "$vault_info" | jq -r '.potMax')
              user_total=$(echo "$vault_info" | jq -r '.userTotalDonated')
              start_date=$(echo "$vault_info" | jq -r '.startDate // empty')
              acquire_lock
              state=$(read_state)
              pot_id="$start_date"
              current_pot_id=$(echo "$state" | jq -r '.vault.currentPotId // empty')
              if [ -n "$pot_id" ] && [ "$pot_id" != "$current_pot_id" ]; then
                state=$(echo "$state" | jq --arg pid "$pot_id" '
                  .vault.currentPotId = $pid |
                  .vault.enteredCurrentPot = false |
                  .vault.currentPotContributed = 0
                ')
              fi
              state=$(echo "$state" | jq --argjson amt "${pot_amount:-0}" --argjson max "${pot_max:-20000000}" '
                .vault.currentPotAmount = $amt | .vault.potMax = $max
              ')
              if [ -n "$start_date" ]; then
                state=$(echo "$state" | jq --arg sd "$start_date" '.vault.potStartDate = $sd')
              fi
              if [ "$user_total" != "0" ] && [ -n "$user_total" ]; then
                state=$(echo "$state" | jq --argjson d "$user_total" '
                  .vault.currentPotContributed = $d | .vault.enteredCurrentPot = true
                ')
              fi
              echo "$state" | write_state
              release_lock
            fi
          fi
        fi

        echo "[spender] Keepalive complete" >&2
        last_keepalive=$(date +%s)
      fi
    fi
  done

  # Check if paused
  is_paused=$(read_state | jq -r '.paused // false')
  if [ "$is_paused" = "true" ]; then
    echo "[spender] Paused, skipping spend cycle"
    continue
  fi

  if ! ensure_session; then
    echo "[spender] No valid session, skipping spend cycle"
    continue
  fi

  echo "[spender] Running scheduled spend cycle..."
  result=$(run_spend "scheduled" 2>&1)
  echo "[spender] Result: $result"
done
