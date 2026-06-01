/**
 * Depthsure — Base Station Logs : Google Apps Script web app (bound to the sheet).
 *
 * DEPLOY (one time):
 *   1. Open the sheet "Depthsure — Base Station Logs".
 *   2. Extensions ▸ Apps Script. Delete any sample code, paste THIS file.
 *   3. Save. Then Deploy ▸ New deployment ▸ type "Web app".
 *        - Execute as: Me
 *        - Who has access: Anyone
 *   4. Authorize when prompted. Copy the Web app URL (ends in /exec).
 *   5. Send that /exec URL back — it goes into GitHub + Vercel as APPS_SCRIPT_URL.
 *
 * Writers (GitHub Action) POST {secret, rows:[{...}]} -> appended + pruned >3 days.
 * Readers (dashboard) GET ?secret=...&days=3 -> {ok, rows:[...]}.
 */

const SECRET = 'ab833296e9664f9b7f1a01b4f54fc028a403c5d3a152d0f4';
const RETENTION_DAYS = 3;
const HEADER = ['ts_utc','ts_ist','station','status','rtcm_bytes','data_rate_bps',
  'frames','sats_total','sats_gps','sats_glo','sats_gal','sats_bds','sats_qzs',
  'lat','lon','height_m','detail'];

function sheet_() {
  const sh = SpreadsheetApp.getActiveSpreadsheet().getSheets()[0];
  if (sh.getLastRow() === 0) sh.appendRow(HEADER);
  return sh;
}

function doPost(e) {
  try {
    const body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (body.secret !== SECRET) return json_({ ok: false, error: 'unauthorized' });
    const rows = body.rows || [];
    const sh = sheet_();
    rows.forEach(function (r) {
      sh.appendRow(HEADER.map(function (k) { return r[k] !== undefined && r[k] !== null ? r[k] : ''; }));
    });
    prune_(sh);
    return json_({ ok: true, appended: rows.length });
  } catch (err) {
    return json_({ ok: false, error: String(err) });
  }
}

function doGet(e) {
  const p = (e && e.parameter) || {};
  if (SECRET && p.secret !== SECRET) return json_({ ok: false, error: 'unauthorized' });
  const days = Math.max(1, Math.min(7, parseInt(p.days, 10) || RETENTION_DAYS));
  const sh = sheet_();
  const data = sh.getDataRange().getValues();
  const header = data.shift() || HEADER;
  const cutoff = Date.now() - days * 86400000;
  const out = [];
  data.forEach(function (row) {
    const ts = new Date(row[0]).getTime();
    if (!isNaN(ts) && ts >= cutoff) {
      const o = {};
      header.forEach(function (h, i) { o[h] = row[i]; });
      out.push(o);
    }
  });
  return json_({ ok: true, rows: out, count: out.length, generatedAt: new Date().toISOString() });
}

/** Delete contiguous rows older than retention from the top (append order = oldest first). */
function prune_(sh) {
  const data = sh.getDataRange().getValues();
  const cutoff = Date.now() - RETENTION_DAYS * 86400000;
  let del = 0;
  for (let i = 1; i < data.length; i++) {
    const ts = new Date(data[i][0]).getTime();
    if (!isNaN(ts) && ts < cutoff) del++; else break;
  }
  if (del > 0) sh.deleteRows(2, del);
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
