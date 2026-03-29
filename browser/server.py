#!/usr/bin/env python3
"""Headless browser service for MAM HTML page fetching.

Runs a simple HTTP server that accepts requests to fetch MAM pages
using a real Chromium browser, bypassing TLS fingerprint detection.

Endpoints:
  POST /fetch  — fetch a MAM page (requires active session)
    Body: {"path": "/millionaires/pot.php"}
    Returns: {"status": 200, "body": "...", "url": "..."}

  POST /login  — log in to MAM and establish a session
    Body: {"email": "...", "password": "..."}
    Returns: {"ok": true} or {"ok": false, "error": "..."}

  GET /health  — health check
    Returns: {"ok": true, "logged_in": bool}
"""

import json
import os
import sys
import asyncio
from http.server import HTTPServer, BaseHTTPRequestHandler
from playwright.async_api import async_playwright

MAM_BASE = os.environ.get('MAM_BASE', 'https://www.myanonamouse.net')
LISTEN_PORT = int(os.environ.get('BROWSER_PORT', '5012'))

# Global browser state
browser_ctx = None
playwright_obj = None
browser_obj = None
logged_in = False
lock = asyncio.Lock()
loop = None


async def ensure_browser():
    global playwright_obj, browser_obj, browser_ctx
    if browser_ctx is not None:
        return
    playwright_obj = await async_playwright().start()
    browser_obj = await playwright_obj.chromium.launch(
        headless=True,
        args=['--no-sandbox', '--disable-dev-shm-usage']
    )
    browser_ctx = await browser_obj.new_context(
        user_agent='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                   'AppleWebKit/537.36 (KHTML, like Gecko) '
                   'Chrome/146.0.0.0 Safari/537.36'
    )
    print('[browser] Chromium started', file=sys.stderr, flush=True)


async def do_login(email, password):
    global logged_in
    async with lock:
        await ensure_browser()
        page = await browser_ctx.new_page()
        try:
            await page.goto(f'{MAM_BASE}/login.php', wait_until='networkidle', timeout=30000)

            # Fill and submit login form
            await page.fill('input[name="email"]', email)
            await page.fill('input[name="password"]', password)
            await page.check('input[name="rememberMe"]')
            await page.click('input[type="submit"]')
            await page.wait_for_load_state('networkidle', timeout=30000)

            # Check if login succeeded (should redirect away from login page)
            url = page.url
            if 'login.php' in url or 'takelogin.php' in url:
                body = await page.content()
                if 'error' in body.lower() or 'incorrect' in body.lower():
                    return {'ok': False, 'error': 'Invalid credentials'}
                if 'locked' in body.lower():
                    return {'ok': False, 'error': 'Account locked — too many attempts'}
                return {'ok': False, 'error': f'Login failed, stuck at {url}'}

            logged_in = True
            print(f'[browser] Logged in, redirected to {url}', file=sys.stderr, flush=True)
            return {'ok': True}
        except Exception as e:
            return {'ok': False, 'error': str(e)}
        finally:
            await page.close()


async def do_fetch(path):
    global logged_in
    async with lock:
        if not logged_in:
            return {'status': 0, 'error': 'Not logged in', 'body': '', 'url': ''}

        await ensure_browser()
        page = await browser_ctx.new_page()
        try:
            url = f'{MAM_BASE}{path}'
            resp = await page.goto(url, wait_until='networkidle', timeout=30000)
            final_url = page.url
            body = await page.content()

            # Detect login redirect
            if 'login.php' in final_url:
                logged_in = False
                return {'status': 302, 'body': '', 'url': final_url,
                        'error': 'Session expired — login required'}

            return {
                'status': resp.status if resp else 0,
                'body': body,
                'url': final_url
            }
        except Exception as e:
            return {'status': 0, 'body': '', 'url': '', 'error': str(e)}
        finally:
            await page.close()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default access logs

    def _json_response(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get('Content-Length', 0))
        return json.loads(self.rfile.read(length)) if length else {}

    def do_GET(self):
        if self.path == '/health':
            self._json_response(200, {'ok': True, 'logged_in': logged_in})
        else:
            self._json_response(404, {'error': 'Not found'})

    def do_POST(self):
        data = self._read_json()

        if self.path == '/login':
            email = data.get('email', '')
            password = data.get('password', '')
            if not email or not password:
                self._json_response(400, {'ok': False, 'error': 'email and password required'})
                return
            result = loop.run_until_complete(do_login(email, password))
            self._json_response(200, result)

        elif self.path == '/fetch':
            path = data.get('path', '')
            if not path:
                self._json_response(400, {'error': 'path required'})
                return
            result = loop.run_until_complete(do_fetch(path))
            self._json_response(200, result)

        else:
            self._json_response(404, {'error': 'Not found'})


def main():
    global loop
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    server = HTTPServer(('0.0.0.0', LISTEN_PORT), Handler)
    print(f'[browser] Listening on :{LISTEN_PORT}', file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if browser_obj:
            loop.run_until_complete(browser_obj.close())
        if playwright_obj:
            loop.run_until_complete(playwright_obj.stop())


if __name__ == '__main__':
    main()
