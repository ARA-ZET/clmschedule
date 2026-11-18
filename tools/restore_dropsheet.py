#!/usr/bin/env python3
"""Restore a day's dropsheet from Firestore point-in-time recovery (PITR).

clmschedule has PITR enabled: Firestore keeps every version of every document
for 7 days. This tool lists the versions a dropsheet day went through and
writes one of them back.

Usage (times are SAST, 24h):
  python3 tools/restore_dropsheet.py history 2026-10-13
  python3 tools/restore_dropsheet.py restore 2026-10-13 07:05

  history  Shows each distinct saved version with its drivers and task counts,
           and the time to pass to `restore`.
  restore  Backs up the current version to ~/clm_dropsheet_backups/, shows what
           will be written, asks for confirmation, then writes the version
           that was live at the given time.

Needs a gcloud login for richardatclm@gmail.com (gcloud auth login
richardatclm@gmail.com), or set CLM_GCLOUD_ACCOUNT. Uses curl for HTTP
because this Mac's python has no CA certificates.
"""
import datetime as dt
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

PROJECT = "clmschedule"
ACCOUNT = os.environ.get("CLM_GCLOUD_ACCOUNT", "richardatclm@gmail.com")
SAST = dt.timezone(dt.timedelta(hours=2))
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
BACKUP_DIR = os.path.expanduser("~/clm_dropsheet_backups")


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def token():
    try:
        return subprocess.check_output(
            ["gcloud", "auth", "print-access-token", f"--account={ACCOUNT}"],
            stderr=subprocess.PIPE).decode().strip()
    except subprocess.CalledProcessError as e:
        die(f"gcloud token for {ACCOUNT} failed:\n{e.stderr.decode()}")


def doc_url(day):
    month = f"{MONTHS[day.month - 1]}%20{day.year}"
    return (f"https://firestore.googleapis.com/v1/projects/{PROJECT}"
            f"/databases/(default)/documents/dropsheet/{day.year}/{month}/"
            f"{day.isoformat()}")


def curl(tok, *args):
    out = subprocess.check_output(
        ["curl", "-s", "-H", f"Authorization: Bearer {tok}", *args])
    return json.loads(out) if out.strip() else {}


def read(tok, day, at_utc=None):
    url = doc_url(day)
    if at_utc:
        # PITR reads older than 1 hour must be on a whole minute.
        url += "?readTime=" + at_utc.strftime("%Y-%m-%dT%H:%M:00Z")
    d = curl(tok, url)
    if "error" in d:
        if d["error"].get("status") == "NOT_FOUND":
            return None
        die(f"Firestore error: {d['error'].get('message')}")
    return d


def summary(doc):
    if not doc:
        return "(no dropsheet)"
    parts = []
    for s in doc["fields"].get("sections", {}).get("arrayValue", {}).get("values", []):
        f = s["mapValue"]["fields"]
        name = f.get("driverName", {}).get("stringValue", "?")
        n = len(f.get("tasks", {}).get("arrayValue", {}).get("values", []))
        parts.append(f"{name}: {n}")
    return ", ".join(parts) or "(empty)"


def sast(iso):
    t = dt.datetime.fromisoformat(iso[:19]).replace(tzinfo=dt.timezone.utc)
    return t.astimezone(SAST).strftime("%a %d %b %H:%M:%S")


def history(day):
    tok = token()
    now = dt.datetime.now(dt.timezone.utc)
    # The day before (when it's usually planned) through the end of the day.
    start = max(dt.datetime.combine(day - dt.timedelta(days=1), dt.time(), SAST),
                now - dt.timedelta(days=7) + dt.timedelta(minutes=5))
    end = min(dt.datetime.combine(day, dt.time(23, 59), SAST), now)
    step = dt.timedelta(minutes=10)
    print(f"Versions of the {day.isoformat()} dropsheet "
          f"(checked every 10 min, times SAST):\n")
    times = []
    t = start.astimezone(dt.timezone.utc).replace(second=0, microsecond=0)
    while t <= end:
        times.append(t)
        t += step
    with ThreadPoolExecutor(max_workers=16) as pool:
        docs = list(pool.map(lambda at: read(tok, day, at), times))
    last = object()
    for t, doc in zip(times, docs):
        key = doc["updateTime"] if doc else None
        if key != last:
            saved = sast(key) if key else "-"
            pick = t.astimezone(SAST).strftime("%Y-%m-%d %H:%M")
            print(f"  saved {saved}   restore with: {pick}\n      {summary(doc)}")
            last = key
    cur = read(tok, day)
    print(f"\nCurrent: saved {sast(cur['updateTime']) if cur else '-'}\n"
          f"      {summary(cur)}")


def restore(day, when):
    tok = token()
    # "07:05" means that time on the dropsheet's own day; "2026-10-12 16:40"
    # picks a time on another day (e.g. the evening it was planned).
    on = dt.date.fromisoformat(when[:10]) if len(when) > 5 else day
    at = dt.datetime.combine(on, dt.time.fromisoformat(when[-5:]), SAST)
    at_utc = at.astimezone(dt.timezone.utc)
    if at_utc < dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=7):
        die("Firestore only keeps 7 days of history.")
    old = read(tok, day, at_utc)
    if not old:
        die(f"No dropsheet existed at {at:%Y-%m-%d %H:%M} SAST.")
    cur = read(tok, day)

    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = dt.datetime.now(SAST).strftime("%Y%m%d-%H%M%S")
    backup = os.path.join(BACKUP_DIR, f"{day.isoformat()}_before_restore_{stamp}.json")
    with open(backup, "w") as fh:
        json.dump(cur, fh, indent=1)

    print(f"Current  (saved {sast(cur['updateTime']) if cur else '-'}): {summary(cur)}")
    print(f"Restore  (saved {sast(old['updateTime'])}): {summary(old)}")
    print(f"Backup of current written to {backup}")
    if input("Write the restored version? [y/N] ").strip().lower() != "y":
        die("Cancelled, nothing written.")

    fields = old["fields"]
    fields["updatedAt"] = {"integerValue": str(int(time.time() * 1000))}
    body = json.dumps({"fields": fields})
    res = curl(tok, "-X", "PATCH", "-H", "Content-Type: application/json",
               doc_url(day), "--data-binary", body)
    if "error" in res:
        die(f"Restore failed: {res['error'].get('message')}")
    print(f"Restored: {summary(res)}")
    print("Reload the app on every device that has this dropsheet open.")


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("history", "restore"):
        die(__doc__)
    day = dt.date.fromisoformat(sys.argv[2])
    if sys.argv[1] == "history":
        history(day)
    else:
        if len(sys.argv) < 4:
            die("restore needs a time, e.g. 07:05")
        restore(day, " ".join(sys.argv[3:]))


if __name__ == "__main__":
    main()
