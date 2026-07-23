#!/usr/bin/env python3
"""
Fetch CORS **RTK** subscription validity for Survey of India CORS accounts
(Region-1 Trimble portal, http://103.205.244.106).

RULE (authoritative):
  Validity Upto = the RTK subscription's End time ONLY (latest, if several RTK
                  subs). iScope is network access, NOT realtime correction, so
                  iScope-only accounts get a BLANK validity — never the iScope date.
  Validity Remarks:
    - RTK active            -> ""  (blank)
    - iScope only (no RTK)  -> "No active RTK plan (no realtime)"
    - login rejected        -> "Login failed - verify CORS ID/password"

Each account's subscriptions are read from ActiveSubscriptions.aspx; the exact
End time comes from each row's SubscriptionDetails.aspx?SubscriptionId=<id>
(raw dates are en-US M/D/YYYY; output is dd/mm/yyyy).

Input : cors_accounts.csv  with columns  row,cors_id,password,serial  (extra cols ok)
Output: cors_expiry_results.csv  with
        row,cors_id,serial,validity,rtk_start,remark,rtk_contract,all_subs,status
        (validity = RTK End date, rtk_start = RTK Start date; both dd/mm/yyyy)

Usage:
  pip install requests
  python3 fetch_expiry.py [--accounts FILE] [--out FILE] [--limit N] [--only 2,4,5]
Credentials come from the input CSV / args, never hard-coded or echoed.
"""
import argparse, calendar, csv, datetime as dt, os, re, sys, time
try:
    import requests
except ImportError:
    sys.exit("Missing dependency. Run:  pip install requests")

HERE = os.path.dirname(os.path.abspath(__file__))
R1 = "http://103.205.244.106"
SUBS_PAGE = "/MemberPages/ActiveSubscriptions.aspx"
DETAIL_PAGE = "/MemberPages/SubscriptionDetails.aspx?SubscriptionId="
TIMEOUT = 30
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")

INPUT_RE = re.compile(r"<input\b[^>]*>", re.I)
ATTR_RE = re.compile(r'(\w+)\s*=\s*"([^"]*)"')
CELL_RE = re.compile(r"(<td[^>]*GridSubscriptions-ic'[^>]*>.*?</td>)", re.S)
UV_RE = re.compile(r'uV="([^"]*)"')
TAG_RE = re.compile(r"<[^>]+>")
SUBID_RE = re.compile(r"SubscriptionDetails\.aspx\?SubscriptionId=(\d+)", re.I)
ENDTIME_RE = re.compile(r"End time \(Local time\):\s*(\d{1,2}/\d{1,2}/\d{4})", re.I)
STARTTIME_RE = re.compile(r"Start time \(Local time\):\s*(\d{1,2}/\d{1,2}/\d{4})", re.I)


def parse_inputs(html):
    out = {}
    for tag in INPUT_RE.findall(html):
        attrs = {k.lower(): v for k, v in ATTR_RE.findall(tag)}
        if attrs.get("name"):
            out[attrs["name"]] = attrs.get("value", "")
    return out


def parse_mdy(s):
    try:
        return dt.datetime.strptime(s.split()[0], "%m/%d/%Y").date()
    except Exception:
        return None


def fmt(d):
    return d.strftime("%d/%m/%Y") if d else "?"


def parse_grid(html):
    cells = []
    for c in CELL_RE.findall(html):
        uv = UV_RE.search(c)
        txt = TAG_RE.sub("", c).strip().replace("&nbsp;", "")
        cells.append((txt, uv.group(1) if uv else None))
    ids = SUBID_RE.findall(html)
    subs = []
    for i in range(0, len(cells) - 8, 9):
        r = cells[i:i + 9]
        idx = i // 9
        subs.append({"contract": r[3][0], "start": parse_mdy(r[5][1] or ""),
                     "sub_id": ids[idx] if idx < len(ids) else None})
    return subs


