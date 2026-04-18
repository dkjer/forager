#!/bin/sh
. /app/lib.sh

# Login is always accessible (no auth check)
handle_cors

if [ "$REQUEST_METHOD" = "POST" ]; then
  body=$(read_body)
  user=$(echo "$body" | jq -r '.username // empty')
  pass=$(echo "$body" | jq -r '.password // empty')

  expected_user="${FORAGER_USER:-}"
  expected_pass="${FORAGER_PASS:-}"

  if [ -z "$expected_user" ]; then
    # No auth configured — shouldn't reach here, but allow
    respond "200" '{"ok":true}'
    exit 0
  fi

  if [ "$user" = "$expected_user" ] && [ "$pass" = "$expected_pass" ]; then
    # Generate session token
    token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    # Save token to session file
    echo "$token" > /var/run/forager/session_token
    # Return token as cookie
    printf "Status: 200\r\n"
    printf "Content-Type: application/json\r\n"
    printf "Set-Cookie: forager_session=%s; Path=/; HttpOnly; SameSite=Lax; Secure; Max-Age=2592000\r\n" "$token"
    printf "Access-Control-Allow-Origin: *\r\n"
    printf "\r\n"
    printf '{"ok":true}'
  else
    respond "401" '{"ok":false,"error":"Invalid credentials"}'
  fi
elif [ "$REQUEST_METHOD" = "GET" ]; then
  # Return auth status
  if [ -z "${FORAGER_USER:-}" ]; then
    respond "200" '{"authRequired":false}'
  else
    respond "200" '{"authRequired":true}'
  fi
else
  respond "405" '{"error":"Method not allowed"}'
fi
