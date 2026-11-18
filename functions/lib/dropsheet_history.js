/**
 * Dropsheet version history, read from Firestore point-in-time recovery.
 *
 * clmschedule has PITR enabled, so Firestore keeps every version of every
 * document for 7 days. Client SDKs can't read old versions; the Admin SDK can,
 * through a read-only transaction pinned to a `readTime`. The app's
 * "Version history" dialog calls this to list a day's versions and fetch one,
 * then restores it through its normal save path — this function never writes.
 *
 * Added after 2026-10-13, when a device with a days-old offline cache
 * re-synced and saved over a printed, fully allocated dropsheet.
 *
 * Request:
 *   { date: 'YYYY-MM-DD' }                     → { versions: [...] }
 *   { date: 'YYYY-MM-DD', readTime: ISO }      → { version: {..., data} }
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { requireStaff } = require("./require_staff");
const admin = require("firebase-admin");

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const SAST_OFFSET_MS = 2 * 60 * 60 * 1000;
const STEP_MS = 10 * 60 * 1000;
const RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const MINUTE_MS = 60 * 1000;
const CONCURRENCY = 24;

function dayRef(db, date) {
  const [y, m] = date.split("-").map((n) => parseInt(n, 10));
  return db.collection("dropsheet").doc(String(y))
    .collection(`${MONTHS[m - 1]} ${y}`).doc(date);
}

/** Midnight SAST of `date` ('YYYY-MM-DD') as epoch ms. */
function sastMidnight(date) {
  return Date.parse(`${date}T00:00:00Z`) - SAST_OFFSET_MS;
}

/** Reads `ref` as it was at `ms` (rounded down to a whole minute). */
async function readAt(db, ref, ms) {
  const readTime = admin.firestore.Timestamp.fromMillis(
    Math.floor(ms / MINUTE_MS) * MINUTE_MS);
  return db.runTransaction((t) => t.get(ref), { readOnly: true, readTime });
}

function summarise(data) {
  return ((data && data.sections) || []).map((s) => ({
    driverId: s.driverId || s.id || "",
    driverName: s.driverName || "",
    tasks: Array.isArray(s.tasks) ? s.tasks.length : 0,
  }));
}

async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i]);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

const dropsheetHistory = onCall(
  { timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    requireStaff(request.auth);
    const { date, readTime } = request.data || {};
    if (typeof date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      throw new HttpsError("invalid-argument", "date must be YYYY-MM-DD");
    }
    const db = admin.firestore();
    const ref = dayRef(db, date);
    const now = Date.now();
    // Leave a minute's margin so the oldest read doesn't fall off the window.
    const earliest = now - RETENTION_MS + 2 * MINUTE_MS;

    if (readTime) {
      const ms = Date.parse(readTime);
      if (!Number.isFinite(ms) || ms < earliest || ms > now) {
        throw new HttpsError("out-of-range",
          "Versions are only kept for 7 days.");
      }
      const snap = await readAt(db, ref, ms);
      if (!snap.exists) {
        throw new HttpsError("not-found", "No dropsheet existed at that time.");
      }
      return {
        version: {
          readTime,
          updateTime: snap.updateTime.toDate().toISOString(),
          sections: summarise(snap.data()),
          data: snap.data(),
        },
      };
    }

    // The day before (when it's usually planned) through the end of the day.
    const start = Math.max(sastMidnight(date) - 24 * 60 * MINUTE_MS, earliest);
    const end = Math.min(sastMidnight(date) + 24 * 60 * MINUTE_MS, now);
    const times = [];
    for (let t = Math.ceil(start / STEP_MS) * STEP_MS; t <= end; t += STEP_MS) {
      times.push(t);
    }
    const snaps = await mapLimit(times, CONCURRENCY, (t) => readAt(db, ref, t));

    // Each distinct updateTime is one saved version; the first sample that
    // saw it is a readTime that returns exactly that version.
    const versions = [];
    let last;
    snaps.forEach((snap, i) => {
      const key = snap.exists ? snap.updateTime.toMillis() : null;
      if (key === last) return;
      last = key;
      if (!snap.exists) return;
      versions.push({
        readTime: new Date(times[i]).toISOString(),
        updateTime: snap.updateTime.toDate().toISOString(),
        sections: summarise(snap.data()),
      });
    });

    // The live version, in case it was saved after the last sample.
    const current = await ref.get();
    if (current.exists && current.updateTime.toMillis() !== last) {
      versions.push({
        readTime: null,
        updateTime: current.updateTime.toDate().toISOString(),
        sections: summarise(current.data()),
      });
    }
    if (current.exists && versions.length) {
      versions[versions.length - 1].current = true;
    }
    return { versions: versions.reverse() }; // newest first
  },
);

module.exports = { dropsheetHistory };