def login_region1(sess, user, pw):
    r = sess.get(R1 + "/Login.aspx", timeout=TIMEOUT)
    data = parse_inputs(r.text)
    data["ctl00$ContentPlaceHolder1$m_Login$UserName"] = user
    data["ctl00$ContentPlaceHolder1$m_Login$Password"] = pw
    data["ctl00$ContentPlaceHolder1$m_Login$LoginButton"] = "Login"
    data.pop("ctl00$ContentPlaceHolder1$m_Login$RememberMe", None)
    sess.post(R1 + "/Login.aspx", data=data, timeout=TIMEOUT)
    page = sess.get(R1 + SUBS_PAGE, timeout=TIMEOUT).text
    return ("m_Login$Password" not in page), page


def fetch_dates(sess, sub_id):
    """Return (start, end) dates for a subscription from its detail page."""
    if not sub_id:
        return None, None
    txt = TAG_RE.sub(" ", sess.get(R1 + DETAIL_PAGE + sub_id, timeout=TIMEOUT).text)
    ms = STARTTIME_RE.search(txt); me = ENDTIME_RE.search(txt)
    return (parse_mdy(ms.group(1)) if ms else None,
            parse_mdy(me.group(1)) if me else None)


def process(user, pw):
    s = requests.Session(); s.headers["User-Agent"] = UA
    logged_in, page = login_region1(s, user, pw)
    if not logged_in:
        return dict(status="LOGIN_FAILED", validity="", rtk_start="", rtk_contract="",
                    all_subs="", remark="Login failed - verify CORS ID/password")
    subs = parse_grid(page)
    for sub in subs:
        ds, de = fetch_dates(s, sub["sub_id"])
        sub["end"] = de
        if ds:
            sub["start"] = ds          # prefer the detail-page start (matches End); else keep grid start
    desc = "; ".join(f"{x['contract']}({fmt(x['start'])}->{fmt(x['end'])})" for x in subs)
    rtk = [(x["end"], x) for x in subs if re.search("RTK", x["contract"], re.I) and x["end"]]
    if rtk:
        rtk.sort(key=lambda t: t[0])
        end, sub = rtk[-1]
        return dict(status="OK_RTK", validity=fmt(end),
                    rtk_start=(fmt(sub["start"]) if sub.get("start") else ""),
                    rtk_contract=sub["contract"], all_subs=desc, remark="")
    if not subs:
        return dict(status="NO_SUBS", validity="", rtk_start="", rtk_contract="", all_subs="",
                    remark="No active subscription")
    return dict(status="OK_NORTK", validity="", rtk_start="", rtk_contract="", all_subs=desc,
                remark="No active RTK plan (no realtime)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--accounts", default=os.path.join(HERE, "cors_accounts.csv"))
    ap.add_argument("--out", default=os.path.join(HERE, "cors_expiry_results.csv"))
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    only = {x.strip() for x in args.only.split(",") if x.strip()}

    with open(args.accounts, newline="") as f:
        accounts = list(csv.DictReader(f))
    if only:
        accounts = [a for a in accounts if a.get("row") in only]
    if args.limit:
        accounts = accounts[:args.limit]

    fields = ["row", "cors_id", "serial", "validity", "rtk_start", "remark",
              "rtk_contract", "all_subs", "status"]
    results = []
    for i, a in enumerate(accounts, 1):
        user = a["cors_id"].strip().replace(" ", "")   # despace usernames
        print(f"[{i}/{len(accounts)}] {user}")
        try:
            res = process(user, a["password"])
        except Exception as e:
            res = dict(status="ERROR", validity="", rtk_start="", rtk_contract="", all_subs="",
                       remark=f"{type(e).__name__}: {e}")
        row = {"row": a.get("row", ""), "cors_id": user, "serial": a.get("serial", "")}
        row.update(res)
        results.append(row)
        print(f"     -> {res['status']:<12} {res['validity']:<11} {res['remark']}")
        time.sleep(0.3)

    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader(); w.writerows(results)
    from collections import Counter
    print(f"\nDone. {dict(Counter(r['status'] for r in results))}  -> {args.out}")


if __name__ == "__main__":
    main()
