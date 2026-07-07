/**
 * One-shot backfill script — uses the active gcloud user token.
 * Run:  node functions/backfill_datasets.js
 */

const { execSync } = require("child_process");

const PROJECT_ID = "clmschedule";
const BUCKET = "clmschedule.firebasestorage.app";
const COMPILED_WAYPOINTS_FILE = "_compiled_waypoints.json";
const MAPS_DATASETS_API = "https://mapsplatformdatasets.googleapis.com/v1";
const FIRESTORE_API = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
const STORAGE_API = `https://storage.googleapis.com/storage/v1`;
const STORAGE_UPLOAD_API = `https://storage.googleapis.com/upload/storage/v1`;
const BATCH = 4;

function getToken() {
  return execSync("gcloud auth print-access-token --project=" + PROJECT_ID, {
    encoding: "utf-8",
  }).trim();
}

function hdrs(token) {
  return {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
    "X-Goog-User-Project": PROJECT_ID,
  };
}

// ── Firestore REST ────────────────────────────────────────────────────────

async function firestoreGet(token, docPath) {
  const r = await fetch(`${FIRESTORE_API}/${docPath}`, { headers: hdrs(token) });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`Firestore GET ${docPath}: ${r.status}`);
  return r.json();
}

async function firestoreSet(token, docPath, fields) {
  function toValue(v) {
    if (typeof v === "string") return { stringValue: v };
    if (typeof v === "number" && Number.isInteger(v)) return { integerValue: String(v) };
    if (typeof v === "number") return { doubleValue: v };
    return { nullValue: null };
  }
  const firestoreFields = {};
  for (const [k, v] of Object.entries(fields)) firestoreFields[k] = toValue(v);

  const r = await fetch(`${FIRESTORE_API}/${docPath}`, {
    method: "PATCH",
    headers: hdrs(token),
    body: JSON.stringify({ fields: firestoreFields }),
  });
  if (!r.ok) throw new Error(`Firestore PATCH ${docPath}: ${r.status} ${await r.text()}`);
}

// ── Cloud Storage REST ────────────────────────────────────────────────────

async function storageListFiles(token, prefix) {
  let files = [], pageToken = null;
  do {
    const url = `${STORAGE_API}/b/${BUCKET}/o?prefix=${encodeURIComponent(prefix)}&maxResults=1000${pageToken ? `&pageToken=${pageToken}` : ""}`;
    const r = await fetch(url, { headers: hdrs(token) });
    if (!r.ok) throw new Error(`Storage list: ${r.status}`);
    const d = await r.json();
    if (d.items) files = files.concat(d.items.map((i) => i.name));
    pageToken = d.nextPageToken;
  } while (pageToken);
  return files;
}

async function storageDownload(token, objectPath) {
  const url = `${STORAGE_API}/b/${BUCKET}/o/${encodeURIComponent(objectPath)}?alt=media`;
  const r = await fetch(url, { headers: hdrs(token) });
  if (!r.ok) throw new Error(`Storage download: ${r.status}`);
  return r.text();
}

async function storageUpload(token, objectPath, content, contentType) {
  const url = `${STORAGE_UPLOAD_API}/b/${BUCKET}/o?uploadType=media&name=${encodeURIComponent(objectPath)}`;
  const r = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": contentType, "X-Goog-User-Project": PROJECT_ID },
    body: content,
  });
  if (!r.ok) throw new Error(`Storage upload: ${r.status} ${await r.text()}`);
}

// ── Dataset helpers ───────────────────────────────────────────────────────

function docId(folderPath) {
  return folderPath.trim().replace(/[^a-zA-Z0-9]/g, "_").replace(/_+/g, "_");
}

// Build a unique display name, capped at 63 UTF-8 bytes (API hard limit)
function displayName(folderPath) {
  const parts = folderPath.split("/").filter(Boolean);
  // Use last 2 segments + ASCII separators (avoids multi-byte em-dash/middot)
  let name = "Waypoints - " + parts.slice(-2).join(" / ");
  while (Buffer.byteLength(name, "utf8") >= 64) {
    name = name.slice(0, -4) + "...";
  }
  return name;
}

// List all datasets in the project and find by exact display name
async function findDatasetByName(token, name) {
  let pageToken = null;
  do {
    const url = `${MAPS_DATASETS_API}/projects/${PROJECT_ID}/datasets?pageSize=100${pageToken ? `&pageToken=${pageToken}` : ""}`;
    const r = await fetch(url, { headers: hdrs(token) });
    if (!r.ok) return null;
    const d = await r.json();
    const match = (d.datasets || []).find((ds) => ds.displayName === name);
    if (match) return match; // { name, displayName, ... }
    pageToken = d.nextPageToken;
  } while (pageToken);
  return null;
}

