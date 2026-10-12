/**
 * Server-rendered shell for CLM Maps share links (/map/{shareCode}).
 *
 * Why this exists: clients were finding our emails in spam whenever they
 * carried a map link. Mail scanners (Outlook Safe Links, Mimecast, Gmail)
 * fetch the linked page without running JavaScript. The Flutter build is a
 * blank JS-only shell with the same generic title for every URL, and it
 * returns 200 even for dead codes — on a shared *.web.app host that pattern
 * scores as phishing.
 *
 * Hosting rewrites /map/** here (see firebase.json, `maps` target). We take
 * the deployed index.html, inject the map's real title/description/OG tags
 * and visible splash text, and return it. Flutter boots from the same HTML,
 * so viewers see no difference. Unknown or deleted codes get a real 404.
 *
 * Reads are public already (mapLinks + shareableMaps rules allow read: true),
 * so nothing new is exposed. The CDN caches each page (s-maxage) so Firestore
 * is hit roughly once per map per cache window.
 */

const { onRequest } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

// Always fetch the template from the canonical Hosting site, never from the
// request's Host header — that would let a direct caller point us anywhere.
const TEMPLATE_URL = "https://clm-maps.web.app/index.html";
const TEMPLATE_TTL_MS = 60 * 1000;

const COMPANY = "Community Life Media";
const CODE_RE = /^[A-Za-z0-9_-]{4,64}$/;

let _template = null;
let _templateAt = 0;

