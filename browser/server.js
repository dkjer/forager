const http = require('http');
const { chromium } = require('playwright');

const MAM_BASE = process.env.MAM_BASE || 'https://www.myanonamouse.net';
const PORT = parseInt(process.env.BROWSER_PORT || '5012');

let browserCtx = null;
let browserObj = null;
let loggedIn = false;
let busy = false;

async function ensureBrowser() {
  if (browserCtx) return;
  browserObj = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage']
  });
  browserCtx = await browserObj.newContext({
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36'
  });
  console.error('[browser] Chromium started');
}

async function doLogin(email, password) {
  await ensureBrowser();
  const page = await browserCtx.newPage();
  try {
    await page.goto(`${MAM_BASE}/login.php`, { waitUntil: 'networkidle', timeout: 30000 });
    await page.fill('input[name="email"]', email);
    await page.fill('input[name="password"]', password);
    await page.check('input[name="rememberMe"]');
    await page.click('input[type="submit"]');
    await page.waitForLoadState('networkidle', { timeout: 30000 });

    const url = page.url();
    if (url.includes('login.php') || url.includes('takelogin.php')) {
      const body = await page.content();
      if (body.toLowerCase().includes('locked'))
        return { ok: false, error: 'Account locked — too many attempts' };
      return { ok: false, error: `Login failed, stuck at ${url}` };
    }

    loggedIn = true;
    console.error(`[browser] Logged in, redirected to ${url}`);
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message };
  } finally {
    await page.close();
  }
}

async function doFetch(path, postData) {
  if (!loggedIn) return { status: 0, error: 'Not logged in', body: '', url: '' };

  await ensureBrowser();
  const page = await browserCtx.newPage();
  try {
    const url = `${MAM_BASE}${path}`;

    if (postData) {
      // Intercept the navigation request and convert it to a POST
      await page.route(url, (route) => {
        route.continue({
          method: 'POST',
          headers: {
            ...route.request().headers(),
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          postData: postData,
        });
      });
    }

    const resp = await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
    const finalUrl = page.url();
    const body = await page.content();

    if (finalUrl.includes('login.php')) {
      loggedIn = false;
      return { status: 302, body: '', url: finalUrl, error: 'Session expired — login required' };
    }

    return { status: resp ? resp.status() : 0, body, url: finalUrl };
  } catch (e) {
    return { status: 0, body: '', url: '', error: e.message };
  } finally {
    await page.close();
  }
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', c => data += c);
    req.on('end', () => resolve(data));
  });
}

const server = http.createServer(async (req, res) => {
  const respond = (code, obj) => {
    const body = JSON.stringify(obj);
    res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
    res.end(body);
  };

  if (req.method === 'GET' && req.url === '/health') {
    return respond(200, { ok: true, logged_in: loggedIn });
  }

  if (req.method !== 'POST') return respond(404, { error: 'Not found' });

  const raw = await readBody(req);
  let data = {};
  try { data = JSON.parse(raw); } catch {}

  if (req.url === '/login') {
    if (!data.email || !data.password)
      return respond(400, { ok: false, error: 'email and password required' });
    if (busy) return respond(429, { ok: false, error: 'Browser is busy' });
    busy = true;
    try {
      const result = await doLogin(data.email, data.password);
      respond(200, result);
    } finally { busy = false; }
  } else if (req.url === '/fetch') {
    if (!data.path) return respond(400, { error: 'path required' });
    if (busy) return respond(429, { error: 'Browser is busy' });
    busy = true;
    try {
      const result = await doFetch(data.path, data.postData || null);
      respond(200, result);
    } finally { busy = false; }
  } else {
    respond(404, { error: 'Not found' });
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.error(`[browser] Listening on :${PORT}`);
});
