/**
 * Month / year archive for Cloud Files (`Distribution/` in Firebase Storage).
 *
 * Archiving builds a ZIP of a month's raw files (GPX, photos, KML, PDFs …),
 * which the user downloads and extracts into whichever Google Drive folder
 * they like — the app never talks to Drive. Once they confirm the ZIP is
 * safe, the originals are removed and only what the maps need stays in
 * Storage: `_compiled_tracks.json`, `_compiled_waypoints.json`, and an
 * `_archive.json` manifest listing every file that went into the ZIP.
 *
 * Photos are the exception: they go into the ZIP AND stay in Cloud Files,
 * so there is a record at both ends — reports link clients to them. The
 * manifest's `copies` notes which version of each photo is already in an
 * archive, so archiving the month again zips only new or changed photos.
 *
 * A year is archived as one ZIP per month (each extracts to "Oct 2026/…"),
 * so no single job outgrows a function's time limit.
 *
 * Lifecycle of a `cloudArchives/{id}` doc:
 *   queued → building → ready ──confirm──▶ removing → archived
 *                         └──discard / 7 days──▶ discarded / expired
 *   (a year doc goes queued → split, and its months run as their own docs)
 *
 * Why the maps survive the removal:
 *   - the build recompiles each folder first, so every waypoint in
 *     `_compiled_waypoints.json` names its source GPX (`sourceFiles` + `fi`);
 *   - the manifest is written BEFORE any delete, and the compile
 *     (carriedArchivedEntries in index.js) carries archived GPX over from
 *     the compiled files instead of dropping them;
 *   - deletes are generation-matched against what went into the ZIP, so a
 *     file changed after the ZIP was built is kept, never lost.
 * The ZIP itself stays in Storage as a safety copy for SAFETY_COPY_DAYS.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const crypto = require("crypto");
const { writeZipToStorage } = require("./storage_zip");

const REGION = "us-central1";
const COLLECTION = "cloudArchives";
const MANIFEST_FILE = "_archive.json";
const FILE_FOLDERS_COLLECTION = "fileFolders";
const ARCHIVES_PREFIX = "archives/";
const READY_TTL_DAYS = 7;
const SAFETY_COPY_DAYS = 30;
const DAY_MS = 24 * 60 * 60 * 1000;

/** Photos: copied into the ZIP, never removed from Cloud Files. */
const PHOTO_RE = /\.(jpe?g|png|webp|gif|heic|heif)$/i;

const YEAR_RE = /^Distribution\/\d{4}$/;
const MONTH_RE = /^Distribution\/\d{4}\/[^/]+$/;

let deps = null;

/** Wire in helpers that live in index.js (compileGpxFolder, getBucket). */
function init(d) {
  deps = d;
}

const db = () => admin.firestore();
const FieldValue = admin.firestore.FieldValue;
const Timestamp = admin.firestore.Timestamp;

const basename = (p) => p.split("/").pop();
const dirname = (p) => p.split("/").slice(0, -1).join("/");
const pathHash = (p) => crypto.createHash("md5").update(p).digest("hex");

function levelOf(folderPath) {
  if (YEAR_RE.test(folderPath)) return "year";
  if (MONTH_RE.test(folderPath)) return "month";
  return null;
}

/** Files that go into the ZIP. Compiled JSON, the manifest and folder
 *  placeholders stay so maps load and the folders keep existing. */
function isArchivable(name) {
  return !name.startsWith("_compiled_") && name !== MANIFEST_FILE && name !== ".folder";
}

/** Whether a file is copied into the archive but kept in Cloud Files. */
function staysInCloudFiles(name) {
  return PHOTO_RE.test(name);
}

/**
 * The files an archive of [objects] should take: everything archivable,
 * except photos whose current version is already in an earlier archive
 * (they never leave Cloud Files, so without this every archive of the month
 * would zip them again).
 */
