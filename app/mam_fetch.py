#!/usr/bin/env python3
"""Fetch MAM HTML pages using urllib (bypasses TLS fingerprint detection that blocks curl)."""
import sys
import urllib.request
import urllib.error
import json

def main():
    url = sys.argv[1]
    cookie = sys.argv[2]  # mbsc cookie value
    ua = sys.argv[3]
    post_data = sys.argv[4] if len(sys.argv) > 4 else None

    req = urllib.request.Request(url)
    req.add_header('User-Agent', ua)
    req.add_header('Cookie', f'mbsc={cookie}')

    if post_data:
        req.data = post_data.encode()

    try:
        resp = urllib.request.urlopen(req, timeout=15)
        body = resp.read().decode('utf-8', errors='replace')

        # Extract rotated mbsc from Set-Cookie headers
        new_mbsc = None
        for header, value in resp.headers.items():
            if header.lower() == 'set-cookie' and 'mbsc=' in value:
                part = value.split('mbsc=')[1].split(';')[0]
                if part != 'deleted':
                    new_mbsc = part
                elif part == 'deleted':
                    new_mbsc = 'deleted'

        result = {
            'status': resp.status,
            'body': body,
            'mbsc': new_mbsc
        }
    except urllib.error.HTTPError as e:
        result = {
            'status': e.code,
            'body': '',
            'mbsc': None
        }
    except Exception as e:
        result = {
            'status': 0,
            'body': '',
            'mbsc': None,
            'error': str(e)
        }

    json.dump(result, sys.stdout)

if __name__ == '__main__':
    main()
