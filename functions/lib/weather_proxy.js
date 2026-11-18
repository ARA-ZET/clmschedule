/**
 * Weather forecast proxy — MET Norway Locationforecast 2.0 (the data behind
 * yr.no), for the schedule's day headers and the Weather screen.
 *
 * MET's terms (https://api.met.no/doc/TermsOfService) are why this sits on
 * the server rather than in the app:
 *  - every request must carry an identifying User-Agent, which a browser
 *    cannot set;
 *  - a response must not be re-requested before its `Expires`, and refreshes
 *    should send `If-Modified-Since` so an unchanged forecast costs a 304;
 *  - coordinates may carry at most 4 decimals.
 * One cache doc per ~1 km grid cell in `weatherCache/{lat}_{lon}` lets every
 * client share a single fetch per forecast update (roughly hourly).
 *
 * The raw response is ~60 KB of per-timestep data; it is summarised here into
 * SAST calendar days plus per-step rows so the client receives a few KB.
 * Outside the Nordics MET has no gust or precipitation-probability fields —
 * wind is the mean speed and rain is the forecast amount.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { requireStaff } = require("./require_staff");
const admin = require("firebase-admin");

const MET_URL = "https://api.met.no/weatherapi/locationforecast/2.0/complete";
const USER_AGENT = "clmschedule/1.0 https://clmschedule.web.app";
const UPSTREAM_TIMEOUT_MS = 15_000;

/** Bump when `summarise` output changes — older cache docs are refetched in
 * full (no If-Modified-Since, which would just hand back a 304). */
const SCHEMA = 2;

/** Schedule dates are SAST civil dates — see lib/utils/schedule_time.dart. */
const SAST_OFFSET_MS = 2 * 60 * 60 * 1000;
const HOUR_MS = 60 * 60 * 1000;

/** Distribution happens in daylight; the day's rating looks at these SAST
 * hours, [start, end). */
const WORK_START_HOUR = 6;
const WORK_END_HOUR = 18;

function db() {
  return admin.firestore();
}

/** Two decimals ≈ 1 km — well within MET's 4-decimal limit, and it lets
 * nearby callers (depot, adjacent suburbs) share one cache doc. */
function round2(n) {
  return Math.round(n * 100) / 100;
}

function sastParts(ms) {
  const d = new Date(ms + SAST_OFFSET_MS);
  const day = d.toISOString().slice(0, 10);
  return { day, hour: d.getUTCHours() };
}

/**
 * How bad a MET symbol is for working outside, so a day can show its worst
 * daytime symbol. Codes look like "lightrainshowers_day", "heavyrain",
 * "rainandthunder", "partlycloudy_night".
 */
function symbolSeverity(code) {
  if (!code) return -1;
  const base = code.replace(/_(day|night|polartwilight)$/, "");
  if (base.includes("thunder")) return 9;
  const wet = /rain|sleet|snow/.test(base);
  if (wet && base.startsWith("heavy")) return 8;
  if (wet && base.startsWith("light")) return base.includes("showers") ? 5 : 6;
  if (wet) return base.includes("showers") ? 6.5 : 7;
  if (base === "fog") return 4;
  if (base === "cloudy") return 3;
  if (base === "partlycloudy") return 2;
  if (base === "fair") return 1;
  return 0; // clearsky
}

function maxOrNull(a, b) {
  if (a == null) return b;
  if (b == null) return a;
  return Math.max(a, b);
}

function minOrNull(a, b) {
  if (a == null) return b;
  if (b == null) return a;
  return Math.min(a, b);
}

function round1(n) {
  return n == null ? null : Math.round(n * 10) / 10;
}

/**
 * Turns MET's timeseries into `{days, steps}`.
 *
 * steps: one row per forecast period — hourly for the first ~2.5 days, then
 *   6-hourly — `{time, hours, temp, feelsLike, symbol, precipMm, windMs,
 *   windDir, humidity, cloud, uv}`.
 *   Periods never overlap: once an hour is covered by a 1-hour block, the
 *   6-hour block that starts there is skipped.
 * days: per SAST date — whole-day temp range and rain, plus the daylight
 *   (06–18) rain, peak mean wind and worst symbol that the rating uses, and
 *   `periods` — MET's own 6-hour symbol for night / morning / afternoon /
 *   evening, as yr.no shows them (null where the forecast has no block).
 */
