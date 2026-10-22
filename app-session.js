(function(){
  "use strict";

  const SUPABASE_URL = "https://rewdmcyqxyzcoeiikoow.supabase.co";
  const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJld2RtY3lxeHl6Y29laWlrb293Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzEwMDcxMDMsImV4cCI6MjA4NjU4MzEwM30.vRkCRFYez3zeL67Ik_niDrPu9wGt53gEqE6LLf_SUHE";
  const SESSION_KEYS = ["dp_session_token","dp_role","dp_display_name","dp_user_id","dp_expires_at","dp_last_activity"];
  const RENEW_AFTER_MS = 4 * 60 * 1000;
  const RETRY_AFTER_MS = 30 * 1000;
  const ROLE_HOME = {
    admin: "dashboard.html",
    dispatch: "dispatch-menu.html",
    cashier: "cashier.html"
  };

  let readyResolve;
  let readySession = null;
  let validationPromise = null;
  let expirationTimer = null;
  let retryTimer = null;
  let lastServerTouchAt = 0;
  let activityBound = false;

  const ready = new Promise(resolve => { readyResolve = resolve; });

  function storedSession(){
    return {
      token: localStorage.getItem("dp_session_token") || "",
      role: String(localStorage.getItem("dp_role") || "").toLowerCase(),
      name: localStorage.getItem("dp_display_name") || "",
      userId: localStorage.getItem("dp_user_id") || "",
      expiresAt: localStorage.getItem("dp_expires_at") || ""
    };
  }

  function clearStoredSession(){
    SESSION_KEYS.forEach(key => localStorage.removeItem(key));
  }

  function loginRedirect(){
    clearStoredSession();
    window.location.replace("index.html");
  }

  function allowedRoles(){
    return String(document.body?.dataset.sessionRoles || "")
      .split(",")
      .map(role => role.trim().toLowerCase())
      .filter(Boolean);
  }

  function redirectForRole(role){
    const suffix = role ? role.charAt(0).toUpperCase() + role.slice(1) : "";
    const pageOverride = suffix ? document.body?.dataset[`sessionRedirect${suffix}`] : "";
    window.location.replace(pageOverride || ROLE_HOME[role] || "index.html");
  }

  function ensureGuardUi(){
    if(!document.getElementById("app_session_guard_style")){
      const style = document.createElement("style");
      style.id = "app_session_guard_style";
      style.textContent = `
        html.app-session-pending body > :not(#app_session_guard),
        html.app-session-locked body > :not(#app_session_guard){visibility:hidden!important}
        #app_session_guard{position:fixed;inset:0;z-index:2147483647;display:none;align-items:center;justify-content:center;background:#f6f8fb;color:#172033;font-family:system-ui,-apple-system,"Segoe UI",sans-serif}
        html.app-session-pending #app_session_guard,html.app-session-locked #app_session_guard{display:flex}
        .app-session-guard-box{width:min(420px,calc(100vw - 32px));padding:24px;border:1px solid #d9e1ec;border-radius:8px;background:#fff;box-shadow:0 16px 42px rgba(17,31,52,.12);text-align:center}
        .app-session-guard-spinner{width:30px;height:30px;margin:0 auto 14px;border:3px solid #d7e3f5;border-top-color:#0d6efd;border-radius:50%;animation:app-session-spin .8s linear infinite}
        .app-session-guard-title{margin:0 0 6px;font-size:18px;font-weight:700}
        .app-session-guard-message{margin:0;color:#5b6b82;font-size:14px;line-height:1.45}
        .app-session-guard-actions{display:none;gap:8px;justify-content:center;margin-top:18px}
        html.app-session-locked .app-session-guard-spinner{display:none}
        html.app-session-locked .app-session-guard-actions{display:flex}
        .app-session-guard-btn{min-height:38px;padding:7px 14px;border:1px solid #8b99ab;border-radius:6px;background:#fff;color:#223047;cursor:pointer;font:inherit}
        .app-session-guard-btn-primary{border-color:#0d6efd;background:#0d6efd;color:#fff}
        @keyframes app-session-spin{to{transform:rotate(360deg)}}
      `;
      document.head.appendChild(style);
    }

    if(!document.getElementById("app_session_guard")){
      const guard = document.createElement("div");
      guard.id = "app_session_guard";
      guard.setAttribute("role", "status");
      guard.setAttribute("aria-live", "polite");
      guard.innerHTML = `
        <div class="app-session-guard-box">
          <div class="app-session-guard-spinner" aria-hidden="true"></div>
          <p class="app-session-guard-title" id="app_session_guard_title">Validando sesión</p>
          <p class="app-session-guard-message" id="app_session_guard_message">Espera un momento.</p>
          <div class="app-session-guard-actions">
            <button class="app-session-guard-btn app-session-guard-btn-primary" id="app_session_retry" type="button">Reintentar</button>
            <button class="app-session-guard-btn" id="app_session_login" type="button">Volver al inicio</button>
          </div>
        </div>`;
      document.body.appendChild(guard);
      document.getElementById("app_session_retry").addEventListener("click", () => validateSession({ force:true, lockDuringValidation:true }));
      document.getElementById("app_session_login").addEventListener("click", loginRedirect);
    }
  }

  function setGuardState(state, title, message){
    ensureGuardUi();
    document.documentElement.classList.toggle("app-session-pending", state === "pending");
    document.documentElement.classList.toggle("app-session-locked", state === "locked");
    const titleNode = document.getElementById("app_session_guard_title");
    const messageNode = document.getElementById("app_session_guard_message");
    if(titleNode && title) titleNode.textContent = title;
    if(messageNode && message) messageNode.textContent = message;
  }

  function revealApplication(){
    document.documentElement.classList.remove("app-session-pending", "app-session-locked");
  }

  function parseExpiry(value){
    const time = Date.parse(value || "");
    return Number.isFinite(time) ? time : 0;
  }

  function armExpiration(expiresAt){
    clearTimeout(expirationTimer);
    const remaining = Math.max(0, parseExpiry(expiresAt) - Date.now());
    expirationTimer = setTimeout(() => {
      setGuardState("pending", "Validando sesión", "La vigencia de la sesión está siendo comprobada.");
      validateSession({ force:true, lockDuringValidation:true });
    }, remaining + 250);
  }

  function saveServerSession(row){
    if(row.role) localStorage.setItem("dp_role", String(row.role).toLowerCase());
    if(row.display_name) localStorage.setItem("dp_display_name", row.display_name);
    if(row.user_id) localStorage.setItem("dp_user_id", row.user_id);
    if(row.expires_at) localStorage.setItem("dp_expires_at", row.expires_at);
    localStorage.setItem("dp_last_activity", new Date().toISOString());
    lastServerTouchAt = Date.now();
    armExpiration(row.expires_at);
    return storedSession();
  }

  async function callTouch(token){
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 12000);
    try{
      const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/rpc_session_touch`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "apikey": SUPABASE_ANON_KEY,
          "Authorization": `Bearer ${SUPABASE_ANON_KEY}`
        },
        body: JSON.stringify({ p_session_token:token }),
        signal: controller.signal
      });
      const text = await response.text();
      let data = null;
      try{ data = text ? JSON.parse(text) : null; }catch(_){ data = null; }
      if(!response.ok) throw new Error(data?.message || data?.details || "No se pudo validar la sesión.");
      return data;
    }finally{
      clearTimeout(timeout);
    }
  }

  function scheduleRetry(){
    clearTimeout(retryTimer);
    retryTimer = setTimeout(() => validateSession({ force:true, lockDuringValidation:true }), RETRY_AFTER_MS);
  }

  async function validateSession(options){
    const settings = Object.assign({ force:false, lockDuringValidation:false }, options || {});
    if(validationPromise) return validationPromise;

    const current = storedSession();
    if(!current.token){
      loginRedirect();
      return false;
    }

    if(!settings.force && readySession && (Date.now() - lastServerTouchAt) < RENEW_AFTER_MS){
      return true;
    }

    if(settings.lockDuringValidation){
      setGuardState("pending", "Validando sesión", "Espera un momento.");
    }

    validationPromise = (async () => {
      try{
        const rows = await callTouch(current.token);
        if(!Array.isArray(rows) || rows.length === 0){
          loginRedirect();
          return false;
        }

        const session = saveServerSession(rows[0]);
        const roles = allowedRoles();
        if(roles.length && !roles.includes(session.role)){
          redirectForRole(session.role);
          return false;
        }

        clearTimeout(retryTimer);
        readySession = session;
        revealApplication();
        if(readyResolve){
          readyResolve(session);
          readyResolve = null;
        }
        bindActivity();
        return true;
      }catch(_){
        const expiresAt = parseExpiry(storedSession().expiresAt);
        if(!readySession || !expiresAt || Date.now() >= expiresAt || settings.lockDuringValidation){
          setGuardState("locked", "No se pudo validar la sesión", "Comprueba la conexión y vuelve a intentarlo. La información digitada permanece en esta pantalla.");
          scheduleRetry();
        }
        return false;
      }finally{
        validationPromise = null;
      }
    })();

    return validationPromise;
  }

  function markActivity(){
    localStorage.setItem("dp_last_activity", new Date().toISOString());
    if(readySession && (Date.now() - lastServerTouchAt) >= RENEW_AFTER_MS){
      validateSession({ force:true, lockDuringValidation:false });
    }
  }

  function bindActivity(){
    if(activityBound) return;
    activityBound = true;
    ["mousedown","keydown","touchstart"].forEach(eventName => {
      window.addEventListener(eventName, markActivity, { passive:true });
    });
    document.addEventListener("visibilitychange", () => {
      if(document.visibilityState !== "visible") return;
      const expired = Date.now() >= parseExpiry(storedSession().expiresAt);
      validateSession({ force:true, lockDuringValidation:expired });
    });
    window.addEventListener("pageshow", event => {
      if(!event.persisted) return;
      setGuardState("pending", "Validando sesión", "Espera un momento.");
      validateSession({ force:true, lockDuringValidation:true });
    });
    window.addEventListener("storage", event => {
      if(event.key === "dp_session_token" && !event.newValue){
        window.location.replace("index.html");
        return;
      }
      if(event.key === "dp_expires_at" && event.newValue){
        armExpiration(event.newValue);
      }
    });
  }

  async function requireSession(options){
    const session = await ready;
    const roles = (options?.roles || []).map(role => String(role).toLowerCase());
    if(roles.length && !roles.includes(session.role)){
      redirectForRole(session.role);
      return false;
    }
    return true;
  }

  document.documentElement.classList.add("app-session-pending");
  window.AppSession = {
    ready,
    requireSession,
    validate: options => validateSession(Object.assign({ force:true }, options || {})),
    getSession: storedSession,
    clearAndRedirect: loginRedirect
  };

  ensureGuardUi();
  validateSession({ force:true, lockDuringValidation:true });
})();
