#!/bin/sh
. /app/lib.sh
handle_cors
check_auth
# Clear session
rm -f /var/run/forager/session_token
printf "Status: 200\r\n"
printf "Content-Type: application/json\r\n"
printf "Set-Cookie: forager_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0\r\n"
printf "Access-Control-Allow-Origin: *\r\n"
printf "\r\n"
printf '{"ok":true}'
