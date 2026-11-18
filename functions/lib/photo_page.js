/**
 * Public photo gallery for a CLM Maps share code (/photos/{shareCode}).
 *
 * The Flyers & Posters report links the client to the photos of every place
 * a poster went up. Cloud Files is sign-in only, so this page lists the
 * images in the map's cloud folders instead — keyed by the map's own share
 * code, so the photos link and the poster-map link always belong together.
 *
 * Plain server-rendered HTML rather than the Flutter shell: mail scanners
 * (see map_page.js) read it without JavaScript, and a gallery needs nothing
 * Flutter offers.
 *
 * Images are served by this function too, at /photos/{code}/img/{id}, so the
 * page never shows a Firebase Storage address or a folder path: a client
 * sees only our own domain and an opaque id. The id is a hash of the file's
 * path and generation, so a replaced photo gets a new URL and the CDN can
 * cache every image as immutable.
 *
 * The grid shows thumbnails (/photos/{code}/thumb/{id}, ~600×800 JPEG, tens
 * of KB instead of a phone's several MB). Each is made the first time it is
 * asked for and kept in Storage under photoThumbnails/ (private; read only
 * through here). The viewer opens on the thumbnail and swaps in the full
 * photo once it has loaded.
 *
 * Hosting rewrites /photos/** here (firebase.json, `maps` target).
 */

const crypto = require("crypto");
const { onRequest } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const COMPANY = "Community Life Media";

/**
 * The company logo as Hosting serves it. Flutter web bundles app assets
 * under `assets/` again, so it is /assets/assets/… — /assets/clm-official-
 * logo.jpeg falls through to the app's index.html and renders as a broken
 * image (and an empty link preview).
 */
const LOGO_PATH = "/assets/assets/clm-official-logo.jpeg";

const CODE_RE = /^[A-Za-z0-9_-]{4,64}$/;
const ID_RE = /^[A-Za-z0-9_-]{8,64}$/;
const IMAGE_RE = /\.(jpe?g|png|webp)$/i;

/** Only folders under the public-read prefix are ever listed. */
const PUBLIC_PREFIX = "Distribution/";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** Where thumbnails are kept, by photo id. Outside Distribution/, so Cloud
 * Files and the archive never see them, and private under storage.rules. */
const THUMB_PREFIX = "photoThumbnails/";

/** Thumbnail box: sharp on a high-density screen at the grid's widest tile. */
const THUMB_WIDTH = 600;
const THUMB_HEIGHT = 800;

let _sharp = null;
/** sharp, loaded on the first thumbnail — the gallery page never needs it. */
function sharp() {
  if (!_sharp) {
    _sharp = require("sharp");
    // One resize at a time per request, no op cache: a phone photo decodes to
    // ~40 MB, and requests already run side by side.
    _sharp.cache(false);
    _sharp.concurrency(1);
  }
  return _sharp;
}

/** Gallery listings kept per instance, so a page of 40 thumbnails does not
 * re-read Firestore and re-list Storage 40 times. Short, because photos are
 * added while a report is being prepared. */
const LISTING_TTL_MS = 60 * 1000;
const _listings = new Map();

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Origin to print in links — only hosts we actually serve. */
function originFor(req) {
  const allowed = new Set([
    "clm-maps.web.app",
    "clm-maps.firebaseapp.com",
    "maps.communitylifemedia.co.za",
  ]);
  const host = String(req.get("x-forwarded-host") || req.hostname || "").toLowerCase();
  return `https://${allowed.has(host) ? host : "clm-maps.web.app"}`;
}

/**
 * What a clmgpx photo's file name says about it.
 *
 * `Petros_Poster 501_2026-10-22_12-37-26.jpg` → who "Petros", what
 * "Poster 501", when 2026-10-22 12:37. clmgpx strips `_` from every part,
 * so splitting on it is safe; the date and time are always the last two.
 * Anything else (a phone's IMG_2041.jpg) keeps its name as the caption.
 */
