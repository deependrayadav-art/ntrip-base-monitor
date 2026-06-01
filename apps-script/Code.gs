/**
 * Depthsure — Base Station Logs : Google Apps Script web app (bound to the sheet).
 *
 * REDEPLOY after editing:
 *   Deploy ▸ Manage deployments ▸ ✏️ Edit ▸ Version: "New version" ▸ Deploy.
 *   (Same /exec URL — nothing else to change.)
 *
 * Column-dynamic: appends a row per station, and AUTO-ADDS any new metric column
 * the writer sends (e.g. correction_latency_sec) — no future redeploys needed.
 * Writers POST {secret, rows:[{...}]}; readers GET ?secret=...&days=3.
 */

const SECRET = 'ab833296e9664f9b7f1a01b4f54fc028a403c5d3a152d0f4';
const RETENTION_DAYS = 3;
const BASE_HEADER = ['ts_utc','ts_ist','station','status','rtcm_bytes','data_rate_bps',
  'frames','sats_total','sats_gps','sats_glo','sats_gal','sats_bds','sats_qzs',
  'lat','lon','height_m','correction_latency_sec','detail'];

function sheet_() {
  const sh = SpreadsheetApp.getActiveSpreadsheet().getSheets()[0];
  if (sh.getLastRow() === 0) sh.appendRow(BASE_HEADER);
  return sh;
}
function headerOf_(sh) {
  return sh.getRange(1, 1, 1, Math.max(1, sh.getLastColumn())).getValues()[0].filter(String);
}

function doPost(e) {
  try {
    const body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (body.secret !== SECRET) return json_({ ok: false, error: 'unauthorized' });
    const rows = body.rows || [];
    const sh = sheet_();
    let header = headerOf_(sh);

    // Auto-extend the header with any new keys the writer sends.
    const newCols = [];
    rows.forEach(function (r) {
      Object.keys(r).forEach(function (k) {
        if (k !== 'secret' && header.indexOf(k) === -1 && newCols.indexOf(k) === -1) newCols.push(k);
      });
    });
    if (newCols.length) {
      header = header.concat(newCols);
      sh.getRange(1, 1, 1, header.length).setValues([header]);
    }

    rows.forEach(function (r) {
      sh.appendRow(header.map(function (k) { return r[k] !== undefined && r[k] !== null ? r[k] : ''; }));
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
  const header = data.shift() || BASE_HEADER;
  const cutoff = Date.now() - days * 86400000;
  const out = [];
  data.forEach(function (row) {
    const ts = new Date(row[0]).getTime();
    if (!isNaN(ts) && ts >= cutoff) {
      const o = {};
      header.forEach(function (h, i) { if (h) o[h] = row[i]; });
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
