/**
 * Cape Town Letterbox Index — server-side seeding.
 *
 * Turns the compiled GPX waypoints already sitting in Cloud Storage into
 * per-suburb candidate letterbox positions:
 *
 *   letterboxes/{suburbId}.json.gz   gzipped [lng,lat,…] payload
 *   letterboxSuburbs/{suburbId}      small metadata doc (count, status, bounds)
 *
 * Two design points worth knowing before editing this:
 *
 * 1. **Folder-major, not suburb-major.** The obvious shape is "for each suburb,
 *    scan every folder", which reads all 269 compiled files 613 times. This
 *    instead reads each folder exactly once and fans its waypoints out to
 *    whichever suburb contains them — O(folders), not O(folders x suburbs).
 *
 * 2. **A verified suburb is never overwritten.** New GPS drops raise
 *    `hasNewCandidates` on the metadata document and stop there. The curated
 *    set is a human artefact; a background job must not silently edit the
 *    numbers the business quotes from.
 *
 * The payload format mirrors `LetterboxCodec` in the Flutter app exactly —
 * change one and you must change the other, and bump `FORMAT_VERSION` in both.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const zlib = require("zlib");
const { promisify } = require("util");

const gzip = promisify(zlib.gzip);

// Must match LetterboxCodec.formatVersion in the Flutter app.
const FORMAT_VERSION = 1;

// ~11 cm. Must match LetterboxCodec._coordinatePrecision.
const COORD_PRECISION = 6;

// ~5.5 m. Repeat monthly visits to one letterbox collapse onto this grid.
const SNAP_DEGREES = 0.00005;

// Cell size for the suburb lookup grid. Roughly 1 km; small enough that a
// cell rarely lists more than a handful of suburbs.
const SUBURB_CELL_DEGREES = 0.01;

const COMPILED_WAYPOINTS_FILE = "_compiled_waypoints.json";

// How many compiled files to download at once. The files are small; the limit
// exists to avoid opening 269 sockets simultaneously.
const DOWNLOAD_CONCURRENCY = 20;

// Firestore caps a batch at 500 writes.
const FIRESTORE_BATCH_LIMIT = 500;

const db = () => admin.firestore();
const bucket = () => admin.storage().bucket();

// ── Geometry ──────────────────────────────────────────────────────────

/** Ray-casting point-in-polygon. Mirrors isPointInPolygon in the Flutter app. */
function pointInPolygon(lat, lng, polygon) {
  const n = polygon.length;
  if (n < 3) return false;
  let inside = false;
  for (let j = 0; j < n; j++) {
    const a = polygon[j];
    const b = polygon[(j + 1) % n];
    if ((a.lat > lat) !== (b.lat > lat)) {
      const x = ((b.lng - a.lng) * (lat - a.lat)) / (b.lat - a.lat) + a.lng;
      if (lng < x) inside = !inside;
    }
  }
  return inside;
}

function boundsOf(points) {
  let minLat = Infinity, maxLat = -Infinity;
  let minLng = Infinity, maxLng = -Infinity;
  for (const p of points) {
    if (p.lat < minLat) minLat = p.lat;
    if (p.lat > maxLat) maxLat = p.lat;
    if (p.lng < minLng) minLng = p.lng;
    if (p.lng > maxLng) maxLng = p.lng;
  }
  return { minLat, minLng, maxLat, maxLng };
}

/**
 * Load the 613 suburb polygons and build a grid from cell key to the suburbs
 * whose bounding box covers that cell. Without this, classifying 890 000
 * waypoints would mean 545 million polygon tests.
 */
async function loadSuburbIndex() {
  const snap = await db().doc("workSuburbs/main").get();
  if (!snap.exists) {
    throw new HttpsError("failed-precondition", "workSuburbs/main does not exist.");
  }

  const raw = snap.data().suburbs || [];
  const suburbs = [];
  for (const entry of raw) {
    const pts = entry.polygonPoints || [];
    if (pts.length < 3) continue;
    const polygon = pts
      .map((p) => ({ lat: Number(p.latitude), lng: Number(p.longitude) }))
      .filter((p) => Number.isFinite(p.lat) && Number.isFinite(p.lng));
    if (polygon.length < 3) continue;
    suburbs.push({
      id: String(entry.id),
      name: String(entry.name || ""),
      polygon,
      bounds: boundsOf(polygon),
    });
  }

  const grid = new Map();
  suburbs.forEach((suburb, index) => {
    const { minLat, minLng, maxLat, maxLng } = suburb.bounds;
    const minRow = Math.floor(minLat / SUBURB_CELL_DEGREES);
    const maxRow = Math.floor(maxLat / SUBURB_CELL_DEGREES);
    const minCol = Math.floor(minLng / SUBURB_CELL_DEGREES);
    const maxCol = Math.floor(maxLng / SUBURB_CELL_DEGREES);
    for (let row = minRow; row <= maxRow; row++) {
      for (let col = minCol; col <= maxCol; col++) {
        const key = `${row}:${col}`;
        let list = grid.get(key);
        if (!list) grid.set(key, (list = []));
        list.push(index);
      }
    }
  });

  return { suburbs, grid };
}