async function getTemplate() {
  if (_template && Date.now() - _templateAt < TEMPLATE_TTL_MS) return _template;
  try {
    const res = await fetch(TEMPLATE_URL, { headers: { "cache-control": "no-cache" } });
    if (!res.ok) throw new Error(`template HTTP ${res.status}`);
    _template = await res.text();
    _templateAt = Date.now();
  } catch (err) {
    // Serve the last good template rather than failing the page.
    console.error("[mapPage] template fetch failed:", err.message);
    if (!_template) throw err;
  }
  return _template;
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function truncate(value, max) {
  const s = String(value || "").replace(/\s+/g, " ").trim();
  return s.length > max ? `${s.slice(0, max - 1).trimEnd()}…` : s;
}

/** Replace a <meta name|property="key" content="..."> value. */
function setMeta(html, attr, key, content) {
  const re = new RegExp(`(<meta\\s+${attr}="${key}"\\s+content=")[^"]*(")`, "i");
  return html.replace(re, (_, open, close) => `${open}${content}${close}`);
}

function setElementText(html, id, text) {
  const re = new RegExp(`(<([a-z0-9]+)[^>]*\\sid="${id}"[^>]*>)[\\s\\S]*?(</\\2>)`, "i");
  return html.replace(re, (_, open, _tag, close) => `${open}${text}${close}`);
}

/**
 * Inject page identity. All values must already be HTML-escaped.
 */
function render(template, { title, description, heading, subheading, origin, canonicalPath, robots }) {
  let html = template;
  html = html.replace(/<title>[\s\S]*?<\/title>/i, () => `<title>${title}</title>`);
  html = setMeta(html, "name", "description", description);
  html = setMeta(html, "property", "og:title", title);
  html = setMeta(html, "property", "og:description", description);
  html = setMeta(html, "name", "twitter:title", title);
  html = setMeta(html, "name", "twitter:description", description);
  html = setMeta(html, "property", "og:image", `${origin}/assets/clm-official-logo.jpeg`);
  html = setMeta(html, "name", "twitter:image", `${origin}/assets/clm-official-logo.jpeg`);
  html = setElementText(html, "splash-title", heading);
  html = setElementText(html, "splash-subtitle", subheading);

  const extraHead =
    `<link rel="canonical" href="${origin}${canonicalPath}">\n` +
    `  <meta property="og:url" content="${origin}${canonicalPath}">\n` +
    `  <meta property="og:site_name" content="${COMPANY}">\n` +
    `  <meta name="robots" content="${robots}">\n`;
  return html.replace(/<\/head>/i, () => `  ${extraHead}</head>`);
}

/** Origin to print in canonical/OG URLs — only hosts we actually serve. */
function originFor(req) {
  const allowed = new Set([
    "clm-maps.web.app",
    "clm-maps.firebaseapp.com",
    "maps.communitylifemedia.co.za",
  ]);
  const host = String(req.get("x-forwarded-host") || req.hostname || "").toLowerCase();
  return `https://${allowed.has(host) ? host : "clm-maps.web.app"}`;
}

async function lookupMap(code) {
  const db = admin.firestore();
  const link = await db.collection("mapLinks").doc(code).get();
  if (!link.exists) return null;

  const { monthKey, mapId, mapName } = link.data() || {};
  if (!monthKey || !mapId) return null;

  // Field mask: map docs can be large (embedded layers); we only need text.
  const mapRef = db.collection("shareableMaps").doc(monthKey).collection("maps").doc(mapId);
  const [map] = await db.getAll(mapRef, { fieldMask: ["name", "description"] });
  if (!map.exists) return null;

  const data = map.data() || {};
  return {
    name: truncate(data.name || mapName || "Distribution map", 80),
    description: truncate(data.description, 160),
  };
}

exports.mapPage = onRequest(
  { region: "us-central1", memory: "256MiB", maxInstances: 10 },
  async (req, res) => {
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.status(405).set("Allow", "GET, HEAD").send("Method Not Allowed");
      return;
    }

    const segments = req.path.split("/").filter(Boolean);
    const code = segments[0] === "map" && segments.length === 2 ? segments[1] : "";
    const origin = originFor(req);

    let template;
    try {
      template = await getTemplate();
    } catch (_) {
      res.status(503).set({ "Retry-After": "30", "Cache-Control": "no-store" })
        .send("CLM Maps is temporarily unavailable. Please try again shortly.");
      return;
    }

    let map = null;
    if (CODE_RE.test(code)) {
      try {
        map = await lookupMap(code);
      } catch (err) {
        console.error("[mapPage] lookup failed:", code, err.message);
        // Don't cache a transient failure as a 404; let Flutter resolve it.
        res.status(200).set("Cache-Control", "no-store").send(render(template, {
          title: escapeHtml(`Distribution map – ${COMPANY}`),
          description: escapeHtml(`Interactive flyer distribution map prepared by ${COMPANY}, Cape Town.`),
          heading: "Distribution map",
          subheading: escapeHtml(`Prepared by ${COMPANY}`),
          origin,
          canonicalPath: `/map/${code}`,
          robots: "noindex, nofollow",
        }));
        return;
      }
    }

    if (!map) {
      // Flutter still boots and shows its own invalid-link message.
      res.status(404).set("Cache-Control", "public, max-age=60, s-maxage=300").send(render(template, {
        title: escapeHtml(`Map link not found – ${COMPANY}`),
        description: escapeHtml(`This map link is no longer active. Contact ${COMPANY} for an updated link.`),
        heading: "Map link not found",
        subheading: escapeHtml(`This link is no longer active. Contact ${COMPANY} for an updated link.`),
        origin,
        canonicalPath: "/",
        robots: "noindex, nofollow",
      }));
      return;
    }

    const name = escapeHtml(map.name);
    const description = escapeHtml(
      map.description ||
        `Flyer distribution area "${map.name}" – interactive GPS-tracked map prepared by ${COMPANY}, Cape Town.`,
    );

    res
      // Browsers revalidate (matches the no-cache policy on index.html);
      // the Hosting CDN keeps a copy for 10 minutes.
      .set("Cache-Control", "public, max-age=0, s-maxage=600")
      .status(200)
      .send(render(template, {
        title: `${name} – ${escapeHtml(COMPANY)}`,
        description,
        heading: name,
        subheading: escapeHtml(`Distribution map prepared by ${COMPANY}`),
        origin,
        canonicalPath: `/map/${code}`,
        // Client maps are private-by-link: readable, but not for search results.
        robots: "noindex, nofollow",
      }));
  },
);

// Exported for tests.
exports._render = render;
exports._escapeHtml = escapeHtml;
