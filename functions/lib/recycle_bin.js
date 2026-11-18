/**
 * Recycle Bin purge (lib/recycle_bin/ in the app).
 *
 * Every delete in the app copies the item into `recycleBin/{id}` in the same
 * batch/transaction. Clients may read, create and mark entries restored, but
 * never delete them (firestore.rules) — deleting for good happens only here:
 *
 *   - `recycleBin` callable: admins purge chosen entries or empty a tab.
 *     Admin = `users/{uid}.role == "admin"`, read with the Admin SDK.
 *   - `sweepRecycleBin`, daily: purges entries past `expiresAt` (30 days) and
 *     restored entries kept 7 days as a record.
 *
 * Purging an entry also deletes what it holds in Storage: deleted Cloud Files
 * under `recycleBin/files/{id}/` and an oversized payload at `payloadRef`.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

const REGION = "us-central1";
const COLLECTION = "recycleBin";
const FILES_PREFIX = "recycleBin/files/";
const RESTORED_KEEP_DAYS = 7;
const DAY_MS = 24 * 60 * 60 * 1000;
const TABS = ["jobList", "schedule", "maps", "cloudFiles", "clients", "settings"];

const db = () => admin.firestore();
const Timestamp = admin.firestore.Timestamp;

async function requireAdmin(auth) {
  if (!auth || auth.token?.firebase?.sign_in_provider === "anonymous") {
    throw new HttpsError("unauthenticated", "Sign in to manage the Recycle Bin.");
  }
  const user = await db().collection("users").doc(auth.uid).get();
  if (user.get("role") !== "admin") {
    throw new HttpsError("permission-denied",
      "Only admins can permanently delete from the Recycle Bin.");
  }
}

/** Deletes one entry and the Storage it holds: moved Cloud Files, an
 *  oversized payload, and objects it owns in place (a map's thumbnail). */
async function purgeEntry(bucket, doc) {
  const payloadRef = doc.get("payloadRef");
  const owned = doc.get("ownedStorage") || [];
  const [files] = await bucket.getFiles({ prefix: `${FILES_PREFIX}${doc.id}/` });
  await Promise.all([
    ...files.map((f) => f.delete().catch(() => {})),
    payloadRef ? bucket.file(payloadRef).delete().catch(() => {}) : null,
    ...owned.map((p) => bucket.file(p).delete().catch(() => {})),
  ]);
  await doc.ref.delete();
}

async function purgeAll(docs) {
  const bucket = admin.storage().bucket();
  let purged = 0;
  // Small batches: a folder entry can hold hundreds of objects.
  for (let i = 0; i < docs.length; i += 10) {
    await Promise.all(docs.slice(i, i + 10).map((d) => purgeEntry(bucket, d)));
    purged += Math.min(10, docs.length - i);
  }
  return purged;
}

exports.recycleBin = onCall(
  { region: REGION, timeoutSeconds: 540, memory: "512MiB" },
  async (request) => {
    await requireAdmin(request.auth);
    const { action } = request.data || {};

    if (action === "purge") {
      const ids = Array.isArray(request.data.ids) ? request.data.ids : [];
      if (ids.length === 0 || ids.length > 500) {
        throw new HttpsError("invalid-argument", "Pass 1–500 entry ids.");
      }
      const snaps = await Promise.all(
        ids.map((id) => db().collection(COLLECTION).doc(String(id)).get()));
      return { purged: await purgeAll(snaps.filter((s) => s.exists)) };
    }

    if (action === "emptyTab") {
      const tab = request.data.tab;
      if (!TABS.includes(tab)) {
        throw new HttpsError("invalid-argument", `Unknown tab: ${tab}`);
      }
      const snap = await db().collection(COLLECTION)
        .where("tab", "==", tab)
        .where("restoredAt", "==", null)
        .get();
      return { purged: await purgeAll(snap.docs) };
    }

    throw new HttpsError("invalid-argument", `Unknown action: ${action}`);
  }
);

exports.sweepRecycleBin = onSchedule(
  { schedule: "every day 03:45", timeZone: "Africa/Johannesburg", region: REGION,
    timeoutSeconds: 540 },
  async () => {
    const now = Timestamp.now();
    const expired = await db().collection(COLLECTION)
      .where("expiresAt", "<", now)
      .get();
    const restoredBefore = Timestamp.fromMillis(now.toMillis() - RESTORED_KEEP_DAYS * DAY_MS);
    const oldRestored = await db().collection(COLLECTION)
      .where("restoredAt", "<", restoredBefore)
      .get();
    const byId = new Map();
    for (const d of [...expired.docs, ...oldRestored.docs]) byId.set(d.id, d);
    const purged = await purgeAll([...byId.values()]);
    console.log(`sweepRecycleBin: purged ${purged} entries`);
  }
);