/** Index of the suburb containing this position, or -1. */
function suburbFor(lat, lng, { suburbs, grid }) {
  const key = `${Math.floor(lat / SUBURB_CELL_DEGREES)}:${Math.floor(
    lng / SUBURB_CELL_DEGREES
  )}`;
  const candidates = grid.get(key);
  if (!candidates) return -1;
  for (const index of candidates) {
    const suburb = suburbs[index];
    const b = suburb.bounds;
    if (lat < b.minLat || lat > b.maxLat || lng < b.minLng || lng > b.maxLng) {
      continue;
    }
    if (pointInPolygon(lat, lng, suburb.polygon)) return index;
  }
  return -1;
}

// ── Payload ───────────────────────────────────────────────────────────

const round = (v) => Number(v.toFixed(COORD_PRECISION));

/** Encode positions exactly as LetterboxCodec.encode does, then gzip. */
async function encodePayload(suburbId, suburbName, positions) {
  const pts = [];
  for (const p of positions) {
    pts.push(round(p.lng), round(p.lat));
  }
  const payload = {
    v: FORMAT_VERSION,
    suburbId,
    name: suburbName,
    count: positions.length,
    pts,
  };
  return gzip(Buffer.from(JSON.stringify(payload), "utf8"));
}

// ── Folder discovery ──────────────────────────────────────────────────

/** Every folder under Distribution/ that has a compiled waypoints file. */
async function listWaypointFolders() {
  const [files] = await bucket().getFiles({ prefix: "Distribution/" });
  const folders = new Set();
  for (const file of files) {
    if (file.name.endsWith(`/${COMPILED_WAYPOINTS_FILE}`)) {
      folders.add(file.name.slice(0, -(COMPILED_WAYPOINTS_FILE.length + 1)));
    }
  }
  return [...folders].sort();
}

async function mapWithConcurrency(items, limit, worker) {
  const results = [];
  let cursor = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor++;
      results[index] = await worker(items[index], index);
    }
  });
  await Promise.all(runners);
  return results;
}

// ── The seed pass ─────────────────────────────────────────────────────

/**
 * Read every folder once, classify its waypoints into suburbs, dedupe, and
 * write one payload plus one metadata document per suburb that produced
 * candidates.
 */
