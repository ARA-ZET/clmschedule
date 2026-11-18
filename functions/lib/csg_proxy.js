/**
 * Chief Surveyor-General (CSG) Property Viewer proxy.
 *
 * The CSG ArcGIS server is self-hosted by DALRRD and sends no
 * `Access-Control-Allow-Origin` header, so a browser refuses every response
 * and the Flutter web build sees only "ClientException: Failed to fetch".
 * (Contrast the ward mapper, which talks to services7.arcgis.com — ArcGIS
 * Online does send CORS headers, which is why that one works from web.)
 *
 * Server-to-server calls are not subject to CORS, so this function fetches on
 * the client's behalf and hands back the ArcGIS JSON untouched.
 *
 * This is NOT a generic pass-through: the host, service and endpoint are all
 * fixed here, only the Erven-style query parameters come from the caller, and
 * only signed-in users get through.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { requireStaff } = require("./require_staff");

// The department was renamed (DRDLR → DALRRD → DLRRD) and the old
// csggis.drdlr.gov.za host no longer resolves at all — it returns NXDOMAIN,
// which is what surfaced as "fetch failed". This is the live host.
const CSG_BASE =
  "https://csggis.dlrrd.gov.za/server/rest/services/Property_Viewer/MapServer";

/** Query parameters a caller may set. Anything else is dropped. */
const ALLOWED_PARAMS = new Set([
  "where",
  "geometry",
  "geometryType",
  "inSR",
  "outSR",
  "spatialRel",
  "outFields",
  "returnGeometry",
  "returnDistinctValues",
  "returnCountOnly",
  "returnIdsOnly",
  "orderByFields",
  "resultOffset",
  "resultRecordCount",
  "maxAllowableOffset",
  "f",
]);

/**
 * Upstream is genuinely slow: a parcel query against the national Erven
 * table measures at roughly 35-45 seconds, with no caching between repeats.
 * The ceiling is set well above that so a normal query is never cut off,
 * while a hung connection still gets abandoned.
 */
const UPSTREAM_TIMEOUT_MS = 180_000;

/**
 * Callable: { layerId: number, params: {string: string} }
 * Returns the decoded ArcGIS response as-is, so the client parses exactly
 * what it would have parsed from a direct call.
 */
exports.csgQuery = onCall(
  { region: "us-central1", timeoutSeconds: 300, memory: "512MiB" },
  async (request) => {
    requireStaff(request.auth, "Sign in to query the cadastral register.");

    const layerId = Number(request.data?.layerId);
    if (!Number.isInteger(layerId) || layerId < 0 || layerId > 30) {
      throw new HttpsError("invalid-argument", `Bad layerId: ${layerId}`);
    }

    const incoming = request.data?.params;
    if (!incoming || typeof incoming !== "object") {
      throw new HttpsError("invalid-argument", "params must be an object.");
    }

    const search = new URLSearchParams();
    for (const [key, value] of Object.entries(incoming)) {
      if (!ALLOWED_PARAMS.has(key)) continue;
      if (value === null || value === undefined) continue;
      search.set(key, String(value));
    }
    search.set("f", "json");

    // POSTed rather than appended to the URL: a suburb boundary passed as a
    // spatial filter runs to hundreds of vertices, which overflows the URL
    // length limit and gets the connection dropped mid-stream.
    const url = `${CSG_BASE}/${layerId}/query`;

    let response;
    try {
      response = await fetch(url, {
        method: "POST",
        signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
        headers: {
          Accept: "application/json",
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: search.toString(),
      });
    } catch (err) {
      // undici reports every transport problem as the bare string "fetch
      // failed" and hides the real reason (DNS, TLS, timeout, refused) in
      // err.cause. Unwrap it, or the log says nothing useful.
      const causes = [];
      for (let e = err; e; e = e.cause) {
        const part = e.code ?? e.message;
        if (part && !causes.includes(part)) causes.push(part);
      }
      const detail = causes.join(" ← ") || String(err);
      console.error(`CSG fetch failed for ${url}: ${detail}`);

      throw new HttpsError(
        "unavailable",
        `Could not reach the CSG server: ${detail}`
      );
    }

    if (!response.ok) {
      throw new HttpsError(
        "unavailable",
        `CSG server returned HTTP ${response.status}.`
      );
    }

    const text = await response.text();
    try {
      return JSON.parse(text);
    } catch (_err) {
      // ArcGIS occasionally answers with an HTML error page.
      throw new HttpsError(
        "internal",
        `CSG returned a non-JSON response (${text.slice(0, 200)})`
      );
    }
  }
);