async function syncDataset(token, folderPath, waypoints) {
  const id = docId(folderPath);
  const dName = displayName(folderPath);

  // Check Firestore for an existing dataset record
  const existing = await firestoreGet(token, `cloudDatasets/${id}`);
  let datasetFullName = existing?.fields?.datasetFullName?.stringValue || null;

  if (!datasetFullName) {
    // Try to create a new dataset
    const createResp = await fetch(`${MAPS_DATASETS_API}/projects/${PROJECT_ID}/datasets`, {
      method: "POST",
      headers: hdrs(token),
      body: JSON.stringify({
        displayName: dName,
        description: `Auto-compiled from ${folderPath}`,
        usage: ["USAGE_DATA_DRIVEN_STYLING"],
      }),
    });

    if (createResp.status === 409) {
      // Dataset already exists (from a previous failed run) — look it up by display name
      const found = await findDatasetByName(token, dName);
      if (!found) throw new Error(`409 conflict but dataset '${dName}' not found in list`);
      datasetFullName = found.name;
    } else if (!createResp.ok) {
      throw new Error(`Create dataset: ${createResp.status} ${await createResp.text()}`);
    } else {
      const ds = await createResp.json();
      // ds.name uses project NUMBER e.g. "projects/346281153032/datasets/{uuid}"
      datasetFullName = ds.name;
    }
  }

  const datasetId = datasetFullName.split("/").pop();

  // Persist the dataset record immediately so the Flutter app switches to
  // viewport-marker mode (spatial index + letterbox.png, zero large marker set).
  // Import is attempted below — if it fails the tile overlay won't show, but
  // the zero-Marker performance fix still activates.
  await firestoreSet(token, `cloudDatasets/${id}`, {
    datasetId,
    datasetFullName,
    folderPath,
    featureCount: waypoints.length,
  });

  // Upload GeoJSON to Cloud Storage then kick off dataset import.
  // importDataset is in Preview and may be access-gated; errors are logged
  // but do not block the Firestore record above.
  try {
    const geojson = JSON.stringify({
      type: "FeatureCollection",
      features: waypoints.map((w, i) => ({
        type: "Feature",
        geometry: { type: "Point", coordinates: [w.lon, w.lat] },
        properties: { id: `wpt_${i}`, name: w.name || "", desc: w.desc || "" },
      })),
    });
    const gcsPath = `_dataset_imports/${id}.geojson`;
    await storageUpload(token, gcsPath, geojson, "application/geo+json");

    const importUrl = `${MAPS_DATASETS_API}/${datasetFullName}:importDataset`;
    const ir = await fetch(importUrl, {
      method: "POST",
      headers: hdrs(token),
      body: JSON.stringify({
        gcsSource: {
          inputUris: [`gs://${BUCKET}/${gcsPath}`],
          fileFormat: "FILE_FORMAT_GEOJSON",
        },
      }),
    });
    if (!ir.ok) {
      const body = await ir.text();
      process.stdout.write(`     (import ${ir.status} — tile overlay unavailable until API access granted)\n`);
    } else {
      process.stdout.write(`     (import started — tiles will appear once operation completes)\n`);
    }
  } catch (e) {
    process.stdout.write(`     (import error: ${e.message})\n`);
  }

  return datasetId;
}

// ── Main ──────────────────────────────────────────────────────────────────

async function main() {
  const token = getToken();
  console.log("Token obtained\n");

  const allFiles = await storageListFiles(token, "Distribution/");
  const folders = [
    ...new Set(
      allFiles
        .filter((f) => f.endsWith(`/${COMPILED_WAYPOINTS_FILE}`))
        .map((f) => f.replace(`/${COMPILED_WAYPOINTS_FILE}`, ""))
    ),
  ];
  console.log(`Found ${folders.length} folders\n`);

  const synced = [], skipped = [], errors = [];

  for (let i = 0; i < folders.length; i += BATCH) {
    const batch = folders.slice(i, i + BATCH);
    await Promise.all(
      batch.map(async (folderPath) => {
        const num = folders.indexOf(folderPath) + 1;
        try {
          const raw = await storageDownload(token, `${folderPath}/${COMPILED_WAYPOINTS_FILE}`);
          const waypoints = JSON.parse(raw).waypoints || [];
          if (waypoints.length === 0) {
            skipped.push(folderPath);
            process.stdout.write(`  –  [${num}/${folders.length}] ${folderPath.split("/").slice(-2).join("/")} (0 waypoints)\n`);
            return;
          }
          const datasetId = await syncDataset(token, folderPath, waypoints);
          synced.push({ folderPath, datasetId, count: waypoints.length });
          process.stdout.write(`  ✓  [${num}/${folders.length}] ${folderPath.split("/").slice(-2).join("/")}  (${waypoints.length} pts → ${datasetId})\n`);
        } catch (e) {
          errors.push({ folderPath, error: e.message });
          process.stdout.write(`  ✗  [${num}/${folders.length}] ${folderPath.split("/").slice(-2).join("/")}  ${e.message}\n`);
        }
      })
    );
  }

  console.log(`\n${"─".repeat(60)}`);
  console.log(`  Synced : ${synced.length}`);
  console.log(`  Skipped: ${skipped.length}`);
  console.log(`  Errors : ${errors.length}`);
  if (errors.length) {
    console.log("\nFailed:");
    errors.forEach((e) => console.log(`  • ${e.folderPath.split("/").slice(-2).join("/")}: ${e.error}`));
  }
}

main().catch((e) => { console.error("Fatal:", e.message); process.exit(1); });
