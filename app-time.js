(function(global){
  "use strict";

  const TIME_ZONE = "America/El_Salvador";
  const UTC_OFFSET = "-06:00";

  function asDate(value){
    const date = value instanceof Date ? value : new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  function parts(value, options){
    const date = asDate(value);
    if(!date) return null;
    const result = new Intl.DateTimeFormat("es-SV", { timeZone:TIME_ZONE, ...options }).formatToParts(date);
    return Object.fromEntries(result.map(part => [part.type, part.value]));
  }

  function formatDate(value, fallback="-"){
    const p = parts(value, { day:"2-digit", month:"2-digit", year:"numeric" });
    return p ? `${p.day}/${p.month}/${p.year}` : fallback;
  }

  function formatTime(value, options={}){
    const p = parts(value, {
      hour:"2-digit",
      minute:"2-digit",
      ...(options.seconds ? { second:"2-digit" } : {}),
      hour12:true
    });
    if(!p) return options.fallback ?? "-";
    const seconds = options.seconds ? `:${p.second}` : "";
    return `${p.hour}:${p.minute}${seconds} ${p.dayPeriod || ""}`.trim();
  }

  function formatDateTime(value, options={}){
    const fallback = options.fallback ?? "-";
    const date = asDate(value);
    if(!date) return fallback;
    return `${formatDate(date, fallback)} ${formatTime(date, { seconds:Boolean(options.seconds), fallback })}`;
  }

  function todayYmd(value=new Date()){
    const p = parts(value, { year:"numeric", month:"2-digit", day:"2-digit" });
    return p ? `${p.year}-${p.month}-${p.day}` : "";
  }

  function currentMonth(value=new Date()){
    return todayYmd(value).slice(0, 7);
  }

  function addDaysYmd(ymd, days){
    if(!/^\d{4}-\d{2}-\d{2}$/.test(String(ymd || ""))) return "";
    const [year, month, day] = ymd.split("-").map(Number);
    const date = new Date(Date.UTC(year, month - 1, day + Number(days || 0)));
    return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2,"0")}-${String(date.getUTCDate()).padStart(2,"0")}`;
  }

  function dateInputToIso(ymd, endOfDay=false){
    if(!/^\d{4}-\d{2}-\d{2}$/.test(String(ymd || ""))) return null;
    const time = endOfDay ? "23:59:59.999" : "00:00:00.000";
    return new Date(`${ymd}T${time}${UTC_OFFSET}`).toISOString();
  }

  global.AppTime = Object.freeze({
    TIME_ZONE,
    formatDate,
    formatTime,
    formatDateTime,
    todayYmd,
    currentMonth,
    addDaysYmd,
    dateInputToIso
  });
})(window);
