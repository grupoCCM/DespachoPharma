(function(){
  "use strict";

  const host = document.querySelector("[data-app-nav]");
  if(!host) return;

  const active = host.getAttribute("data-active") || "";
  const role = String(localStorage.getItem("dp_role") || "").toLowerCase();
  const isOperations = host.getAttribute("data-mode") === "auto" && role !== "admin";

  const item = (href, label, key, extraClass) => {
    const selected = active === key;
    const classes = ["app-nav-link", extraClass || "", selected ? "is-active" : ""].filter(Boolean).join(" ");
    return `<a class="${classes}" href="${href}"${selected ? ' aria-current="page"' : ""}>${label}</a>`;
  };

  const group = (label, keys, links) => {
    const selected = keys.includes(active);
    return `<details class="app-nav-menu">
      <summary class="app-nav-summary${selected ? " is-active" : ""}">${label}</summary>
      <div class="app-nav-dropdown">${links}</div>
    </details>`;
  };

  const adminLinks = `
    ${item("dashboard.html", "Dashboard", "dashboard")}
    ${group("Farmacia", ["purchasing","inventory","expiration"], `
      ${item("purchasing.html", "Compras", "purchasing")}
      ${item("inventory-audit.html", "Inventario", "inventory")}
      ${item("expiration-dashboard.html", "Vencimientos", "expiration")}
      ${item("availability.html", "Disponibilidad", "availability")}
    `)}
    ${group("Gestión", ["history","imports","catalog"], `
      ${item("history.html", "Histórico", "history")}
      ${item("imports.html", "Importaciones", "imports")}
      ${item("catalog.html", "Catálogo", "catalog")}
    `)}
    <span class="app-nav-module-divider" aria-hidden="true"></span>
    ${item("device-inventory.html", "Dispositivos", "devices", "app-nav-devices")}
  `;

  const operationsLinks = `
    ${item(role === "cashier" ? "cashier.html" : "dispatch-menu.html", role === "cashier" ? "Caja" : "Despacho", "operations")}
    ${item("inventory-audit.html", "Inventario", "inventory")}
    ${item("availability.html", "Disponibilidad", "availability")}
  `;

  const home = isOperations ? (role === "cashier" ? "cashier.html" : "dispatch-menu.html") : "dashboard.html";
  host.outerHTML = `<nav class="navbar app-admin-nav" aria-label="Navegación principal">
    <div class="container app-nav-shell">
      <a id="brand_home" class="app-nav-brand" href="${home}">
        <span class="app-nav-brand-dot" aria-hidden="true"></span>
        <span>Botiquín CCM</span>
      </a>
      <button class="app-nav-toggle" type="button" aria-expanded="false" aria-controls="app_nav_panel">
        <span aria-hidden="true">&#9776;</span><span>Menú</span>
      </button>
      <div id="app_nav_panel" class="app-nav-panel">
        ${isOperations ? operationsLinks : adminLinks}
        <div class="app-nav-account">
          <span class="app-nav-user">Usuario: <strong id="nav_user">-</strong></span>
          <button id="btn_logout" class="app-nav-logout" type="button">Salir</button>
        </div>
      </div>
    </div>
  </nav>`;

  const nav = document.querySelector(".app-admin-nav");
  const toggle = nav && nav.querySelector(".app-nav-toggle");
  const menus = nav ? Array.from(nav.querySelectorAll(".app-nav-menu")) : [];

  if(toggle){
    toggle.addEventListener("click", function(){
      const open = nav.classList.toggle("is-open");
      toggle.setAttribute("aria-expanded", String(open));
    });
  }

  menus.forEach(menu => menu.addEventListener("toggle", function(){
    if(!menu.open) return;
    menus.forEach(other => { if(other !== menu) other.open = false; });
  }));

  document.addEventListener("click", function(event){
    if(!nav || nav.contains(event.target)) return;
    menus.forEach(menu => { menu.open = false; });
  });

  document.addEventListener("keydown", function(event){
    if(event.key !== "Escape") return;
    menus.forEach(menu => { menu.open = false; });
    if(nav && nav.classList.contains("is-open") && window.matchMedia("(max-width: 991.98px)").matches){
      nav.classList.remove("is-open");
      if(toggle) toggle.setAttribute("aria-expanded", "false");
    }
  });
})();