function parsePhotoName(fileName) {
  const base = fileName.split("/").pop();
  const stem = base.replace(/\.[^.]+$/, "");
  const parts = stem.split("_");
  const n = parts.length;
  const date = n >= 4 ? /^(\d{4})-(\d{2})-(\d{2})$/.exec(parts[n - 2]) : null;
  const time = n >= 4 ? /^(\d{2})-(\d{2})-(\d{2})$/.exec(parts[n - 1]) : null;
  if (!date || !time) {
    return { who: "", what: stem, when: "", date: "", time: "", sortKey: `~${stem.toLowerCase()}` };
  }
  const who = parts[0] === "Unknown" ? "" : parts[0];
  const what = parts.slice(1, n - 2).join(" - ");
  const month = MONTHS[Number(date[2]) - 1] || date[2];
  return {
    who,
    what,
    when: `${Number(date[3])} ${month} ${date[1]}, ${time[1]}:${time[2]}`,
    date: `${date[1]}-${date[2]}-${date[3]}`,
    time: `${time[1]}:${time[2]}:${time[3]}`,
    // Chronological: two distributors both have a "Poster 1".
    sortKey: `${date[1]}${date[2]}${date[3]}${time[1]}${time[2]}${time[3]}|${who}`,
  };
}

/** Opaque, URL-safe id for one version of one file. */
function photoId(path, generation) {
  return crypto.createHash("sha256")
    .update(`${path}#${generation || ""}`)
    .digest("base64url")
    .slice(0, 22);
}

async function lookupMap(code) {
  const db = admin.firestore();
  const link = await db.collection("mapLinks").doc(code).get();
  if (!link.exists) return null;

  const { monthKey, mapId, mapName } = link.data() || {};
  if (!monthKey || !mapId) return null;

  const mapRef = db.collection("shareableMaps").doc(monthKey).collection("maps").doc(mapId);
  const [map] = await db.getAll(mapRef, {
    fieldMask: ["name", "cloudFolderPaths", "storageFolderPath"],
  });
  if (!map.exists) return null;

  const data = map.data() || {};
  const folders = new Set(
    [...(Array.isArray(data.cloudFolderPaths) ? data.cloudFolderPaths : []), data.storageFolderPath]
      .filter((p) => typeof p === "string" && p.startsWith(PUBLIC_PREFIX))
      .map((p) => p.replace(/\/+$/, "")),
  );
  return { name: String(data.name || mapName || "Poster map").trim(), folders: [...folders] };
}

/** Every image under [folders] (subfolders included), de-duplicated, with
 * the opaque id it is served under. */
async function listPhotos(bucket, folders) {
  const listed = await Promise.all(
    folders.map((f) => bucket.getFiles({ prefix: `${f}/` }).then(([files]) => files)),
  );
  const byPath = new Map();
  for (const file of listed.flat()) {
    if (!IMAGE_RE.test(file.name)) continue;
    const meta = file.metadata || {};
    byPath.set(file.name, {
      path: file.name,
      id: photoId(file.name, meta.generation),
      contentType: meta.contentType || "image/jpeg",
      size: Number(meta.size) || 0,
    });
  }
  return [...byPath.values()];
}

/** The map and its photos for [code], or null for an unknown code. */
async function galleryFor(code, bucket) {
  const hit = _listings.get(code);
  if (hit && Date.now() - hit.at < LISTING_TTL_MS) return hit.value;
  const map = await lookupMap(code);
  const value = map ? { map, photos: await listPhotos(bucket, map.folders) } : null;
  _listings.set(code, { at: Date.now(), value });
  return value;
}

function sortedForDisplay(photos) {
  return photos
    .map((p) => ({ ...p, ...parsePhotoName(p.path) }))
    .sort((a, b) => (a.sortKey < b.sortKey ? -1 : a.sortKey > b.sortKey ? 1 : 0));
}

