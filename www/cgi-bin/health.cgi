#!/bin/sh
. /app/lib.sh
handle_cors
respond "200" "{\"ok\":true,\"version\":\"${FORAGER_VERSION}\"}"
