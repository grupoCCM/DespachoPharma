const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const protectedPages = {
  "dashboard.html": ["admin"],
  "imports.html": ["admin"],
  "purchasing.html": ["admin"],
  "expiration-dashboard.html": ["admin"],
  "inventory-audit.html": ["admin", "dispatch", "cashier"],
  "catalog.html": ["admin"],
  "history.html": ["admin"],
  "device-inventory.html": ["admin"],
  "cashier.html": ["cashier", "admin"],
  "dispatch.html": ["dispatch"],
  "dispatch-menu.html": ["dispatch"],
  "device-dispatch.html": ["dispatch"]
};

for(const [file, roles] of Object.entries(protectedPages)){
  const html = fs.readFileSync(path.join(root, file), "utf8");
  const bodyMatch = html.match(/<body\b[^>]*data-session-roles="([^"]+)"[^>]*>/i);
  assert(bodyMatch, `${file}: falta data-session-roles`);
  assert.deepStrictEqual(bodyMatch[1].split(","), roles, `${file}: roles inesperados`);

  const guardMatch = html.match(/<script src="app-session\.js\?v=\d+-\d+"><\/script>/i);
  assert(guardMatch, `${file}: falta la versión publicada del guard de sesión`);
  const guardIndex = guardMatch.index;
  const navIndex = html.indexOf('<script src="app-nav.js"></script>');
  assert(guardIndex > bodyMatch.index, `${file}: el guard debe cargarse al inicio del body`);
  if(navIndex >= 0){
    assert(guardIndex < navIndex, `${file}: el guard debe cargarse antes de la navegación`);
  }
  assert(
    html.includes("window.AppSession.requireSession"),
    `${file}: init debe esperar la validación central`
  );
}

for(const file of ["index.html", "availability.html"]){
  const html = fs.readFileSync(path.join(root, file), "utf8");
  assert(!html.includes('src="app-session.js"'), `${file}: la pantalla pública no debe bloquearse`);
}

const nav = fs.readFileSync(path.join(root, "app-nav.js"), "utf8");
assert(nav.includes("window.AppSession.ready.then(renderNav)"), "app-nav.js debe esperar session-ready");

console.log(`session guard: ${Object.keys(protectedPages).length} protected pages OK`);
