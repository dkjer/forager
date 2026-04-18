#!/bin/sh
. /app/lib.sh
handle_cors
check_auth

acquire_lock
state=$(read_state)
release_lock

result=$(echo "$state" | jq '{spendHistory: (.spendHistory // [])}')
respond "200" "$result"
