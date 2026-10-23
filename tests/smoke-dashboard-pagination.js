const assert = require("assert");
const fs = require("fs");
const http = require("http");
const path = require("path");
const { chromium } = require("playwright");

const root = path.resolve(__dirname, "..");
const port = 8770;
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

function products(count, prefix){
  return Array.from({ length:count }, (_, index) => ({
    medicine_name:`${prefix} ${index + 1}`,
    external_code:String(700 + index),
    units:index + 1,
    net_sales:(index + 1) * 10,
    profit:index + 1,
    margin_pct:20,
    action:"Pedir",
    suggested_qty:index + 1,
    estimated_purchase_value:index + 1,
    sale_date:`2026-10-${String((index % 28) + 1).padStart(2, "0")}`
  }));
}

const monthly = Array.from({ length:12 }, (_, index) => ({
  month:`2026-${String(index + 1).padStart(2, "0")}`,
  units:index + 1,
  net_sales:(index + 1) * 100,
  profit:(index + 1) * 20,
  patients:index + 1,
  sales_documents:index + 1,
  negative_profit_lines:0
}));

const overview = {
  summary:{ inventory_value:1000, inventory_units:100 },
  monthly_sales:monthly,
  penetration:monthly.map(row => ({ month:row.month, consulted_patients:10, converted_patients:5, penetration_pct:50 })),
  top_units:products(10, "Producto"),
  top_profit:products(10, "Utilidad"),
  recommendations:products(15, "Compra"),
  negative_margin:products(10, "Negativa")
};

const priceMargin = {
  summary:{ total_review_items:23, critical_items:12, desired_gap_items:11, negotiation_risk_items:2 },
  rows:products(23, "Margen").map((row, index) => ({
    ...row,
    margin_status:index < 12 ? "critical" : "review",
    last_purchase_cost_net:10,
    current_sale_price_gross:11,
    current_sale_price_net:9.73,
    current_margin_pct:10,
    suggested_price_20_gross:14,
    suggested_price_25_gross:15,
    reference_price_gross:16,
    reference_vs_suggested_25_gross:1,
    reference_vs_current_gross:5
  }))
};

const followUp = {
  summary:{ records:15, unique_patients:15, no_purchase:15, partial_purchase:0 },
  reasons:[{ reason:"Sin disponibilidad", qty:15, pct:100 }],
  trend:Array.from({ length:8 }, (_, index) => ({ day:`2026-10-${String(index + 1).padStart(2, "0")}`, records:1, patients:1 })),
  catalog:[{ reason_id:"reason-1", label:"Sin disponibilidad", sort_order:1, active:true }],
  records:Array.from({ length:15 }, (_, index) => ({
    event_id:`event-${index + 1}`,
    expediente:`Paciente ${index + 1}`,
    outcome:"no_purchase",
    reason_id:"reason-1",
    reason:"Sin disponibilidad",
    comment:"",
    status:"active",
    created_at:`2026-10-${String((index % 28) + 1).padStart(2, "0")}T15:00:00-06:00`
  }))
};

(async () => {
  await new Promise(resolve => server.listen(port, "127.0.0.1", resolve));
  const browser = await chromium.launch({
    headless:true,
    executablePath:process.env.PLAYWRIGHT_BROWSER_PATH || "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"
  });
  try{
    const page = await browser.newPage({ viewport:{ width:1440, height:1000 } });
    await page.addInitScript(() => {
      localStorage.setItem("dp_session_token", "dashboard-token");
      localStorage.setItem("dp_role", "admin");
      localStorage.setItem("dp_display_name", "Admin");
      localStorage.setItem("dp_user_id", "11111111-1111-1111-1111-111111111111");
      localStorage.setItem("dp_expires_at", "2099-01-01T00:00:00.000Z");
    });
    await page.route("https://rewdmcyqxyzcoeiikoow.supabase.co/rest/v1/rpc/**", async route => {
      const name = route.request().url().split("/").pop();
      const payload = name === "rpc_session_touch"
        ? [{ session_id:"session-1", user_id:"11111111-1111-1111-1111-111111111111", display_name:"Admin", role:"admin", expires_at:"2099-01-01T00:00:00.000Z" }]
        : name === "rpc_dashboard_overview"
          ? overview
          : name === "rpc_dashboard_price_margin_watch"
            ? priceMargin
            : name === "rpc_sales_follow_up_admin_overview"
              ? followUp
              : {};
      await route.fulfill({ status:200, contentType:"application/json", body:JSON.stringify(payload) });
    });

    await page.goto(`${baseUrl}/dashboard.html`);
    await page.locator("#tbody_top_units tr").first().waitFor();
    assert.strictEqual(await page.locator("#tbody_top_units tr").count(), 5);
    assert.match(await page.locator("#pager_top_units").textContent(), /Mostrando 1.5 de 10/);
    await page.locator('#pager_top_units [data-page-step="1"]').click();
    assert.match(await page.locator("#tbody_top_units tr").first().textContent(), /Producto 6/);

    assert.strictEqual(await page.locator("#tbody_monthly_compare tr").count(), 6);
    assert.strictEqual(await page.locator("#tbody_recommendations tr").count(), 5);

    await page.locator('[data-dashboard-tab="price_margin"]').click();
    assert.strictEqual(await page.locator("#tbody_price_margin tr").count(), 10);
    assert.match(await page.locator("#pager_price_margin").textContent(), /de 23/);

    await page.locator('[data-dashboard-tab="sales_follow_up"]').click();
    await page.locator("#sf_records_body tr").first().waitFor();
    assert.strictEqual(await page.locator("#sf_records_body tr").count(), 10);
    assert.match(await page.locator("#sf_records_hint").textContent(), /15 resultados/);
    assert.strictEqual(await page.locator("#sf_trend > div").count(), 6);

    await page.locator('#pager_sf_records [data-page-step="1"]').click();
    assert.match(await page.locator("#sf_records_body tr").first().textContent(), /Paciente 11/);

    await page.locator("#sf_search").fill("Paciente 15");
    assert.strictEqual(await page.locator("#sf_records_body tr").count(), 1);
    assert.strictEqual(await page.locator("#pager_sf_records").isHidden(), true);

    await page.setViewportSize({ width:390, height:844 });
    assert.strictEqual(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);

    console.log("dashboard pagination smoke: bounded rows, navigation, filter reset and all dashboard sections OK");
  }finally{
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => {
  console.error(error);
  server.close(() => process.exit(1));
});
