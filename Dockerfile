FROM alpine:3.21

RUN apk add --no-cache curl jq lighttpd lighttpd-mod_auth tzdata shunit2 python3

COPY VERSION /app/VERSION
COPY app/ /app/
COPY www/ /www/

RUN chmod +x /app/*.sh /www/cgi-bin/*.cgi

EXPOSE 5011

ENTRYPOINT ["/app/entrypoint.sh"]