async function filesToArchive(bucket, objects) {
  const archivable = objects.filter((f) => isArchivable(basename(f.name)));
  const photoFolders = [...new Set(
    archivable.filter((f) => staysInCloudFiles(basename(f.name))).map((f) => dirname(f.name))
  )];
  const copiesByFolder = new Map();
  await mapLimit(photoFolders, 8, async (folder) => {
    const manifest = await readJson(bucket, `${folder}/${MANIFEST_FILE}`);
    copiesByFolder.set(folder, (manifest && manifest.copies) || {});
  });
  return archivable.filter((f) => {
    const name = basename(f.name);
    if (!staysInCloudFiles(name)) return true;
    const copy = (copiesByFolder.get(dirname(f.name)) || {})[name];
    return !copy || String(copy.generation) !== String(f.metadata.generation);
  });
}

function requireStaff(auth) {
  if (!auth || auth.token?.firebase?.sign_in_provider === "anonymous") {
    throw new HttpsError("unauthenticated", "Sign in to archive files.");
  }
}

/** "2026-10-19" in SAST — the date the archive was made. */
function sastDate(d = new Date()) {
  return new Date(d.getTime() + 2 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

async function mapLimit(items, limit, task) {
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      await task(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
}

async function readJson(bucket, path) {
  try {
    const [buf] = await bucket.file(path).download();
    return JSON.parse(buf.toString("utf-8"));
  } catch (e) {
    if (e && e.code === 404) return null;
    throw e;
  }
}

async function deletePrefix(bucket, prefix) {
  const [files] = await bucket.getFiles({ prefix });
  await Promise.all(files.map((f) => f.delete().catch(() => {})));
}

/** Read-modify-write a folder's manifest, generation-matched so two
 *  archives confirming into the same folder never overwrite each other. */
async function updateManifest(bucket, folder, mutate) {
  const path = `${folder}/${MANIFEST_FILE}`;
  for (let attempt = 0; attempt < 8; attempt++) {
    let manifest = { version: 1, folderPath: folder, files: {}, copies: {} };
    let generation = 0;
    try {
      const [meta] = await bucket.file(path).getMetadata();
      generation = Number(meta.generation);
      const [buf] = await bucket.file(path, { generation }).download();
      manifest = JSON.parse(buf.toString("utf-8"));
      manifest.files = manifest.files || {};
      manifest.copies = manifest.copies || {};
    } catch (e) {
      if (!(e && e.code === 404)) throw e;
      generation = 0;
    }
    mutate(manifest);
    manifest.updatedAt = new Date().toISOString();
    try {
      if (Object.keys(manifest.files).length === 0 &&
          Object.keys(manifest.copies).length === 0) {
        if (generation) await bucket.file(path).delete({ ifGenerationMatch: generation });
        return;
      }
      await bucket.file(path).save(JSON.stringify(manifest), {
        contentType: "application/json",
        resumable: false,
        metadata: { cacheControl: "no-cache" },
        preconditionOpts: { ifGenerationMatch: generation },
      });
      return;
    } catch (e) {
      if (e && (e.code === 412 || e.code === 404)) continue; // raced; re-read
      throw e;
    }
  }
  throw new Error(`Could not update ${path} — it kept changing`);
}

// ── Build ───────────────────────────────────────────────────────────────────

/** A year becomes one queued month doc per month that has archivable files. */
async function splitYear(ref, job, id) {
  const bucket = deps.getBucket();
  const [objects] = await bucket.getFiles({ prefix: `${job.folderPath}/` });
  const months = new Set();
  for (const f of await filesToArchive(bucket, objects)) {
    const rest = f.name.slice(job.folderPath.length + 1).split("/");
    if (rest.length >= 2) months.add(rest[0]);
  }
  if (!months.size) {
    await ref.update({ status: "empty", finishedAt: FieldValue.serverTimestamp() });
    return;
  }
  const sorted = [...months].sort();
  const batch = db().batch();
  for (const m of sorted) {
    batch.set(db().collection(COLLECTION).doc(), {
      folderPath: `${job.folderPath}/${m}`,
      level: "month",
      batchId: id,
      parentId: id,
      requestedBy: job.requestedBy,
      requestedByName: job.requestedByName || null,
      status: "queued",
      createdAt: FieldValue.serverTimestamp(),
    });
  }
  batch.update(ref, { status: "split", level: "year", months: sorted, partCount: sorted.length });
  await batch.commit();
}

async function buildMonth(ref, job, id) {
  const bucket = deps.getBucket();
  const folder = job.folderPath;
  const [objects] = await bucket.getFiles({ prefix: `${folder}/` });
  const files = await filesToArchive(bucket, objects);
  if (!files.length) {
    await ref.update({ status: "empty", level: "month", finishedAt: FieldValue.serverTimestamp() });
    return;
  }

  // Recompile every folder that has GPX so its compiled waypoints name their
  // source files — the compile after removal depends on it.
  const gpxFolders = [...new Set(
    files.filter((f) => f.name.toLowerCase().endsWith(".gpx")).map((f) => dirname(f.name))
  )];
  await ref.update({
    level: "month",
    stage: "compiling",
    totalFiles: files.length,
    photoFiles: files.filter((f) => staysInCloudFiles(basename(f.name))).length,
    sourceBytes: files.reduce((n, f) => n + Number(f.metadata.size || 0), 0),
  });
  await mapLimit(gpxFolders, 4, (f) => deps.compileGpxFolder(f));

  // Paths in the ZIP start at the month ("Oct 2026/Client/Round 1/x.gpx"),
  // so extracting it into a Drive year folder rebuilds the tree.
  const yearPath = dirname(folder);
  const zipName = `${basename(folder)} - CLM Cloud Files ${sastDate()}.zip`;
  const entries = files.map((f) => {
    // Pin the generation: the ZIP must hold exactly what removal deletes.
    const file = bucket.file(f.name, { generation: f.metadata.generation });
    file.metadata = f.metadata;
    return { file, zipPath: f.name.slice(yearPath.length + 1) };
  });

  let lastUpdate = 0;
  await ref.update({ stage: "zipping", zippedFiles: 0 });
  const zip = await writeZipToStorage({
    bucket,
    entries,
    objectPath: `${ARCHIVES_PREFIX}${id}/${zipName}`,
    zipName,
    onProgress: async (done) => {
      if (Date.now() - lastUpdate < 2000) return;
      lastUpdate = Date.now();
      await ref.update({ zippedFiles: done }).catch(() => {});
    },
  });

  await bucket.file(`${ARCHIVES_PREFIX}${id}/files.json`).save(
    JSON.stringify({
      folderPath: folder,
      files: files.map((f) => ({
        path: f.name,
        generation: String(f.metadata.generation),
        size: Number(f.metadata.size || 0),
        md5: f.metadata.md5Hash ? Buffer.from(f.metadata.md5Hash, "base64").toString("hex") : null,
        contentType: f.metadata.contentType || null,
        updated: f.metadata.updated || null,
        // Copied into the ZIP, left in Cloud Files.
        keep: staysInCloudFiles(basename(f.name)),
      })),
    }),
    { contentType: "application/json", resumable: false }
  );

  await ref.update({
    status: "ready",
    stage: FieldValue.delete(),
    zipName,
    zipPath: zip.objectPath,
    zipUrl: zip.url,
    zipBytes: zip.zipBytes,
    fileCount: zip.fileCount,
    zippedFiles: zip.fileCount,
    sourceBytes: zip.sourceBytes,
    readyAt: FieldValue.serverTimestamp(),
    expiresAt: Timestamp.fromMillis(Date.now() + READY_TTL_DAYS * DAY_MS),
  });
}

exports.processCloudArchive = onDocumentCreated(
  {
    document: `${COLLECTION}/{id}`,
    region: REGION,
    timeoutSeconds: 540,
    memory: "2GiB",
  },
  async (event) => {
    const ref = event.data.ref;
    const id = event.params.id;
    const job = await db().runTransaction(async (tx) => {
      const d = (await tx.get(ref)).data();
      if (!d || d.status !== "queued") return null;
      tx.update(ref, { status: "building", startedAt: FieldValue.serverTimestamp() });
      return d;
    });
    if (!job) return;

    const level = levelOf(job.folderPath || "");
    try {
      if (level === "year") await splitYear(ref, job, id);
      else if (level === "month") await buildMonth(ref, job, id);
      else throw new Error("Only a year or a month folder can be archived");
    } catch (e) {
      console.error(`[cloudArchive] build ${id} (${job.folderPath}) failed`, e);
      await deletePrefix(deps.getBucket(), `${ARCHIVES_PREFIX}${id}/`).catch(() => {});
      await ref.update({
        status: "error",
        error: `${e.message || e}`.slice(0, 500),
        finishedAt: FieldValue.serverTimestamp(),
      });
    }
  }
);

// ── Confirm: remove the originals ───────────────────────────────────────────

async function confirmOne(id, uid) {
  const ref = db().collection(COLLECTION).doc(id);
  const job = await db().runTransaction(async (tx) => {
    const d = (await tx.get(ref)).data();
    if (!d || d.status !== "ready") return null;
    tx.update(ref, { status: "removing", confirmedBy: uid, confirmedAt: FieldValue.serverTimestamp() });
    return d;
  });
  if (!job) return { id, skipped: true };

  const bucket = deps.getBucket();
  try {
    const snap = await readJson(bucket, `${ARCHIVES_PREFIX}${id}/files.json`);
    if (!snap || !Array.isArray(snap.files)) throw new Error("The archive's file list is missing");

    const byFolder = new Map();
    for (const f of snap.files) {
      const folder = dirname(f.path);
      if (!byFolder.has(folder)) byFolder.set(folder, []);
      byFolder.get(folder).push(f);
    }

    const now = new Date().toISOString();
    let removed = 0;
    let kept = 0;
    let removedBytes = 0;
    let photosKept = 0;
    await mapLimit([...byFolder.entries()], 4, async ([folder, all]) => {
      // Photos stay in Cloud Files; the manifest notes which version of each
      // is now in an archive, so the next archive skips it.
      const photos = all.filter((f) => f.keep || staysInCloudFiles(basename(f.path)));
      const files = all.filter((f) => !photos.includes(f));
      photosKept += photos.length;

      // Manifest first: the compile triggered by each delete reads it.
      await updateManifest(bucket, folder, (m) => {
        for (const f of photos) {
          m.copies[basename(f.path)] = {
            generation: f.generation,
            sizeBytes: f.size,
            archivedAt: now,
            archiveId: id,
            zipName: job.zipName,
          };
        }
        for (const f of files) {
          m.files[basename(f.path)] = {
            sizeBytes: f.size,
            md5: f.md5,
            contentType: f.contentType,
            originalUpdated: f.updated,
            archivedAt: now,
            archiveId: id,
            zipName: job.zipName,
          };
        }
      });

      const keptNames = [];
      const removedFiles = [];
      await mapLimit(files, 16, async (f) => {
        try {
          await bucket.file(f.path).delete({ ifGenerationMatch: Number(f.generation) });
          removedFiles.push(f);
        } catch (e) {
          if (e && e.code === 404) {
            removedFiles.push(f); // already gone — it is in the ZIP
          } else {
            // Changed since the ZIP was built (412) or a transient failure:
            // the live file stays and must not be listed as archived.
            keptNames.push(basename(f.path));
          }
        }
      });
      if (keptNames.length) {
        await updateManifest(bucket, folder, (m) => {
          for (const n of keptNames) delete m.files[n];
        });
      }
      removed += removedFiles.length;
      kept += keptNames.length;
      removedBytes += removedFiles.reduce((n, f) => n + f.size, 0);

      if (removedFiles.length) {
        const archivedFiles = {};
        for (const f of removedFiles) {
          archivedFiles[basename(f.path)] = {
            nameLower: basename(f.path).toLowerCase(),
            sizeBytes: f.size,
            contentType: f.contentType,
            archiveId: id,
            zipName: job.zipName,
            archivedAt: FieldValue.serverTimestamp(),
          };
        }
        await db().collection(FILE_FOLDERS_COLLECTION).doc(pathHash(folder)).set(
          { folderPath: folder, ancestorFolders: ancestorsOf(folder), archivedFiles },
          { merge: true }
        );
      }
    });

    await ref.update({
      status: "archived",
      removedFiles: removed,
      keptFiles: kept,
      photosKept,
      removedBytes,
      error: FieldValue.delete(),
      archivedAt: FieldValue.serverTimestamp(),
      expiresAt: Timestamp.fromMillis(Date.now() + SAFETY_COPY_DAYS * DAY_MS),
    });
    return { id, removed, kept, photosKept, removedBytes };
  } catch (e) {
    console.error(`[cloudArchive] confirm ${id} failed`, e);
    // Back to ready: confirming again is safe (already-removed files 404).
    await ref.update({ status: "ready", error: `${e.message || e}`.slice(0, 500) });
    return { id, error: `${e.message || e}` };
  }
}

function ancestorsOf(folderPath) {
  const out = [];
  let acc = "";
  for (const p of folderPath.split("/").filter(Boolean)) {
    acc = acc ? `${acc}/${p}` : p;
    out.push(acc);
  }
  return out;
}

async function discardOne(id) {
  const ref = db().collection(COLLECTION).doc(id);
  const ok = await db().runTransaction(async (tx) => {
    const d = (await tx.get(ref)).data();
    if (!d || !["ready", "error", "empty"].includes(d.status)) return false;
    tx.update(ref, {
      status: "discarded",
      zipUrl: FieldValue.delete(),
      finishedAt: FieldValue.serverTimestamp(),
    });
    return true;
  });
  if (ok) await deletePrefix(deps.getBucket(), `${ARCHIVES_PREFIX}${id}/`);
  return { id, discarded: ok };
}

exports.cloudArchive = onCall(
  { region: REGION, timeoutSeconds: 540, memory: "1GiB" },
  async (request) => {
    requireStaff(request.auth);
    const { action, archiveIds } = request.data || {};
    if (!Array.isArray(archiveIds) || !archiveIds.length || archiveIds.length > 24 ||
        archiveIds.some((x) => typeof x !== "string" || !/^[A-Za-z0-9]{1,64}$/.test(x))) {
      throw new HttpsError("invalid-argument", "archiveIds must be 1–24 archive ids");
    }
    const results = [];
    if (action === "confirm") {
      for (const id of archiveIds) results.push(await confirmOne(id, request.auth.uid));
    } else if (action === "discard") {
      for (const id of archiveIds) results.push(await discardOne(id));
    } else {
      throw new HttpsError("invalid-argument", `Unknown action: ${action}`);
    }
    return { results };
  }
);

// ── Daily sweep ─────────────────────────────────────────────────────────────

exports.sweepCloudArchives = onSchedule(
  { schedule: "every day 03:30", timeZone: "Africa/Johannesburg", region: REGION },
  async () => {
    const bucket = deps.getBucket();
    const expired = await db().collection(COLLECTION)
      .where("expiresAt", "<", Timestamp.now())
      .get();
    for (const doc of expired.docs) {
      const d = doc.data();
      if (d.zipDeleted) continue;
      await deletePrefix(bucket, `${ARCHIVES_PREFIX}${doc.id}/`);
      await doc.ref.update({
        zipDeleted: true,
        zipUrl: FieldValue.delete(),
        // Never confirmed: nothing was removed, the ZIP just lapses.
        ...(d.status === "ready" ? { status: "expired" } : {}),
      });
    }
    // A removal whose callable died goes back to ready; confirming again is
    // safe because files already removed simply 404.
    const removing = await db().collection(COLLECTION).where("status", "==", "removing").get();
    for (const doc of removing.docs) {
      const at = doc.data().confirmedAt;
      if (at && Date.now() - at.toMillis() > 60 * 60 * 1000) {
        await doc.ref.update({ status: "ready", error: "Removal was interrupted — confirm again to finish." });
      }
    }
    // A build whose function died (timeout / crash) never reaches ready.
    const stuck = await db().collection(COLLECTION).where("status", "==", "building").get();
    for (const doc of stuck.docs) {
      const started = doc.data().startedAt;
      if (started && Date.now() - started.toMillis() > 60 * 60 * 1000) {
        await deletePrefix(bucket, `${ARCHIVES_PREFIX}${doc.id}/`);
        await doc.ref.update({
          status: "error",
          error: "Building the ZIP did not finish — the month may be too large. Try again.",
        });
      }
    }
  }
);

exports.init = init;
exports.MANIFEST_FILE = MANIFEST_FILE;
