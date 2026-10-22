const assert = require("assert");
const fs = require("fs");
const http = require("http");
const path = require("path");
const { chromium } = require("playwright");

const root = path.resolve(__dirname, "..");
const port = 8767;
const baseUrl = `http://127.0.0.1:${port}`;

function contentType(file){
  const ext = path.extname(file);
  if(ext === ".html") return "text/html; charset=utf-8";
  if(ext === ".js") return "text/javascript; charset=utf-8";
  if(ext === ".css") return "text/css; charset=utf-8";
  return "application/octet-stream";
}

const server = http.createServer((request, response) => {
  const pathname = decodeURIComponent(new URL(request.url, baseUrl).pathname);
  const relative = pathname === "/" ? "index.html" : pathname.replace(/^\//, "");
  const file = path.resolve(root, relative);
  if(!file.startsWith(root + path.sep)){
    response.writeHead(403).end();
    return;
  }
  fs.readFile(file, (error, data) => {
    if(error){
      response.writeHead(404).end("Not found");
      return;
    }
    response.setHeader("Content-Type", contentType(file));
    response.end(data);
  });
});

async function seedSession(page, values){
  await page.addInitScript(session => {
    localStorage.setItem("dp_session_token", session.token);
    localStorage.setItem("dp_role", session.role);
    localStorage.setItem("dp_display_name", session.name);
    localStorage.setItem("dp_user_id", session.userId);
    localStorage.setItem("dp_expires_at", session.expiresAt);
  }, values);
}

async function mockSupabase(page, sessionRow, options = {}){
  await page.route("https://rewdmcyqxyzcoeiikoow.supabase.co/rest/v1/rpc/**", async route => {
    if(options.abort){
      await route.abort("failed");
      return;
    }
    const name = route.request().url().split("/").pop();
    const payload = name === "rpc_session_touch" ? (sessionRow ? [sessionRow] : []) : [];
    await route.fulfill({ status:200, contentType:"application/json", body:JSON.stringify(payload) });
  });
}

(async () => {
  await new Promise(resolve => server.listen(port, "127.0.0.1", resolve));
  const browser = await chromium.launch({
    headless:true,
    executablePath: process.env.PLAYWRIGHT_BROWSER_PATH || "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"
  });
  try{
    const noSession = await browser.newPage();
    await noSession.goto(`${baseUrl}/dashboard.html`);
    await noSession.waitForURL(`${baseUrl}/index.html`);
    assert.strictEqual(await noSession.locator("#app_session_guard").count(), 0);
    await noSession.close();

    const valid = await browser.newPage();
    const renewedExpiry = new Date(Date.now() + (30 * 60 * 1000)).toISOString();
    await seedSession(valid, {
      token:"valid-token",
      role:"admin",
      name:"Admin",
      userId:"11111111-1111-1111-1111-111111111111",
      expiresAt:"2020-01-01T00:00:00.000Z"
    });
    await mockSupabase(valid, {
      session_id:"22222222-2222-2222-2222-222222222222",
      user_id:"11111111-1111-1111-1111-111111111111",
      display_name:"Admin",
      role:"admin",
      expires_at:renewedExpiry
    });
    await valid.goto(`${baseUrl}/dashboard.html`);
    await valid.locator("html:not(.app-session-pending):not(.app-session-locked)").waitFor();
    assert.strictEqual(await valid.locator(".app-admin-nav").count(), 1);
    assert.strictEqual(await valid.evaluate(() => localStorage.getItem("dp_expires_at")), renewedExpiry);
    await valid.close();

    const roleRedirect = await browser.newPage();
    await seedSession(roleRedirect, {
      token:"admin-on-dispatch",
      role:"admin",
      name:"Admin",
      userId:"11111111-1111-1111-1111-111111111111",
      expiresAt:renewedExpiry
    });
    await mockSupabase(roleRedirect, {
      session_id:"22222222-2222-2222-2222-222222222222",
      user_id:"11111111-1111-1111-1111-111111111111",
      display_name:"Admin",
      role:"admin",
      expires_at:renewedExpiry
    });
    await roleRedirect.goto(`${baseUrl}/dispatch.html`);
    await roleRedirect.waitForURL(`${baseUrl}/catalog.html`);
    await roleRedirect.locator("html:not(.app-session-pending):not(.app-session-locked)").waitFor();
    await roleRedirect.close();

    const rejected = await browser.newPage();
    await seedSession(rejected, {
      token:"expired-token",
      role:"admin",
      name:"Admin",
      userId:"11111111-1111-1111-1111-111111111111",
      expiresAt:"2099-01-01T00:00:00.000Z"
    });
    await mockSupabase(rejected, null);
    await rejected.goto(`${baseUrl}/dashboard.html`);
    await rejected.waitForURL(`${baseUrl}/index.html`);
    assert.strictEqual(await rejected.evaluate(() => localStorage.getItem("dp_session_token")), null);
    await rejected.close();

    const offline = await browser.newPage();
    await seedSession(offline, {
      token:"offline-token",
      role:"admin",
      name:"Admin",
      userId:"11111111-1111-1111-1111-111111111111",
      expiresAt:"2099-01-01T00:00:00.000Z"
    });
    await mockSupabase(offline, null, { abort:true });
    await offline.goto(`${baseUrl}/dashboard.html`);
    await offline.locator("html.app-session-locked").waitFor();
    assert.strictEqual(await offline.locator("#app_session_retry").isVisible(), true);
    assert.strictEqual(await offline.locator(".app-admin-nav").count(), 0);
    assert.strictEqual(await offline.evaluate(() => localStorage.getItem("dp_session_token")), "offline-token");
    await offline.close();

    const timedExpiry = await browser.newPage();
    await seedSession(timedExpiry, {
      token:"short-session-token",
      role:"dispatch",
      name:"Despacho",
      userId:"33333333-3333-3333-3333-333333333333",
      expiresAt:new Date(Date.now() + 5000).toISOString()
    });
    let touchCount = 0;
    await timedExpiry.route("https://rewdmcyqxyzcoeiikoow.supabase.co/rest/v1/rpc/**", async route => {
      const name = route.request().url().split("/").pop();
      if(name !== "rpc_session_touch"){
        await route.fulfill({ status:200, contentType:"application/json", body:"[]" });
        return;
      }
      touchCount += 1;
      const payload = touchCount === 1 ? [{
        session_id:"44444444-4444-4444-4444-444444444444",
        user_id:"33333333-3333-3333-3333-333333333333",
        display_name:"Despacho",
        role:"dispatch",
        expires_at:new Date(Date.now() + 200).toISOString()
      }] : [];
      await route.fulfill({ status:200, contentType:"application/json", body:JSON.stringify(payload) });
    });
    await timedExpiry.goto(`${baseUrl}/dispatch-menu.html`);
    await timedExpiry.locator("html:not(.app-session-pending):not(.app-session-locked)").waitFor();
    await timedExpiry.waitForURL(`${baseUrl}/index.html`, { timeout:3000 });
    assert(touchCount >= 2, "expiration timer must revalidate with the server");
    await timedExpiry.close();

    const publicPage = await browser.newPage();
    await publicPage.goto(`${baseUrl}/availability.html`);
    assert.strictEqual(publicPage.url(), `${baseUrl}/availability.html`);
    assert.strictEqual(await publicPage.locator("#app_session_guard").count(), 0);
    await publicPage.close();

    const publicWithSession = await browser.newPage();
    await seedSession(publicWithSession, {
      token:"public-valid-token",
      role:"admin",
      name:"Admin",
      userId:"11111111-1111-1111-1111-111111111111",
      expiresAt:"2020-01-01T00:00:00.000Z"
    });
    await mockSupabase(publicWithSession, {
      session_id:"22222222-2222-2222-2222-222222222222",
      user_id:"11111111-1111-1111-1111-111111111111",
      display_name:"Admin",
      role:"admin",
      expires_at:renewedExpiry
    });
    await publicWithSession.goto(`${baseUrl}/availability.html`);
    await publicWithSession.locator("#session_user:not(.d-none)").waitFor();
    assert.strictEqual(publicWithSession.url(), `${baseUrl}/availability.html`);
    assert.strictEqual(await publicWithSession.evaluate(() => localStorage.getItem("dp_expires_at")), renewedExpiry);
    await publicWithSession.close();

    console.log("session guard smoke: renewal, role routing, timed expiry, rejection, offline lock and public session sync OK");
  }finally{
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => {
  console.error(error);
  server.close(() => process.exit(1));
});
