#!/bin/sh
. /app/lib.sh
handle_cors
if [ "$REQUEST_METHOD" = "POST" ]; then
  send_notification "Forager: Test" "Notifications are working!" "default" "bell"
  respond "200" '{"ok":true}'
else
  respond "405" '{"error":"Method not allowed"}'
fi