function summarise(met) {
  const series = met?.properties?.timeseries ?? [];
  const steps = [];
  const days = new Map();
  const dayFor = (key) => {
    if (!days.has(key)) {
      days.set(key, {
        date: key,
        minTemp: null,
        maxTemp: null,
        precipMm: 0,
        workPrecipMm: 0,
        workMaxWindMs: null,
        maxWindMs: null,
        symbol: null,
        periods: [null, null, null, null],
        hasWorkHours: false,
      });
    }
    return days.get(key);
  };

  let coveredUntil = -Infinity;
  for (const entry of series) {
    const t = Date.parse(entry.time);
    if (Number.isNaN(t)) continue;
    const instant = entry.data?.instant?.details ?? {};
    const { day, hour } = sastParts(t);
    const d = dayFor(day);
    const inWork = hour >= WORK_START_HOUR && hour < WORK_END_HOUR;

    d.minTemp = minOrNull(d.minTemp, instant.air_temperature);
    d.maxTemp = maxOrNull(d.maxTemp, instant.air_temperature);
    d.maxWindMs = maxOrNull(d.maxWindMs, instant.wind_speed);
    if (inWork) {
      d.workMaxWindMs = maxOrNull(d.workMaxWindMs, instant.wind_speed);
      d.hasWorkHours = true;
    }

    const one = entry.data?.next_1_hours;
    const six = entry.data?.next_6_hours;
    // yr's day row: the 6-hour block starting on a 00/06/12/18 SAST boundary
    // while the series is hourly, or each block once it turns 6-hourly
    // (those start at 02/08/14/20 SAST).
    if (six && (hour % 6 === 0 || !one)) {
      const q = Math.floor(hour / 6);
      if (!d.periods[q]) {
        d.periods[q] = {
          symbol: six.summary?.symbol_code ?? null,
          precipMm: round1(six.details?.precipitation_amount ?? 0),
          minTemp: round1(six.details?.air_temperature_min),
          maxTemp: round1(six.details?.air_temperature_max),
        };
      }
    }

    if (t < coveredUntil) continue;
    const block = one ? { hours: 1, ...one } : six ? { hours: 6, ...six } : null;
    if (!block) continue;
    coveredUntil = t + block.hours * HOUR_MS;

    const precip = block.details?.precipitation_amount ?? 0;
    const symbol = block.summary?.symbol_code ?? null;
    d.precipMm += precip;
    if (block.hours === 6) {
      d.minTemp = minOrNull(d.minTemp, block.details?.air_temperature_min);
      d.maxTemp = maxOrNull(d.maxTemp, block.details?.air_temperature_max);
    }
    // A block counts toward working hours when at least half of it falls
    // inside them — 6-hour blocks start at 02/08/14/20 SAST, so the mostly
    // night-time 02–08 block stays out of the day's rating.
    const overlap =
      Math.min(hour + block.hours, WORK_END_HOUR) - Math.max(hour, WORK_START_HOUR);
    if (overlap * 2 >= block.hours) {
      d.workPrecipMm += precip;
      d.hasWorkHours = true;
      if (symbolSeverity(symbol) > symbolSeverity(d.symbol)) d.symbol = symbol;
    }

    steps.push({
      time: entry.time,
      hours: block.hours,
      temp: round1(instant.air_temperature),
      feelsLike: round1(instant.apparent_air_temperature),
      symbol,
      precipMm: round1(precip),
      windMs: round1(instant.wind_speed),
      windDir: instant.wind_from_direction != null ? Math.round(instant.wind_from_direction) : null,
      humidity: instant.relative_humidity != null ? Math.round(instant.relative_humidity) : null,
      cloud: instant.cloud_area_fraction != null ? Math.round(instant.cloud_area_fraction) : null,
      uv: round1(instant.ultraviolet_index_clear_sky),
    });
  }

  const dayList = [...days.values()]
    .filter((d) => d.hasWorkHours && d.symbol)
    .map(({ hasWorkHours, ...d }) => ({
      ...d,
      minTemp: round1(d.minTemp),
      maxTemp: round1(d.maxTemp),
      precipMm: round1(d.precipMm),
      workPrecipMm: round1(d.workPrecipMm),
      workMaxWindMs: round1(d.workMaxWindMs),
      maxWindMs: round1(d.maxWindMs),
    }));

  return {
    updatedAt: met?.properties?.meta?.updated_at ?? null,
    days: dayList,
    steps,
  };
}

