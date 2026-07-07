/**
 * One-shot backfill for the `fileFolders` Firestore collection — one doc per
 * folder, with every file in that folder stored as an entry in a `files`
 * map field. Reading "every file in a folder" then costs one document read
 * regardless of file count, and scoping a recursive search only costs one
 * read per folder in scope (not one per file) — see the "CLOUD FILE SEARCH
 * INDEX" section in index.js for the full rationale.
 *
 * New files are indexed automatically going forward by the
 * indexFileOnUpload/indexFileOnDelete Cloud Functions; this script only
 * needs to run once (or again if you ever need to rebuild the index from
 * scratch — it's idempotent, each folder doc is fully rebuilt from the
 * current Storage listing).
 *
 * Uses the active gcloud user token (same pattern as backfill_datasets.js)
 * rather than firebase-admin, so it doesn't require Application Default
 * Credentials to be configured locally.
 *
 * Run:  node functions/backfill_file_folders.js
 */

const { execSync } = require("child_process");
const crypto = require("crypto");

const PROJECT_ID = "clmschedule";
const BUCKET = "clmschedule.firebasestorage.app";
const STORAGE_API = "https://storage.googleapis.com/storage/v1";
const FIRESTORE_BATCH_WRITE_URL =
  `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents:batchWrite`;
const FILE_SEARCH_SKIP_PREFIXES = ["_compiled_"];

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

function fileFolderDocId(folderPath) {
  return crypto.createHash("md5").update(folderPath).digest("hex");
}

function shouldIndexFile(filePath) {
  if (!filePath.startsWith("Distribution/")) return false;
  const name = filePath.split("/").pop();
  if (!name || name === ".folder") return false;
  return !FILE_SEARCH_SKIP_PREFIXES.some((p) => name.startsWith(p));
}

function ancestorFoldersFor(folderPath) {
  const parts = folderPath.split("/").filter(Boolean);
  const out = [];
  let acc = "";
  for (const p of parts) {
    acc = acc ? `${acc}/${p}` : p;
    out.push(acc);
  }
  return out;
}

function splitFilePath(filePath) {
  const parts = filePath.split("/");
  const name = parts.pop();
  return { name, folderPath: parts.join("/") };
}

async function listAllFiles(token) {
  let files = [];
  let pageToken = null;
  do {
    const url =
      `${STORAGE_API}/b/${BUCKET}/o?prefix=${encodeURIComponent("Distribution/")}` +
      `&maxResults=1000${pageToken ? `&pageToken=${pageToken}` : ""}`;
    const r = await fetch(url, { headers: hdrs(token) });
    if (!r.ok) throw new Error(`Storage list: ${r.status} ${await r.text()}`);
    const d = await r.json();
    if (d.items) files = files.concat(d.items);
    pageToken = d.nextPageToken;
  } while (pageToken);
  return files;
}

function toFirestoreValue(v) {
  if (v == null) return { nullValue: null };
  if (typeof v === "string") return { stringValue: v };
  if (typeof v === "number") return { integerValue: String(Math.round(v)) };
  return { nullValue: null };
}

function buildFolderWrite(folderPath, fileMap) {
  const filesFields = {};
  for (const [name, entry] of Object.entries(fileMap)) {
    filesFields[name] = {
      mapValue: {
        fields: {
          nameLower: toFirestoreValue(entry.nameLower),
          sizeBytes: toFirestoreValue(entry.sizeBytes),
          contentType: toFirestoreValue(entry.contentType),
          updatedAt: { timestampValue: new Date().toISOString() },
        },
      },
    };
  }

  return {
    update: {
      name: `projects/${PROJECT_ID}/databases/(default)/documents/fileFolders/${fileFolderDocId(folderPath)}`,
      fields: {
        folderPath: toFirestoreValue(folderPath),
        ancestorFolders: {
          arrayValue: {
            values: ancestorFoldersFor(folderPath).map((p) => ({ stringValue: p })),
          },
        },
        files: { mapValue: { fields: filesFields } },
      },
    },
  };
}

async function batchWrite(token, writes) {
  const r = await fetch(FIRESTORE_BATCH_WRITE_URL, {
    method: "POST",
    headers: hdrs(token),
    body: JSON.stringify({ writes }),
  });
  if (!r.ok) throw new Error(`Firestore batchWrite: ${r.status} ${await r.text()}`);
  return r.json();
}

(async () => {
  const token = getToken();

  console.log("Listing files under Distribution/ ...");
  const files = await listAllFiles(token);
  const toIndex = files.filter((f) => shouldIndexFile(f.name));
  console.log(`Found ${files.length} objects, ${toIndex.length} to index.`);

  // Group files by folder — each folder becomes exactly one write.
  const folders = new Map(); // folderPath -> { [name]: fileEntry }
  for (const f of toIndex) {
    const { name, folderPath } = splitFilePath(f.name);
    if (!folders.has(folderPath)) folders.set(folderPath, {});
    folders.get(folderPath)[name] = {
      nameLower: name.toLowerCase(),
      sizeBytes: f.size ? Number(f.size) : null,
      contentType: f.contentType || null,
    };
  }
  console.log(`Grouped into ${folders.size} folders.`);

  const folderEntries = [...folders.entries()];
  const BATCH = 400; // Firestore batchWrite caps at 500 writes/request
  let written = 0;
  for (let i = 0; i < folderEntries.length; i += BATCH) {
    const slice = folderEntries.slice(i, i + BATCH);
    const writes = slice.map(([folderPath, fileMap]) => buildFolderWrite(folderPath, fileMap));
    const result = await batchWrite(token, writes);
    const failed = (result.status || []).filter((s) => s.code).length;
    written += slice.length - failed;
    console.log(`  batch ${i / BATCH + 1}: wrote ${slice.length - failed}/${slice.length} folders`);
  }

  console.log(`DONE — wrote ${written}/${folders.size} folder docs (${toIndex.length} files).`);
})().catch((e) => {
  console.error("Backfill failed:", e);
  process.exit(1);
});
