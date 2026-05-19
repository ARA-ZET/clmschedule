/**
 * Server-side dropsheet route optimizer.
 *
 * Mirrors `lib/services/dropsheet_route_planner.dart::optimizeSection`
 * but runs entirely server-side. The client posts the section's stops +
 * depot + start time; we run greedy nearest-neighbour using the shared
 * Distance Matrix cache and return the optimised order, ETAs, leg data
 * and a single combined polyline (decoded server-side once).
 *
 * Doing this here means:
 *  - Client devices never hit the Google Directions endpoint.
 *  - All clients share the org-wide `routeCache` so repeat planning
 *    runs are mostly free.
 *  - No main-thread jank on the device while ETAs compute.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { lookupRouteSegment, GOOGLE_MAPS_API_KEY } = require("./distance_matrix_cache");

function fmtHHmm(d) {
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

function parseStartTime(s) {
  if (!s) return { hour: 7, minute: 0 };
  const [h, m] = String(s).split(":").map((n) => parseInt(n, 10));
  return {
    hour: Number.isFinite(h) ? h : 7,
    minute: Number.isFinite(m) ? m : 0,
  };
}

/**
 * Decode a Google encoded polyline into [{lat, lng}, ...]. Pure JS
 * version of the Dart isolate decoder.
 */
function decodePolyline(encoded) {
  if (!encoded) return [];
  const points = [];
  let index = 0;
  const len = encoded.length;
  let lat = 0;
  let lng = 0;
  while (index < len) {
    let shift = 0;
    let result = 0;
    let byte;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    const dlat = (result & 1) !== 0 ? ~(result >> 1) : (result >> 1);
    lat += dlat;
    shift = 0;
    result = 0;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    const dlng = (result & 1) !== 0 ? ~(result >> 1) : (result >> 1);
    lng += dlng;
    points.push({ lat: lat / 1e5, lng: lng / 1e5 });
  }
  return points;
}

/**
 * @param {Object} input
 * @param {Array} input.stops          [{ taskId, role, lat, lng, serviceMinutes, stopKey }]
 * @param {Object} input.depot         { lat, lng, startTime }
 * @param {string} input.baseDate      'YYYY-MM-DD'
 * @param {string} [input.startTime]   'HH:MM' override
 */
async function runOptimisation(input, apiKey) {
  const { stops, depot, baseDate, startTime } = input;
  if (!Array.isArray(stops) || stops.length === 0) {
    return null;
  }
  if (!depot || typeof depot.lat !== "number" || typeof depot.lng !== "number") {
    throw new HttpsError("invalid-argument", "depot.lat / depot.lng required");
  }

  const startStr = startTime || depot.startTime || "07:00";
  const start = parseStartTime(startStr);
  const [yy, mm, dd] = String(baseDate).split("-").map((n) => parseInt(n, 10));
  let clock = new Date(yy, (mm || 1) - 1, dd || 1, start.hour, start.minute);

  const remaining = stops.slice();
  const ordered = [];
  const legs = [];
  const arrivalTimes = {};
  const skipped = [];
  let currentLat = depot.lat;
  let currentLng = depot.lng;

  while (remaining.length > 0) {
    // Eligible = single/loading immediately; offload only after its loading.
    const eligible = remaining.filter((s) => {
      if (s.role !== "offload") return true;
      return ordered.some((o) => o.taskId === s.taskId && o.role === "loading");
    });
    if (eligible.length === 0) break;

    // Parallel cache/directions lookup for every candidate.
    const segments = await Promise.all(
      eligible.map((cand) =>
        lookupRouteSegment(
          {
            fromLat: currentLat,
            fromLng: currentLng,
            toLat: cand.lat,
            toLng: cand.lng,
            departureTime: clock.toISOString(),
          },
          apiKey
        ).catch((err) => {
          console.warn(`[routeOptimizer] segment failed for ${cand.stopKey}: ${err.message}`);
          return null;
        })
      )
    );

    let best = null;
    let bestSeg = null;
    let bestDuration = Number.POSITIVE_INFINITY;
    for (let i = 0; i < eligible.length; i++) {
      const seg = segments[i];
      if (!seg) continue;
      const d = seg.durationInTrafficSeconds || seg.durationSeconds;
      if (d < bestDuration) {
        bestDuration = d;
        best = eligible[i];
        bestSeg = seg;
      }
    }
    if (!best) {
      // No reachable stop — bail out and mark the rest skipped.
      break;
    }

    legs.push({
      fromStopKey: ordered.length === 0 ? null : ordered[ordered.length - 1].stopKey,
      toStopKey: best.stopKey,
      distanceMeters: bestSeg.distanceMeters,
      durationSeconds: bestDuration,
      polyline: decodePolyline(bestSeg.encodedPolyline),
    });
    clock = new Date(clock.getTime() + bestDuration * 1000);
    arrivalTimes[best.stopKey] = fmtHHmm(clock);
    clock = new Date(clock.getTime() + (best.serviceMinutes || 0) * 60 * 1000);
    ordered.push(best);
    const idx = remaining.findIndex((s) => s.stopKey === best.stopKey);
    if (idx >= 0) remaining.splice(idx, 1);
    currentLat = best.lat;
    currentLng = best.lng;
  }

  for (const r of remaining) skipped.push(r.taskId);

  // Deduplicate task order (furniture-move contributes 2 stops).
  const taskOrder = [];
  for (const s of ordered) {
    if (taskOrder.length === 0 || taskOrder[taskOrder.length - 1] !== s.taskId) {
      taskOrder.push(s.taskId);
    }
  }

  const fullPolyline = [];
  for (const leg of legs) {
    if (!leg.polyline.length) continue;
    if (fullPolyline.length === 0) fullPolyline.push(...leg.polyline);
    else fullPolyline.push(...leg.polyline.slice(1));
  }

  const legBeforeStop = {};
  for (let i = 0; i < ordered.length; i++) {
    legBeforeStop[ordered[i].stopKey] = legs[i];
  }

  const totalDistanceMeters = legs.reduce((s, l) => s + l.distanceMeters, 0);
  const totalDurationSeconds = legs.reduce((s, l) => s + l.durationSeconds, 0);

  return {
    taskOrder,
    arrivalTimes,
    legBeforeStop,
    fullPolyline,
    totalDistanceMeters,
    totalDurationSeconds,
    skippedTaskIds: Array.from(new Set(skipped)),
    computedAt: Date.now(),
  };
}

const optimizeDropsheetRoute = onCall(
  { secrets: [GOOGLE_MAPS_API_KEY], timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }
    const apiKey = GOOGLE_MAPS_API_KEY.value();
    if (!apiKey) {
      throw new HttpsError("failed-precondition", "GOOGLE_MAPS_API_KEY secret not set");
    }
    return await runOptimisation(request.data || {}, apiKey);
  }
);

module.exports = { optimizeDropsheetRoute };