function page({ title, body, origin, script = "" }) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title}</title>
  <meta name="description" content="Photos of poster placements prepared by ${escapeHtml(COMPANY)}, Cape Town.">
  <meta property="og:title" content="${title}">
  <meta property="og:site_name" content="${escapeHtml(COMPANY)}">
  <meta property="og:image" content="${origin}${LOGO_PATH}">
  <meta name="robots" content="noindex, nofollow">
  <meta name="referrer" content="no-referrer">
  <style>
    :root { --bg:#f6f7f9; --card:#fff; --text:#1d2330; --muted:#5d6675; --line:#e2e5ea; --accent:#1f6feb; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#14171c; --card:#1d2129; --text:#e8eaee; --muted:#9aa3b2; --line:#2c323d; --accent:#58a6ff; }
    }
    * { box-sizing: border-box; }
    html { -webkit-font-smoothing: antialiased; }
    body { margin:0; background:var(--bg); color:var(--text);
      font:15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif; }
    header { padding:20px 16px 12px; max-width:1200px; margin:0 auto; display:flex; gap:14px; align-items:center; flex-wrap:wrap; }
    /* The logo is wide (about 2:1): keep its shape, never crop it square. */
    header img { height:48px; width:auto; max-width:160px; aspect-ratio:591 / 300;
      object-fit:contain; border-radius:6px; }
    header .t { flex:1 1 240px; min-width:0; }
    h1 { font-size:20px; margin:0; overflow-wrap:anywhere; text-wrap:balance; }
    .sub { color:var(--muted); font-size:13px; }
    .btn { display:inline-block; padding:8px 14px; border-radius:8px; background:var(--accent); color:#fff; text-decoration:none; font-weight:600; font-size:14px; }
    main { max-width:1200px; margin:0 auto; padding:4px 16px 32px; }
    .grid { display:grid; gap:12px; grid-template-columns:repeat(auto-fill, minmax(170px, 1fr)); }
    figure { margin:0; background:var(--card); border:1px solid var(--line); border-radius:10px; overflow:hidden; }
    figure a { display:block; aspect-ratio:3/4; background:var(--line); cursor:zoom-in; }
    figure img { width:100%; height:100%; object-fit:cover; display:block; outline:1px solid rgba(0,0,0,.08); outline-offset:-1px; }
    figcaption { padding:8px 10px; font-size:12px; color:var(--muted); }
    figcaption b { color:var(--text); font-weight:600; display:block; overflow-wrap:anywhere; }
    .empty { padding:48px 16px; text-align:center; color:var(--muted); }
    footer { text-align:center; color:var(--muted); font-size:12px; padding:0 16px 24px; }

    /* Viewer */
    .viewer { position:fixed; inset:0; z-index:10; background:#0b0d12; display:none;
      flex-direction:column; color:#fff; }
    .viewer.open { display:flex; }
    .bar { display:flex; align-items:center; gap:6px; padding:10px 12px; flex-wrap:wrap;
      background:#0b0d12; position:relative; z-index:1; }
    .bar .cap { flex:1 1 200px; min-width:0; font-size:13px; line-height:1.35; }
    .bar .cap b { display:block; font-size:14px; overflow-wrap:anywhere; }
    .bar .cap span { color:#b8c0cc; font-variant-numeric:tabular-nums; }
    .ib { width:44px; height:44px; border:0; border-radius:10px; background:rgba(255,255,255,.1); color:#fff;
      font-size:20px; line-height:44px; text-align:center; cursor:pointer; text-decoration:none;
      transition-property:background-color, transform; transition-duration:150ms; }
    .ib:hover { background:rgba(255,255,255,.2); }
    .ib:active { transform:scale(.96); }
    .ib:focus-visible { outline:2px solid #58a6ff; outline-offset:2px; }
    .zoomv { min-width:52px; text-align:center; font-size:13px; color:#b8c0cc; font-variant-numeric:tabular-nums; }
    .stage { flex:1; position:relative; overflow:hidden; touch-action:none; }
    /* Fills the stage either way, so the full photo replacing the thumbnail
       sharpens the picture without changing its size. */
    .stage img { position:absolute; left:0; top:0; width:100%; height:100%; object-fit:contain;
      transform:translate(0, 0) scale(1); transform-origin:center; user-select:none; -webkit-user-drag:none; }
    .loading { position:absolute; left:50%; bottom:16px; transform:translateX(-50%); font-size:12px;
      color:#d6dbe3; background:rgba(0,0,0,.55); padding:6px 12px; border-radius:999px; pointer-events:none; }
    .stage.zoomed { cursor:grab; }
    .stage.dragging { cursor:grabbing; }
    .nav { position:absolute; top:50%; transform:translateY(-50%); }
    .nav.prev { left:10px; } .nav.next { right:10px; }
    @media (max-width: 560px) {
      /* Caption on its own line, the controls together under it. */
      .bar .cap { flex-basis:100%; }
      .bar .cap span { display:block; }
    }
    @media (prefers-reduced-motion: reduce) { .ib { transition:none; } }
  </style>
</head>
<body>
${body}
<footer>Prepared by ${escapeHtml(COMPANY)}, Cape Town</footer>
${script}
</body>
</html>`;
}

/** Full-screen viewer: zoom in/out, drag to pan when zoomed, previous/next,
 * download and close. Keyboard: Esc, ←/→, +/−. Images come from our own
 * /img/ URLs only. */
const VIEWER_SCRIPT = `<script>
(function () {
  var photos = JSON.parse(document.getElementById('photo-data').textContent);
  var v = document.getElementById('viewer'), img = document.getElementById('v-img'),
      stage = document.getElementById('v-stage'), title = document.getElementById('v-title'),
      meta = document.getElementById('v-meta'), zoomv = document.getElementById('v-zoom'),
      dl = document.getElementById('v-download'), loading = document.getElementById('v-loading');
  var i = 0, scale = 1, x = 0, y = 0, last = null, opener = null, token = 0;
  var STEPS = [1, 1.5, 2, 3, 4];

  function apply() {
    img.style.transform = 'translate(' + x + 'px, ' + y + 'px) scale(' + scale + ')';
    zoomv.textContent = Math.round(scale * 100) + '%';
    stage.classList.toggle('zoomed', scale > 1);
  }
  function reset() { scale = 1; x = 0; y = 0; apply(); }
  function show(n) {
    i = (n + photos.length) % photos.length;
    var p = photos[i], t = ++token;
    // The thumbnail at once (already loaded by the grid), then the full photo
    // once it has downloaded — unless the user has moved on meanwhile.
    img.src = p.thumb; img.alt = p.title;
    loading.textContent = 'Loading full size…'; loading.hidden = false;
    var full = new Image();
    full.onload = function () { if (t !== token) return; img.src = p.src; loading.hidden = true; };
    full.onerror = function () { if (t === token) loading.textContent = 'Full size could not load'; };
    full.src = p.src;
    title.textContent = p.title;
    meta.textContent = [p.meta, (i + 1) + ' of ' + photos.length].filter(Boolean).join(' · ');
    dl.href = p.download;
    reset();
  }
  function open(n) {
    opener = document.activeElement;
    v.classList.add('open'); document.body.style.overflow = 'hidden';
    show(n);
    document.getElementById('v-close').focus();
  }
  function close() {
    v.classList.remove('open'); document.body.style.overflow = '';
    token++;
    img.removeAttribute('src');
    if (opener) opener.focus();
  }
  function zoom(dir) {
    var at = STEPS.indexOf(scale); if (at < 0) at = 0;
    scale = STEPS[Math.max(0, Math.min(STEPS.length - 1, at + dir))];
    if (scale === 1) { x = 0; y = 0; }
    apply();
  }

  document.querySelectorAll('[data-photo]').forEach(function (a) {
    a.addEventListener('click', function (e) { e.preventDefault(); open(Number(a.dataset.photo)); });
  });
  document.getElementById('v-close').onclick = close;
  document.getElementById('v-in').onclick = function () { zoom(1); };
  document.getElementById('v-out').onclick = function () { zoom(-1); };
  document.getElementById('v-prev').onclick = function () { show(i - 1); };
  document.getElementById('v-next').onclick = function () { show(i + 1); };
  if (photos.length < 2) {
    document.getElementById('v-prev').hidden = true;
    document.getElementById('v-next').hidden = true;
  }

  stage.addEventListener('wheel', function (e) { e.preventDefault(); zoom(e.deltaY < 0 ? 1 : -1); }, { passive: false });
  stage.addEventListener('dblclick', function () { if (scale > 1) reset(); else zoom(2); });
  stage.addEventListener('pointerdown', function (e) {
    if (scale <= 1) return;
    last = { x: e.clientX, y: e.clientY }; stage.classList.add('dragging');
    stage.setPointerCapture(e.pointerId);
  });
  stage.addEventListener('pointermove', function (e) {
    if (!last) return;
    x += e.clientX - last.x; y += e.clientY - last.y; last = { x: e.clientX, y: e.clientY };
    apply();
  });
  function endDrag() { last = null; stage.classList.remove('dragging'); }
  stage.addEventListener('pointerup', endDrag);
  stage.addEventListener('pointercancel', endDrag);

  document.addEventListener('keydown', function (e) {
    if (!v.classList.contains('open')) return;
    if (e.key === 'Escape') close();
    else if (e.key === 'ArrowLeft') show(i - 1);
    else if (e.key === 'ArrowRight') show(i + 1);
    else if (e.key === '+' || e.key === '=') zoom(1);
    else if (e.key === '-') zoom(-1);
  });
})();
</script>`;

function renderGallery({ mapName, code, origin, photos }) {
  const sorted = sortedForDisplay(photos);
  const name = escapeHtml(mapName);
  const count = sorted.length === 1 ? "1 photo" : `${sorted.length} photos`;
  const root = `/photos/${encodeURIComponent(code)}`;
  const full = (p) => `${root}/img/${p.id}`;
  const thumb = (p) => `${root}/thumb/${p.id}`;

  const tiles = sorted.map((p, i) => {
    const what = escapeHtml(p.what || "Photo");
    const meta = [p.who, p.when].filter(Boolean).map(escapeHtml).join(" · ");
    // Without JavaScript the link still opens the full photo — on our domain.
    return `<figure><a href="${full(p)}" data-photo="${i}" aria-label="Open ${what}">` +
      `<img src="${thumb(p)}" alt="${what}" loading="lazy" decoding="async"></a>` +
      `<figcaption><b>${what}</b>${meta}</figcaption></figure>`;
  }).join("\n");

  // Read by the viewer. `<` escaped so nothing in a caption can end the
  // script element.
  const data = JSON.stringify(sorted.map((p) => ({
    thumb: thumb(p),
    src: full(p),
    download: `${full(p)}?download=1`,
    title: p.what || "Photo",
    meta: [p.who, p.when].filter(Boolean).join(" · "),
  }))).replace(/</g, "\\u003c");

  const viewer = `<div class="viewer" id="viewer" role="dialog" aria-modal="true" aria-label="Photo viewer">
  <div class="bar">
    <div class="cap"><b id="v-title"></b><span id="v-meta"></span></div>
    <button class="ib" id="v-out" type="button" aria-label="Zoom out" title="Zoom out">&minus;</button>
    <span class="zoomv" id="v-zoom">100%</span>
    <button class="ib" id="v-in" type="button" aria-label="Zoom in" title="Zoom in">+</button>
    <a class="ib" id="v-download" href="#" aria-label="Download" title="Download">&#8681;</a>
    <button class="ib" id="v-close" type="button" aria-label="Close" title="Close (Esc)">&times;</button>
  </div>
  <div class="stage" id="v-stage">
    <img id="v-img" alt="" draggable="false">
    <div class="loading" id="v-loading" hidden></div>
    <button class="ib nav prev" id="v-prev" type="button" aria-label="Previous photo">&#8249;</button>
    <button class="ib nav next" id="v-next" type="button" aria-label="Next photo">&#8250;</button>
  </div>
</div>
<script type="application/json" id="photo-data">${data}</script>`;

  const body = `<header>
  <img src="${origin}${LOGO_PATH}" alt="${escapeHtml(COMPANY)}" width="95" height="48">
  <div class="t"><h1>${name} — poster photos</h1><div class="sub">${count}. Tap a photo to view it full size.</div></div>
  <a class="btn" href="${origin}/map/${escapeHtml(code)}">View the poster map</a>
</header>
<main>
${sorted.length ? `<div class="grid">\n${tiles}\n</div>` : "<p class=\"empty\">No photos have been added yet.</p>"}
</main>
${sorted.length ? viewer : ""}`;

  return page({
    title: `${name} — poster photos – ${escapeHtml(COMPANY)}`,
    body,
    origin,
    script: sorted.length ? VIEWER_SCRIPT : "",
  });
}

function renderMessage({ heading, text, origin }) {
  return page({
    title: `${escapeHtml(heading)} – ${escapeHtml(COMPANY)}`,
    body: `<main><p class="empty"><b>${escapeHtml(heading)}</b><br>${escapeHtml(text)}</p></main>`,
    origin,
  });
}

/**
 * /photos/{code}/index.json — the gallery's photos as data, for the map
 * viewer to show a waypoint's photo in its info window. Ids and our own
 * URLs only: no Storage address, no folder path.
 */
function photoIndex(code, photos) {
  const root = `/photos/${encodeURIComponent(code)}`;
  return {
    photos: sortedForDisplay(photos).map((p) => ({
      id: p.id,
      who: p.who,
      what: p.what,
      date: p.date,
      time: p.time,
      // `?cors=1`: a separate CDN entry from the gallery's own images, which
      // may have been cached before they carried the CORS header the map
      // (another origin, rendering with fetch) needs.
      thumb: `${root}/thumb/${p.id}?cors=1`,
      src: `${root}/img/${p.id}?cors=1`,
      download: `${root}/img/${p.id}?download=1`,
    })),
  };
}

/** The map app may run on another of our hosts (the editor) and Flutter web
 * fetches images with CORS, so photos and the index are readable from any
 * origin — they are public already. */
const CORS = { "Access-Control-Allow-Origin": "*" };

/** `attachment; filename=...` for a download, ASCII fallback plus RFC 5987. */
function downloadDisposition(path) {
  const name = path.split("/").pop();
  const ascii = name.replace(/[^\x20-\x7E]/g, "_").replace(/"/g, "'");
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`;
}

/**
 * The thumbnail for [photo]: kept from an earlier request, or made now from
 * the original and kept. EXIF orientation is applied (phones store photos
 * sideways with a flag), and the result is a small baseline JPEG.
 */
async function thumbnailFor(bucket, photo) {
  const kept = bucket.file(`${THUMB_PREFIX}${photo.id}.jpg`);
  try {
    const [buf] = await kept.download();
    return buf;
  } catch (e) {
    if (!(e && e.code === 404)) throw e;
  }
  const [original] = await bucket.file(photo.path).download();
  const buf = await sharp()(original)
    .rotate()
    .resize({ width: THUMB_WIDTH, height: THUMB_HEIGHT, fit: "inside", withoutEnlargement: true })
    .jpeg({ quality: 72, mozjpeg: true })
    .toBuffer();
  // Kept for next time; failing to keep it only costs a resize later.
  kept.save(buf, { contentType: "image/jpeg", resumable: false })
    .catch((err) => console.error("[photoPage] could not keep thumbnail:", photo.id, err.message));
  return buf;
}

/**
 * /photos/{code}/img/{id} — one photo of the gallery, streamed from Storage —
 * or, with [thumb], /photos/{code}/thumb/{id}: its thumbnail.
 */
async function serveImage(req, res, bucket, code, id, origin, { thumb = false } = {}) {
  let gallery = null;
  try {
    gallery = await galleryFor(code, bucket);
  } catch (err) {
    console.error("[photoPage] image lookup failed:", code, err.message);
    res.status(503).set({ "Retry-After": "30", "Cache-Control": "no-store" }).send("Unavailable");
    return;
  }
  // Only ids of this gallery's own photos resolve — nothing else in Storage
  // can be reached through this URL.
  const photo = gallery && gallery.photos.find((p) => p.id === id);
  if (!photo) {
    res.status(404).set("Cache-Control", "public, max-age=60").send(renderMessage({
      heading: "Photo not found",
      text: "This photo is no longer available.",
      origin,
    }));
    return;
  }

  const cacheHeaders = {
    // The id changes when the file does, so a copy never goes stale.
    "Cache-Control": "public, max-age=86400, s-maxage=31536000, immutable",
    "X-Content-Type-Options": "nosniff",
    ...CORS,
  };

  if (thumb) {
    try {
      const buf = await thumbnailFor(bucket, photo);
      res.set({ ...cacheHeaders, "Content-Type": "image/jpeg", "Content-Length": String(buf.length) });
      if (req.method === "HEAD") res.status(200).end();
      else res.status(200).send(buf);
      return;
    } catch (err) {
      // A photo sharp cannot read still shows — at full size.
      console.error("[photoPage] thumbnail failed, sending the original:", photo.path, err.message);
    }
  }

  res.set({ ...cacheHeaders, "Content-Type": photo.contentType });
  if (photo.size) res.set("Content-Length", String(photo.size));
  if (req.query.download) res.set("Content-Disposition", downloadDisposition(photo.path));
  if (req.method === "HEAD") {
    res.status(200).end();
    return;
  }

  bucket.file(photo.path).createReadStream()
    .on("error", (err) => {
      console.error("[photoPage] stream failed:", photo.path, err.message);
      if (!res.headersSent) res.status(502).send("Unavailable");
      else res.end();
    })
    .pipe(res);
}

exports.photoPage = onRequest(
  // Thumbnails decode full phone photos, so more memory than an HTML page
  // needs, and a whole vCPU so requests can share an instance.
  { region: "us-central1", memory: "1GiB", cpu: 1, concurrency: 8, maxInstances: 10 },
  async (req, res) => {
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.status(405).set("Allow", "GET, HEAD").send("Method Not Allowed");
      return;
    }

    const segments = req.path.split("/").filter(Boolean);
    const code = segments[0] === "photos" && segments.length >= 2 ? segments[1] : "";
    const origin = originFor(req);
    const bucket = admin.storage().bucket();

    if (segments.length === 3 && segments[2] === "index.json" && CODE_RE.test(code)) {
      let gallery = null;
      try {
        gallery = await galleryFor(code, bucket);
      } catch (err) {
        console.error("[photoPage] index failed:", code, err.message);
        res.status(503).set({ ...CORS, "Cache-Control": "no-store" }).json({ photos: [] });
        return;
      }
      res.status(gallery ? 200 : 404)
        .set({ ...CORS, "Cache-Control": "public, max-age=60, s-maxage=300" })
        .json(gallery ? photoIndex(code, gallery.photos) : { photos: [] });
      return;
    }

    if (segments.length === 4 && (segments[2] === "img" || segments[2] === "thumb") &&
        CODE_RE.test(code) && ID_RE.test(segments[3])) {
      await serveImage(req, res, bucket, code, segments[3], origin,
        { thumb: segments[2] === "thumb" });
      return;
    }

    let gallery = null;
    if (segments.length === 2 && CODE_RE.test(code)) {
      try {
        gallery = await galleryFor(code, bucket);
      } catch (err) {
        console.error("[photoPage] lookup failed:", code, err.message);
        res.status(503).set({ "Retry-After": "30", "Cache-Control": "no-store" }).send(renderMessage({
          heading: "Photos temporarily unavailable",
          text: "Please try again in a moment.",
          origin,
        }));
        return;
      }
    }

    if (!gallery) {
      res.status(404).set("Cache-Control", "public, max-age=60, s-maxage=300").send(renderMessage({
        heading: "Photo link not found",
        text: `This link is no longer active. Contact ${COMPANY} for an updated link.`,
        origin,
      }));
      return;
    }

    res
      // The CDN keeps a copy for 10 minutes; photos added later show after that.
      .set("Cache-Control", "public, max-age=0, s-maxage=600")
      .status(200)
      .send(renderGallery({ mapName: gallery.map.name, code, origin, photos: gallery.photos }));
  },
);

// Exported for tests.
exports._parsePhotoName = parsePhotoName;
exports._renderGallery = renderGallery;
exports._photoId = photoId;
exports._downloadDisposition = downloadDisposition;
exports._thumbnailFor = thumbnailFor;
exports._photoIndex = photoIndex;
