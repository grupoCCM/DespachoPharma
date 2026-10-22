const assert = require("assert");

global.window = {};
require("../app-time.js");

const time = window.AppTime;

assert.strictEqual(time.formatDate("2026-10-07T18:52:00Z"), "07/10/2026");
assert.match(time.formatTime("2026-10-07T18:52:00Z"), /^12:52 p\./);
assert.strictEqual(time.formatDate("2026-10-08T01:00:00Z"), "07/10/2026");
assert.match(time.formatTime("2026-10-08T01:00:00Z"), /^07:00 p\./);
assert.strictEqual(time.todayYmd(new Date("2026-10-08T01:00:00Z")), "2026-10-07");
assert.strictEqual(time.addDaysYmd("2026-03-01", -1), "2026-02-28");
assert.strictEqual(time.dateInputToIso("2026-10-07"), "2026-10-07T06:00:00.000Z");
assert.strictEqual(time.dateInputToIso("2026-10-07", true), "2026-10-08T05:59:59.999Z");

console.log("app-time.js: timezone checks OK");
