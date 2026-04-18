#!/bin/sh
. /app/lib.sh
handle_cors
check_auth

if [ "$REQUEST_METHOD" != "POST" ]; then
  respond "405" '{"error":"POST required"}'
  exit 0
fi

result=$(run_dry_spend 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$result" ]; then
  respond "502" '{"error":"Dry run failed"}'
  exit 0
fi

respond "200" "$result"