function expiresMs(response, now) {
  const parsed = Date.parse(response.headers.get("expires") ?? "");
  // Never hold a forecast more than 2 h, never re-ask sooner than 10 min.
  if (Number.isNaN(parsed)) return now + 30 * 60 * 1000;
  return Math.min(Math.max(parsed, now + 10 * 60 * 1000), now + 2 * HOUR_MS);
}

function toResult(doc, source) {
  return {
    lat: doc.lat,
    lon: doc.lon,
    updatedAt: doc.updatedAt,
    fetchedAt: doc.fetchedAt,
    days: doc.days,
    steps: doc.steps,
    source,
  };
}

/**
 * Callable: { lat: number, lon: number }
 * Returns { lat, lon, updatedAt, fetchedAt, days, steps, source }.
 */
exports.weatherForecast = onCall(
  { region: "us-central1", timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    requireStaff(request.auth, "Sign in to see the weather.");
    const lat = Number(request.data?.lat);
    const lon = Number(request.data?.lon);
    if (!Number.isFinite(lat) || lat < -90 || lat > 90 ||
        !Number.isFinite(lon) || lon < -180 || lon > 180) {
      throw new HttpsError("invalid-argument", `Bad coordinates: ${lat}, ${lon}`);
    }
    const rlat = round2(lat);
    const rlon = round2(lon);
    const ref = db().collection("weatherCache").doc(`${rlat.toFixed(2)}_${rlon.toFixed(2)}`);
    const snap = await ref.get();
    const cached = snap.exists && snap.data().schema === SCHEMA ? snap.data() : null;
    const now = Date.now();
    if (cached && now < (cached.expiresAt ?? 0)) {
      return toResult(cached, "cache");
    }

    const headers = { "User-Agent": USER_AGENT, Accept: "application/json" };
    if (cached?.lastModified) headers["If-Modified-Since"] = cached.lastModified;

    let response;
    try {
      response = await fetch(`${MET_URL}?lat=${rlat}&lon=${rlon}`, {
        headers,
        signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
      });
    } catch (err) {
      // undici hides the real reason in err.cause — unwrap it
      const causes = [];
      for (let e = err; e; e = e.cause) {
        const part = e.code ?? e.message;
        if (part && !causes.includes(part)) causes.push(part);
      }
      const detail = causes.join(" ← ") || String(err);
      console.error(`MET fetch failed for ${rlat},${rlon}: ${detail}`);
      if (cached) return toResult(cached, "stale");
      throw new HttpsError("unavailable", `Could not reach the weather service: ${detail}`);
    }

    if (response.status === 304 && cached) {
      const expiresAt = expiresMs(response, now);
      await ref.set({ expiresAt, checkedAt: now }, { merge: true });
      return toResult(cached, "cache");
    }
    if (response.status === 203) {
      console.warn("MET Locationforecast 2.0 reports it is deprecated (HTTP 203).");
    }
    if (!response.ok) {
      console.error(`MET returned HTTP ${response.status} for ${rlat},${rlon}`);
      if (cached) return toResult(cached, "stale");
      throw new HttpsError("unavailable", `The weather service returned HTTP ${response.status}.`);
    }

    let met;
    try {
      met = await response.json();
    } catch (_err) {
      if (cached) return toResult(cached, "stale");
      throw new HttpsError("internal", "The weather service returned an unreadable response.");
    }
    const summary = summarise(met);
    const doc = {
      schema: SCHEMA,
      lat: rlat,
      lon: rlon,
      ...summary,
      fetchedAt: now,
      checkedAt: now,
      expiresAt: expiresMs(response, now),
      lastModified: response.headers.get("last-modified") ?? null,
    };
    await ref.set(doc);
    return toResult(doc, "network");
  }
);

exports.summarise = summarise; // for local smoke tests
