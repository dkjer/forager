#!/bin/sh
# Background spender — runs spend cycle on configured interval
. /app/lib.sh

KEEPALIVE_INTERVAL=14400  # 4 hours — keep mbsc session alive

echo "[spender] Starting background spender"

# Refresh balance immediately on startup
if ensure_session 2>/dev/null; then
  startup_profile=$(fetch_profile 2>/dev/null)
  if [ -n "$startup_profile" ]; then
    startup_pts=$(echo "$startup_profile" | jq -r '.bonusPoints')
    acquire_lock
    state=$(read_state)
    state=$(echo "$state" | jq --argjson p "$startup_profile" '.profile = (.profile // {}) * $p')
    state=$(append_points_history "$state" "$startup_pts")
    echo "$state" | write_state
    release_lock
    echo "[spender] Startup: balance refreshed (${startup_pts} pts)"
  fi
else
  echo "[spender] Startup: no valid session"
fi

last_keepalive=0

while true; do
  # Read interval from state (may change at runtime)
  interval_hours=$(read_state | jq -r '.settings.spendIntervalHours // 24')
  interval_secs=$((interval_hours * 3600))

  # Compute next spend time based on lastSpend.at (survives restarts)
  next_at=$(next_spend_timestamp)
  acquire_lock
  state=$(read_state)
  echo "$state" | jq --arg at "$next_at" '.nextSpendAt = $at' | write_state
  release_lock

  # Calculate actual sleep time (may be less than full interval after restart)
  next_epoch=$(epoch_from_timestamp "$next_at")
  now_epoch=$(date +%s)
  sleep_secs=$((next_epoch - now_epoch))
  if [ "$sleep_secs" -lt 0 ]; then
    sleep_secs=0
  fi

  echo "[spender] Next spend in $(( sleep_secs / 3600 ))h$(( (sleep_secs % 3600) / 60 ))m (${sleep_secs}s)"

  # Sleep in chunks so we can run keepalives between spend cycles
  elapsed=0
  while [ "$elapsed" -lt "$sleep_secs" ]; do
    # Sleep in 1-hour chunks
    chunk=3600
    remaining=$((sleep_secs - elapsed))
    if [ "$chunk" -gt "$remaining" ]; then
      chunk=$remaining
    fi
    sleep "$chunk"
    elapsed=$((elapsed + chunk))

    # Periodic keepalive: refresh balance, mbsc session, vault stats
    now_epoch=$(date +%s)
    since_keepalive=$((now_epoch - last_keepalive))
    if [ "$since_keepalive" -ge "$KEEPALIVE_INTERVAL" ]; then
      # Always refresh bonus points via JSON API
      if ensure_session 2>/dev/null; then
        keepalive_profile=$(fetch_profile 2>/dev/null)
        if [ -n "$keepalive_profile" ]; then
          keepalive_pts=$(echo "$keepalive_profile" | jq -r '.bonusPoints')
          acquire_lock
          state=$(read_state)
          state=$(echo "$state" | jq --argjson p "$keepalive_profile" '.profile = (.profile // {}) * $p')
          state=$(append_points_history "$state" "$keepalive_pts")
          echo "$state" | write_state
          release_lock
          echo "[spender] Keepalive: balance refreshed (${keepalive_pts} pts)" >&2
        fi
      fi

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

        echo "[spender] Keepalive: browser session complete" >&2
      fi
      last_keepalive=$(date +%s)
    fi
  done

  # Check if paused
  is_paused=$(read_state | jq -r '.paused // false')
  if [ "$is_paused" = "true" ]; then
    echo "[spender] Paused, skipping spend cycle"
    continue
  fi

  was_invalid=$(read_state | jq -r '.sessionStatus.valid == false')
  if ! ensure_session; then
    echo "[spender] No valid session, skipping spend cycle"
    send_notification "Forager: Session Expired" \
      "Cookie rejected — open forager.kjer.io to paste a fresh mam_id cookie" \
      "high" "warning"
    # Sleep full interval before retrying (don't spin in tight loop)
    sleep "$interval_secs"
    continue
  fi

  # If session was previously invalid but now recovered, notify
  if [ "$was_invalid" = "true" ]; then
    send_notification "Forager: Session Restored" \
      "Cookie is working again. Resuming spend cycles." \
      "default" "white_check_mark"
  fi

  echo "[spender] Running scheduled spend cycle..."
  result=$(run_spend "scheduled" 2>&1)
  echo "[spender] Result: $result"
  gb=$(echo "$result" | jq -r '.uploadGbPurchased // 0' 2>/dev/null)
  pts=$(echo "$result" | jq -r '.pointsSpent // 0' 2>/dev/null)
  if [ "${pts:-0}" -gt 0 ]; then
    send_notification "Forager: Spend Complete" \
      "Purchased ${gb}GB upload for ${pts} pts" \
      "low" "moneybag"
  fi
done
