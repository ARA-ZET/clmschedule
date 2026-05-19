/**
 * Server-side Distance Matrix cache.
 *
 * Wraps Google Directions API behind a Firestore-backed cache so every
 * client across the org shares one quota and most lookups never reach
 * Google. Cache documents live at `routeCache/{key}` and store the
 * distance/duration/polyline plus a TTL.
 *
 * Cache key: `${fromLat},${fromLng}|${toLat},${toLng}|${hourBucket}`
 *  - lat/lng rounded to 5 decimals (~1m precision) for stable keys
 *  - hourBucket is "HH:MM" floored to the next 15-minute mark, or "none"
 *
 * Exposed as a callable function `getRouteSegment` so the Flutter client
 * can pass coordinates + an optional `departureTime` and receive the
 * cached or freshly fetched segment in one round-trip.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");

const GOOGLE_MAPS_API_KEY = defineSecret("GOOGLE_MAPS_API_KEY");

const CACHE_TTL_DAYS = 14;
const CACHE_TTL_MS = CACHE_TTL_DAYS * 24 * 60 * 60 * 1000;

function db() {
  return admin.firestore();
}

function round5(n) {
  return Math.round(n * 1e5) / 1e5;
}

function bucketFor(departureTime) {
  if (!departureTime) return "none";
  const d = new Date(departureTime);
  if (Number.isNaN(d.getTime())) return "none";
  const minute = Math.floor(d.getMinutes() / 15) * 15;
  return `${String(d.getHours()).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

function cacheKeyFor({ fromLat, fromLng, toLat, toLng, departureTime }) {
  const f = `${round5(fromLat)},${round5(fromLng)}`;
  const t = `${round5(toLat)},${round5(toLng)}`;
  return `${f}|${t}|${bucketFor(departureTime)}`;
}

/**
 * Advance a past timestamp forward by 24h until it lies in the future,
 * preserving the time-of-day so the Directions API still returns a
 * realistic `duration_in_traffic` for the scheduled hour.
 */
function effectiveDeparture(departureTime) {
  if (!departureTime) return null;
  let d = new Date(departureTime);
  const now = new Date();
  while (d.getTime() < now.getTime()) {
    d = new Date(d.getTime() + 24 * 60 * 60 * 1000);
  }
  return d;
}

async function fetchFromGoogle({ fromLat, fromLng, toLat, toLng, departureTime, apiKey }) {
  const origin = `${fromLat},${fromLng}`;
  const destination = `${toLat},${toLng}`;
  const params = new URLSearchParams({
    origin,
    destination,
    key: apiKey,
  });
  const eff = effectiveDeparture(departureTime);
  if (eff) {
    params.set("departure_time", String(Math.floor(eff.getTime() / 1000)));
    params.set("traffic_model", "best_guess");
  }
  const url = `https://maps.googleapis.com/maps/api/directions/json?${params.toString()}`;
  const res = await fetch(url);
  if (!res.ok) {
    throw new HttpsError("internal", `Directions API HTTP ${res.status}`);
  }
  const data = await res.json();
  if (data.status !== "OK" || !data.routes || !data.routes.length) {
    throw new HttpsError("not-found", `Directions API: ${data.status}`);
  }
  const route = data.routes[0];
  const leg = route.legs[0];
  return {
    distanceMeters: leg.distance.value,
    durationSeconds: leg.duration.value,
    durationInTrafficSeconds: leg.duration_in_traffic
      ? leg.duration_in_traffic.value
      : leg.duration.value,
    encodedPolyline: route.overview_polyline.points,
  };
}

/**
 * Returns a cached or freshly fetched route segment.
 *
 * Returns `null` polyline points to keep the payload small — the client
 * decodes the encoded polyline on demand (and our isolate decoder
 * already handles long encodings off the main thread).
 */
async function lookupRouteSegment({ fromLat, fromLng, toLat, toLng, departureTime }, apiKey) {
  if ([fromLat, fromLng, toLat, toLng].some((v) => typeof v !== "number")) {
    throw new HttpsError("invalid-argument", "lat/lng must be numbers");
  }
  const key = cacheKeyFor({ fromLat, fromLng, toLat, toLng, departureTime });
  const ref = db().collection("routeCache").doc(key);
  const snap = await ref.get();
  const now = Date.now();
  if (snap.exists) {
    const data = snap.data();
    const age = now - (data.cachedAt || 0);
    if (age < CACHE_TTL_MS && data.distanceMeters != null) {
      return { ...data, source: "cache" };
    }
  }
  const fresh = await fetchFromGoogle({
    fromLat,
    fromLng,
    toLat,
    toLng,
    departureTime,
    apiKey,
  });
  await ref.set({ ...fresh, cachedAt: now }, { merge: true });
  return { ...fresh, source: "google" };
}

const getRouteSegment = onCall(
  { secrets: [GOOGLE_MAPS_API_KEY], timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }
    const apiKey = GOOGLE_MAPS_API_KEY.value();
    if (!apiKey) {
      throw new HttpsError("failed-precondition", "GOOGLE_MAPS_API_KEY secret not set");
    }
    const result = await lookupRouteSegment(request.data || {}, apiKey);
    return result;
  }
);

module.exports = {
  getRouteSegment,
  lookupRouteSegment, // re-used by route optimizer
  GOOGLE_MAPS_API_KEY,
};