async function runSeed({ folderPaths, dryRun }) {
  const startedAt = Date.now();
  const index = await loadSuburbIndex();
  console.log(`[letterboxSeed] ${index.suburbs.length} suburb polygons loaded`);

  const folders = folderPaths && folderPaths.length
    ? folderPaths
    : await listWaypointFolders();
  console.log(`[letterboxSeed] ${folders.length} folders with compiled waypoints`);

  // suburbIndex -> Map<snapKey, {lat, lng}>
  const perSuburb = new Map();
  let totalDrops = 0;
  let insideDrops = 0;
  let unmatchedDrops = 0;
  const failedFolders = [];

  await mapWithConcurrency(folders, DOWNLOAD_CONCURRENCY, async (folder) => {
    try {
      const file = bucket().file(`${folder}/${COMPILED_WAYPOINTS_FILE}`);
      const [buf] = await file.download();
      const waypoints = JSON.parse(buf.toString("utf8")).waypoints || [];

      for (const w of waypoints) {
        const lat = Number(w.lat);
        const lng = Number(w.lon);
        if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;
        totalDrops++;

        const found = suburbFor(lat, lng, index);
        if (found < 0) {
          unmatchedDrops++;
          continue;
        }
        insideDrops++;

        let set = perSuburb.get(found);
        if (!set) perSuburb.set(found, (set = new Map()));
        const key = `${Math.round(lat / SNAP_DEGREES)}:${Math.round(
          lng / SNAP_DEGREES
        )}`;
        if (!set.has(key)) set.set(key, { lat, lng });
      }
    } catch (e) {
      console.warn(`[letterboxSeed] ${folder} failed: ${e.message}`);
      failedFolders.push(folder);
    }
  });

  console.log(
    `[letterboxSeed] classified ${totalDrops} drops in ${Date.now() - startedAt}ms — ` +
      `${insideDrops} inside a suburb, ${unmatchedDrops} outside any suburb, ` +
      `${perSuburb.size} suburbs touched`
  );

  // Existing metadata, so verified suburbs are protected rather than clobbered.
  const existingSnap = await db().collection("letterboxSuburbs").get();
  const existing = new Map();
  existingSnap.forEach((doc) => existing.set(doc.id, doc.data()));

  const written = [];
  const flaggedVerified = [];

  const writes = [];
  for (const [suburbIndex, positionMap] of perSuburb.entries()) {
    const suburb = index.suburbs[suburbIndex];
    const prior = existing.get(suburb.id);

    // Never overwrite a curated suburb — flag it for human review instead.
    if (prior && prior.status === "verified") {
      flaggedVerified.push(suburb.id);
      writes.push({
        id: suburb.id,
        data: { hasNewCandidates: true, updatedAt: admin.firestore.FieldValue.serverTimestamp() },
        merge: true,
      });
      continue;
    }

    const positions = [...positionMap.values()];
    if (!dryRun) {
      const gz = await encodePayload(suburb.id, suburb.name, positions);
      await bucket()
        .file(`letterboxes/${suburb.id}.json.gz`)
        .save(gz, {
          contentType: "application/gzip",
          // no-cache, not max-age: these files are edited and re-read in the
          // same session by the curation tool, so a cached copy would show a
          // curator the version from before their own edit.
          metadata: { cacheControl: "no-cache" },
        });

      const b = boundsOf(positions.map((p) => ({ lat: p.lat, lng: p.lng })));
      writes.push({
        id: suburb.id,
        data: {
          suburbName: suburb.name,
          count: positions.length,
          status: "seeded",
          seededCount: positions.length,
          hasNewCandidates: false,
          storagePath: `letterboxes/${suburb.id}.json.gz`,
          storageBytes: gz.length,
          bounds: b,
          formatVersion: FORMAT_VERSION,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        merge: true,
      });
    }

    written.push({ suburbId: suburb.id, name: suburb.name, count: positions.length });
  }

  if (!dryRun) {
    for (let i = 0; i < writes.length; i += FIRESTORE_BATCH_LIMIT) {
      const batch = db().batch();
      for (const w of writes.slice(i, i + FIRESTORE_BATCH_LIMIT)) {
        batch.set(db().collection("letterboxSuburbs").doc(w.id), w.data, {
          merge: w.merge,
        });
      }
      await batch.commit();
    }
  }

  const elapsed = Date.now() - startedAt;
  console.log(
    `[letterboxSeed] DONE in ${elapsed}ms — ${written.length} suburbs seeded, ` +
      `${flaggedVerified.length} verified suburbs flagged, ${failedFolders.length} folders failed`
  );

  return {
    dryRun: !!dryRun,
    elapsedMs: elapsed,
    folders: folders.length,
    failedFolders,
    totalDrops,
    insideDrops,
    unmatchedDrops,
    suburbsSeeded: written.length,
    verifiedSuburbsFlagged: flaggedVerified,
    // Biggest first — the quickest way to spot a classification bug.
    top: written.sort((a, b) => b.count - a.count).slice(0, 20),
  };
}

/**
 * Seed the letterbox index.
 *
 * `dryRun: true` classifies and reports without writing anything — run it
 * first and check the totals before letting it write 613 files.
 * `folderPaths` restricts the pass to specific folders, for testing.
 */
exports.seedLetterboxIndex = onCall(
  { region: "us-central1", timeoutSeconds: 540, memory: "2GiB" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }
    const { folderPaths, dryRun } = request.data || {};
    return runSeed({ folderPaths, dryRun: !!dryRun });
  }
);

/**
 * Recount one suburb from its stored payload and repair the metadata document
 * if it has drifted. Cheap consistency check; safe to run on anything.
 */
exports.refreshLetterboxCount = onCall(
  { region: "us-central1", timeoutSeconds: 120 },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }
    const { suburbId } = request.data || {};
    if (!suburbId || typeof suburbId !== "string") {
      throw new HttpsError("invalid-argument", "suburbId is required.");
    }

    const file = bucket().file(`letterboxes/${suburbId}.json.gz`);
    const [exists] = await file.exists();
    if (!exists) {
      throw new HttpsError("not-found", `No payload for ${suburbId}.`);
    }

    const [gz] = await file.download();
    const payload = JSON.parse(zlib.gunzipSync(gz).toString("utf8"));
    if (payload.v !== FORMAT_VERSION) {
      throw new HttpsError(
        "failed-precondition",
        `Payload is format v${payload.v}; this function reads v${FORMAT_VERSION}.`
      );
    }

    const actual = (payload.pts || []).length / 2;
    const ref = db().collection("letterboxSuburbs").doc(suburbId);
    const snap = await ref.get();
    const recorded = snap.exists ? snap.data().count : null;

    if (recorded !== actual) {
      await ref.set(
        { count: actual, updatedAt: admin.firestore.FieldValue.serverTimestamp() },
        { merge: true }
      );
    }

    return { suburbId, recorded, actual, repaired: recorded !== actual };
  }
);
