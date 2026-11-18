/**
 * Server-side ZIP downloads for Cloud Files.
 *
 * The browser used to download every file into memory and zip it with Dart's
 * `archive` package — slow, single-threaded, and a 200 MB photo folder could
 * freeze or crash the tab. Here the files stream Storage → archiver → Storage
 * inside Google's network, and the client gets one tokenised download URL
 * the browser saves natively (real progress bar, no memory ceiling).
 *
 * Zips land in `downloads/{uid}/`, which firestore/storage rules leave
 * unlisted (fail-closed for the SDK); the download token URL works anyway.
 * Anything there older than DOWNLOAD_TTL_MS is swept on each call.
 * writeZipToStorage is shared with the month/year archive.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const archiver = require("archiver");
const crypto = require("crypto");

const REGION = "us-central1";
const ROOT_PATH = "Distribution";
const DOWNLOADS_PREFIX = "downloads/";
const DOWNLOAD_TTL_MS = 6 * 60 * 60 * 1000;
const MAX_PATHS = 500;
const MAX_FILES = 5000;

// Already-compressed formats are stored, not deflated again.
const STORE_EXTENSIONS = new Set(["jpg", "jpeg", "png", "webp", "heic", "mp4", "mov", "zip", "kmz", "gz", "pdf"]);

let deps = null;
function init(d) {
  deps = d;
}

function validPath(p) {
  return (
    typeof p === "string" &&
    p.startsWith(`${ROOT_PATH}/`) &&
    !p.split("/").some((s) => s === "" || s === "." || s === "..")
  );
}

const basename = (p) => p.split("/").pop();
const dirname = (p) => p.split("/").slice(0, -1).join("/");

function safeZipName(name) {
  const base = String(name || "Cloud Files")
    .replace(/\.zip$/i, "")
    .replace(/[\\/:*?"<>|\u0000-\u001f]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
  return `${base || "Cloud Files"}.zip`;
}

async function sweepOldDownloads(bucket) {
  try {
    const [files] = await bucket.getFiles({ prefix: DOWNLOADS_PREFIX });
    const cutoff = Date.now() - DOWNLOAD_TTL_MS;
    await Promise.all(
      files
        .filter((f) => new Date(f.metadata.timeCreated).getTime() < cutoff)
        .map((f) => f.delete().catch(() => {}))
    );
  } catch (e) {
    console.warn(`[cloudFilesZip] sweep failed: ${e.message}`);
  }
}

/** Append one stream and wait until archiver has fully consumed it, so only
 *  one Storage read is open at a time however many files there are. */
function appendAndWait(archive, stream, data) {
  return new Promise((resolve, reject) => {
    const done = (err) => {
      archive.off("entry", onEntry);
      archive.off("error", onError);
      stream.off("error", onError);
      err ? reject(err) : resolve();
    };
    const onEntry = () => done();
    const onError = (err) => done(err);
    archive.on("entry", onEntry);
    archive.on("error", onError);
    stream.on("error", onError);
    archive.append(stream, data);
  });
}

exports.cloudFilesZip = onCall(
  { region: REGION, timeoutSeconds: 540, memory: "1GiB" },
  async (request) => {
    const auth = request.auth;
    if (!auth || auth.token?.firebase?.sign_in_provider === "anonymous") {
      throw new HttpsError("unauthenticated", "Sign in to download files.");
    }
    const files = Array.isArray(request.data?.files) ? request.data.files : [];
    const folders = Array.isArray(request.data?.folders) ? request.data.folders : [];
    if (!files.length && !folders.length) {
      throw new HttpsError("invalid-argument", "Nothing to download.");
    }
    if (files.length + folders.length > MAX_PATHS) {
      throw new HttpsError("invalid-argument", `At most ${MAX_PATHS} items per download.`);
    }
    for (const p of [...files, ...folders]) {
      if (!validPath(p)) throw new HttpsError("invalid-argument", `Bad path: ${p}`);
    }

    const bucket = deps.getBucket();
    const entries = []; // { file, zipPath }
    const seen = new Set();
    const add = (file, zipPath) => {
      if (seen.has(zipPath)) return;
      seen.add(zipPath);
      entries.push({ file, zipPath });
    };

    for (const p of files) {
      const file = bucket.file(p);
      const [exists] = await file.exists();
      if (!exists) continue;
      const [metadata] = await file.getMetadata();
      file.metadata = metadata;
      add(file, basename(p));
    }
    for (const folder of folders) {
      const [objects] = await bucket.getFiles({ prefix: `${folder}/` });
      const parent = dirname(folder);
      for (const f of objects) {
        if (basename(f.name) === ".folder") continue;
        add(f, parent ? f.name.slice(parent.length + 1) : f.name);
      }
    }
    if (!entries.length) {
      throw new HttpsError("not-found", "Those folders are empty.");
    }
    if (entries.length > MAX_FILES) {
      throw new HttpsError("invalid-argument", `Too many files (${entries.length}); download a smaller folder.`);
    }

    await sweepOldDownloads(bucket);

    const zipName = safeZipName(request.data?.name);
    const result = await writeZipToStorage({
      bucket,
      entries,
      objectPath: `${DOWNLOADS_PREFIX}${auth.uid}/${Date.now()}_${zipName}`,
      zipName,
    });
    return { ...result, fileName: zipName };
  }
);

/**
 * Stream [entries] ({ file, zipPath }) into one ZIP at [objectPath] and
 * return a tokenised download URL for it. The object is served as an
 * attachment named [zipName], so opening the URL saves the file. Also used
 * by the month/year archive (cloud_archive.js).
 */
async function writeZipToStorage({ bucket, entries, objectPath, zipName, onProgress }) {
  const token = crypto.randomUUID();
  const asciiName = zipName.replace(/[^\x20-\x7e]/g, "_").replace(/"/g, "'");
  const out = bucket.file(objectPath).createWriteStream({
    resumable: true,
    metadata: {
      contentType: "application/zip",
      contentDisposition: `attachment; filename="${asciiName}"; filename*=UTF-8''${encodeURIComponent(zipName)}`,
      cacheControl: "private, max-age=0",
      metadata: { firebaseStorageDownloadTokens: token },
    },
  });

  const archive = archiver("zip", { zlib: { level: 6 } });
  const written = new Promise((resolve, reject) => {
    out.on("finish", resolve);
    out.on("error", reject);
    archive.on("error", reject);
  });
  archive.pipe(out);

  let sourceBytes = 0;
  for (let i = 0; i < entries.length; i++) {
    const { file, zipPath } = entries[i];
    const ext = zipPath.includes(".") ? zipPath.split(".").pop().toLowerCase() : "";
    sourceBytes += Number(file.metadata.size || 0);
    await appendAndWait(archive, file.createReadStream(), {
      name: zipPath,
      date: file.metadata.updated ? new Date(file.metadata.updated) : new Date(),
      store: STORE_EXTENSIONS.has(ext),
    });
    if (onProgress) await onProgress(i + 1, entries.length);
  }
  await archive.finalize();
  await written;

  return {
    url:
      `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/` +
      `${encodeURIComponent(objectPath)}?alt=media&token=${token}`,
    objectPath,
    fileCount: entries.length,
    sourceBytes,
    zipBytes: archive.pointer(),
  };
}

exports.writeZipToStorage = writeZipToStorage;
exports.init = init;
