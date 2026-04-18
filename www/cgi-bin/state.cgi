#!/bin/sh
. /app/lib.sh
handle_cors
check_auth

version="$FORAGER_VERSION"

if [ "$REQUEST_METHOD" = "PUT" ]; then
  body=$(read_body)

  acquire_lock
  state=$(read_state)

  # Update cookie if provided
  new_cookie=$(echo "$body" | jq -r '.currentCookie // empty')
  if [ -n "$new_cookie" ]; then
    state=$(echo "$state" | jq --arg c "$new_cookie" '.currentCookie = $c')
  fi

  # Merge settings if provided
  new_settings=$(echo "$body" | jq -r '.settings // empty')
  if [ -n "$new_settings" ] && [ "$new_settings" != "" ]; then
    state=$(echo "$state" | jq --argjson s "$(echo "$body" | jq '.settings')" '
      .settings = (.settings // {}) * $s
    ')
  fi

  # Merge browserSession if provided
  new_browser=$(echo "$body" | jq -r '.browserSession // empty')
  if [ -n "$new_browser" ] && [ "$new_browser" != "" ]; then
    state=$(echo "$state" | jq --argjson b "$(echo "$body" | jq '.browserSession')" '
      .browserSession = (.browserSession // {}) * $b
    ')
  fi

  # Merge sessionStatus if provided
  new_session_status=$(echo "$body" | jq -r '.sessionStatus // empty')
  if [ -n "$new_session_status" ] && [ "$new_session_status" != "" ]; then
    state=$(echo "$state" | jq --argjson ss "$(echo "$body" | jq '.sessionStatus')" '
      .sessionStatus = (.sessionStatus // {}) * $ss
    ')
  fi

  # Update paused if provided (can't use // empty since false is falsy in jq)
  has_paused=$(echo "$body" | jq 'has("paused")')
  if [ "$has_paused" = "true" ]; then
    new_paused=$(echo "$body" | jq '.paused')
    state=$(echo "$state" | jq --argjson p "$new_paused" '.paused = $p')
  fi

  echo "$state" | write_state
  state=$(read_state)
  release_lock

  # Return full state with computed fields + simulation
  points_per_hour=$(calc_points_per_hour "$state")
  simulation=$(calc_simulation "$state")

  result=$(echo "$state" | jq \
    --argjson pph "$points_per_hour" \
    --argjson sim "$simulation" \
    --arg ver "$version" \
    '. + {pointsPerHour: $pph, simulation: $sim, version: $ver}')
  respond "200" "$result"
else
  # GET
  acquire_lock
  state=$(read_state)
  release_lock

  points_per_hour=$(calc_points_per_hour "$state")
  simulation=$(calc_simulation "$state")

  result=$(echo "$state" | jq \
    --argjson pph "$points_per_hour" \
    --argjson sim "$simulation" \
    --arg ver "$version" \
    '. + {pointsPerHour: $pph, simulation: $sim, version: $ver}')
  respond "200" "$result"
fi
