/**
 * Xero Accounting API 2.0 proxy — Community Life Media invoicing.
 *
 * Same philosophy as functions/lib/zoho_books.js: this app ships a web build,
 * where anything compiled into the bundle is readable from devtools, so the
 * OAuth credentials live here and every Xero call is proxied. `op` is matched
 * against a fixed allowlist, each entry pinning its own method and path — a
 * signed-in user cannot reach arbitrary Xero endpoints.
 *
 * Where it differs from the Zoho proxy, and why:
 *
 *  1. **Rotating refresh tokens.** Zoho's refresh token is immortal, so it sits
 *     in Secret Manager. Xero's rotates on *every* refresh — using it kills it
 *     and returns a replacement — so it cannot be a Firebase secret. It lives in
 *     Firestore at `secureTokens/xero` instead, guarded by a lock so two
 *     instances cannot burn the same token concurrently. See §Token store.
 *
 *  2. **Tenant header, not an org query param.** Every call carries
 *     `Xero-Tenant-Id`.
 *
 *  3. **HTTP status means what it says.** Zoho signals failure with `"code": 0`
 *     on an HTTP 200; Xero uses real status codes, and packs validation detail
 *     into `Elements[].ValidationErrors[]` under a useless top-level
 *     "A validation exception occurred".
 *
 * Set the two secrets once:
 *   firebase functions:secrets:set XERO_CLIENT_ID
 *   firebase functions:secrets:set XERO_CLIENT_SECRET
 *
 * The initial refresh token comes from the one-off consent script (~/xero_connect.js,
 * kept outside the repo), which writes `secureTokens/xero`.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const crypto = require("crypto");

const XERO_CLIENT_ID = defineSecret("XERO_CLIENT_ID");
const XERO_CLIENT_SECRET = defineSecret("XERO_CLIENT_SECRET");

// ── Endpoints ────────────────────────────────────────────────────────────────
const TOKEN_URL = "https://identity.xero.com/connect/token";
const API_BASE = "https://api.xero.com/api.xro/2.0";

/**
 * Where the rotating token lives.
 *
 * `secureTokens` is deliberately ABSENT from firestore.rules, which ends
 * fail-closed — so no client can read it, while Cloud Functions bypass rules
 * via the Admin SDK. Do NOT "tidy up" by adding this collection to the rules,
 * and in particular do not move this document under `settings/`, which grants
 * read/write to every signed-in user.
 *
 * A deny rule would not help: Firestore evaluates all matching rules and grants
 * access if any `allow` matches, regardless of order.
 */
const TOKEN_DOC_PATH = "secureTokens/xero";

// Access tokens last 30 minutes. Refresh 5 minutes early so a call in flight
// never races the expiry.
const ACCESS_TOKEN_SKEW_MS = 5 * 60 * 1000;

// A refresh holds the lock for at most this long; a crashed instance therefore
// cannot wedge the integration for more than 30s.
const TENANT_CACHE_TTL_MS = 5 * 60 * 1000;

const LOCK_TTL_MS = 30 * 1000;
const LOCK_POLL_MS = 400;
const LOCK_MAX_POLLS = 25; // ~10s of waiting before we give up

function db() {
  return admin.firestore();
}

function tokenRef() {
  return db().doc(TOKEN_DOC_PATH);
}

// ── Token store ──────────────────────────────────────────────────────────────
// Module-scope cache so a warm instance reuses one access token across calls.
// The Firestore copy is what lets a *cold* instance skip the refresh entirely —
// worth having, because refreshing burns the rotating token every time.
let _accessToken = null;
let _accessTokenExpiresAt = 0;

// The tenant is cached with a TTL, NOT for the life of the instance.
//
// It used to be cached forever, which meant that changing
// `secureTokens/xero.tenantId` — switching from a testing organisation to the
// real one, say — left every warm instance still sending the old tenant. An
// invoice raised in that window is written to the wrong organisation and looks
// entirely successful. Bounding the staleness costs one document read per
// instance per TTL, which is nothing next to that.
let _tenantId = null;
let _tenantIdReadAt = 0;

const INSTANCE_ID = crypto.randomUUID();

function tokenIsFresh(expiresAt) {
  return Boolean(expiresAt) && Date.now() < expiresAt - ACCESS_TOKEN_SKEW_MS;
}

/**
 * Whether a stored token can be handed out.
 *
 * [rejectToken] is the token a caller was just given a 401 for. Xero can revoke
 * an access token before its nominal expiry, so "not expired" is not the same
 * as "works" — without this check the 401 retry would be handed the same dead
 * token straight back and fail identically.
 */
function isUsable(stored, rejectToken) {
  return tokenIsFresh(stored.expiresAt)
    && Boolean(stored.accessToken)
    && stored.accessToken !== rejectToken;
}

function notConnected(detail) {
  return new HttpsError(
    "failed-precondition",
    `Xero is not connected: ${detail} Run the consent script (~/xero_connect.js) ` +
    "to authorise the Community Life Media organisation.",
  );
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Exchange one refresh token for a new access/refresh pair.
 *
 * Returns the parsed token response. Throws with `isInvalidGrant` set when Xero
 * rejects the token itself, which is the signal to fall back to the previous
 * one inside its grace window.
 */
async function requestTokenRefresh(refreshToken) {
  const basic = Buffer.from(
    `${XERO_CLIENT_ID.value()}:${XERO_CLIENT_SECRET.value()}`,
  ).toString("base64");

  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      Authorization: `Basic ${basic}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
    }),
  });

  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    /* fall through to the status-based error below */
  }

  if (!res.ok || !json || !json.access_token) {
    const error = json && json.error ? json.error : `HTTP ${res.status}`;
    const err = new Error(`Xero token refresh failed: ${error}`);
    err.isInvalidGrant = error === "invalid_grant";
    throw err;
  }

  return json;
}

/**
 * Refresh and persist, assuming the caller holds the lock.
 *
 * The new refresh token is written to Firestore **before** the access token is
 * returned. If that write fails we throw rather than proceed: the consumed
 * token is already dead at Xero, and returning an access token we failed to
 * record would silently strand the integration at the next cold start.
 */
async function refreshAndPersist(stored) {
  const primary = stored.refreshToken;
  if (!primary) throw notConnected("no refresh token is stored.");

  let json;
  let usedToken = primary;
  try {
    json = await requestTokenRefresh(primary);
  } catch (e) {
    // Xero keeps a consumed refresh token alive for a 30-minute grace window,
    // precisely so a lost response can be retried. If our stored token was
    // rejected, the previous one may still work — which is what recovers the
    // case where a refresh succeeded at Xero but our write did not land.
    if (e.isInvalidGrant && stored.previousRefreshToken) {
      console.warn(
        "[xero] stored refresh token rejected; retrying the previous one " +
        "inside its 30-minute grace window",
      );
      usedToken = stored.previousRefreshToken;
      try {
        json = await requestTokenRefresh(usedToken);
      } catch (inner) {
        throw notConnected(
          `both the current and previous refresh tokens were rejected (${inner.message}).`,
        );
      }
    } else if (e.isInvalidGrant) {
      throw notConnected(`the stored refresh token was rejected (${e.message}).`);
    } else {
      throw new HttpsError("unavailable", e.message);
    }
  }

  const expiresAt = Date.now() + (Number(json.expires_in) || 1800) * 1000;

  try {
    await tokenRef().set(
      {
        refreshToken: json.refresh_token,
        previousRefreshToken: usedToken,
        accessToken: json.access_token,
        expiresAt,
        lastRefreshAt: Date.now(),
        refreshLock: null,
        lockExpiresAt: 0,
      },
      { merge: true },
    );
  } catch (e) {
    // Loud, because the next refresh depends on this having landed.
    console.error("[xero] FAILED to persist rotated refresh token", e);
    throw new HttpsError(
      "internal",
      "Xero token rotated but could not be saved. Retry shortly — the previous " +
      "token stays valid for 30 minutes.",
    );
  }

  _accessToken = json.access_token;
  _accessTokenExpiresAt = expiresAt;
  return json.access_token;
}

/**
 * Try to claim the refresh lock.
 *
 * Returns `{ claimed, stored }`. A caller that does not claim it waits and
 * re-reads — by then the winner has usually written a fresh access token, so
 * nobody refreshes twice and no rotating token is wasted.
 */
async function claimRefreshLock({ ignoreFreshness = false, rejectToken = null } = {}) {
  return db().runTransaction(async (tx) => {
    const snap = await tx.get(tokenRef());
    if (!snap.exists) throw notConnected("no token document exists.");
    const stored = snap.data();

    // Someone refreshed while we were getting here. `ignoreFreshness` is how
    // the heartbeat still rotates a token that has plenty of life left — it is
    // the age of the *refresh* token it cares about, not the access token.
    if (!ignoreFreshness && isUsable(stored, rejectToken)) {
      return { claimed: false, stored };
    }

    const now = Date.now();
    const lockHeld =
      Boolean(stored.refreshLock) && Number(stored.lockExpiresAt || 0) > now;
    if (lockHeld) return { claimed: false, stored };

    tx.update(tokenRef(), {
      refreshLock: INSTANCE_ID,
      lockExpiresAt: now + LOCK_TTL_MS,
    });
    return { claimed: true, stored };
  });
}

async function releaseRefreshLock() {
  try {
    await tokenRef().update({ refreshLock: null, lockExpiresAt: 0 });
  } catch (e) {
    // The lock self-expires, so a failed release is survivable.
    console.warn("[xero] could not release refresh lock", e.message);
  }
}

/**
 * A valid access token, refreshing only when nobody else already has.
 */
async function getAccessToken({ forceRefresh = false, rejectToken = null } = {}) {
  if (!forceRefresh && !rejectToken && tokenIsFresh(_accessTokenExpiresAt)) {
    return _accessToken;
  }

  // Never hand back a token we were just told is dead.
  if (rejectToken && _accessToken === rejectToken) {
    _accessToken = null;
    _accessTokenExpiresAt = 0;
  }

  // A cold instance usually finds a perfectly good token already in Firestore.
  const snap = await tokenRef().get();
  if (!snap.exists) throw notConnected("no token document exists.");
  const stored = snap.data();
  if (stored.tenantId) {
    _tenantId = stored.tenantId;
    _tenantIdReadAt = Date.now();
  }

  if (!forceRefresh && isUsable(stored, rejectToken)) {
    _accessToken = stored.accessToken;
    _accessTokenExpiresAt = stored.expiresAt;
    return _accessToken;
  }

  const startedAt = Date.now();

  for (let attempt = 0; attempt < LOCK_MAX_POLLS; attempt++) {
    const { claimed, stored: current } = await claimRefreshLock({
      ignoreFreshness: forceRefresh,
      rejectToken,
    });

    if (claimed) {
      try {
        return await refreshAndPersist(current);
      } finally {
        await releaseRefreshLock();
      }
    }

    // Not our turn. Either the winner already published a usable token…
    // (under forceRefresh, only one minted since we started counts — otherwise
    // we would accept the very token we set out to replace.)
    const mintedSinceWeStarted = Number(current.lastRefreshAt || 0) >= startedAt;
    if (isUsable(current, rejectToken) && (!forceRefresh || mintedSinceWeStarted)) {
      _accessToken = current.accessToken;
      _accessTokenExpiresAt = current.expiresAt;
      return _accessToken;
    }
    // …or they are still working on it.
    await sleep(LOCK_POLL_MS);
  }

  throw new HttpsError(
    "deadline-exceeded",
    "Timed out waiting for a Xero token refresh to complete. Try again.",
  );
}

async function getTenantId() {
  const fresh = _tenantId &&
    Date.now() - _tenantIdReadAt < TENANT_CACHE_TTL_MS;
  if (fresh) return _tenantId;

  const snap = await tokenRef().get();
  if (!snap.exists) throw notConnected("no token document exists.");

  const stored = snap.data().tenantId || null;
  if (!stored) throw notConnected("no tenant id is stored.");

  if (_tenantId && stored !== _tenantId) {
    console.warn(
      `[xero] tenant changed from ${_tenantId} to ${stored}; ` +
      "subsequent calls target the new organisation",
    );
  }

  _tenantId = stored;
  _tenantIdReadAt = Date.now();
  return _tenantId;
}

// ── Error shaping ────────────────────────────────────────────────────────────

/**
 * Flatten a Xero error into one readable sentence.
 *
 * Xero's validation failures arrive as a generic "A validation exception
 * occurred" with the actual reasons buried in
 * `Elements[].ValidationErrors[].Message` — surfacing only the top-level
 * message tells the user nothing at all.
 */
function describeXeroError(status, json, text) {
  const parts = [];
  if (json) {
    if (json.Detail) parts.push(json.Detail);
    else if (json.Message) parts.push(json.Message);
    else if (json.Title) parts.push(json.Title);

    const collectValidation = (errors) => {
      for (const ve of errors || []) {
        if (ve && ve.Message && !parts.includes(ve.Message)) parts.push(ve.Message);
      }
    };
    collectValidation(json.ValidationErrors);
    for (const element of json.Elements || []) {
      collectValidation(element.ValidationErrors);
    }
  }
  if (parts.length === 0) {
    parts.push(text ? text.slice(0, 300) : `HTTP ${status}`);
  }
  return parts.join(" — ");
}

function statusToCode(status) {
  switch (status) {
    case 400: return "invalid-argument";
    case 401: return "permission-denied";
    case 403: return "permission-denied";
    case 404: return "not-found";
    case 429: return "resource-exhausted";
    default: return status >= 500 ? "unavailable" : "failed-precondition";
  }
}

// ── Request plumbing ─────────────────────────────────────────────────────────

function buildUrl(path, query) {
  const url = new URL(`${API_BASE}${path}`);
  // 4dp on money, so a rate like 12.5375 per 1000 flyers is not silently
  // rounded to 12.54 before Xero even sees it.
  url.searchParams.set("unitdp", "4");
  for (const [k, v] of Object.entries(query || {})) {
    if (v !== undefined && v !== null && v !== "") url.searchParams.set(k, String(v));
  }
  return url.toString();
}

/**
 * One Xero call. Retries once on 401 with a forced refresh, since a cached
 * token can be revoked server-side before its nominal expiry.
 */
async function xeroRequest(method, path, { query, body, idempotencyKey } = {}) {
  // Token first: getAccessToken() caches the tenant id as a side effect, so a
  // cold instance makes one Firestore read here rather than two.
  const token = await getAccessToken();
  const tenantId = await getTenantId();

  const attempt = async (bearer) => {
    const headers = {
      Authorization: `Bearer ${bearer}`,
      "Xero-Tenant-Id": tenantId,
      Accept: "application/json",
    };
    if (body !== undefined && body !== null) headers["Content-Type"] = "application/json";
    // Xero honours this on POST/PUT (max 128 chars): a retry with the same key
    // returns the original result rather than raising a second invoice.
    if (idempotencyKey) headers["Idempotency-Key"] = String(idempotencyKey).slice(0, 128);

    return fetch(buildUrl(path, query), {
      method,
      headers,
      body: body === undefined || body === null ? undefined : JSON.stringify(body),
    });
  };

  let res = await attempt(token);
  if (res.status === 401) {
    res = await attempt(await getAccessToken({ rejectToken: token }));
  }

  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    /* handled below */
  }

  if (!res.ok) {
    if (res.status === 429) {
      // Xero tells us exactly how long to wait; passing it through lets the UI
      // say "try again in 40s" instead of a bare failure.
      const retryAfter = Number(res.headers.get("retry-after")) || null;
      throw new HttpsError(
        "resource-exhausted",
        retryAfter
          ? `Xero is rate-limiting this organisation. Try again in ${retryAfter}s.`
          : "Xero is rate-limiting this organisation. Try again shortly.",
        { retryAfterSeconds: retryAfter },
      );
    }
    throw new HttpsError(
      statusToCode(res.status),
      `Xero: ${describeXeroError(res.status, json, text)}`,
      { httpStatus: res.status },
    );
  }

  return json === null ? {} : json;
}

/**
 * Fetch a Xero-rendered invoice PDF, base64-encoded.
 *
 * Same GET as the JSON read with `Accept: application/pdf` — Xero renders it
 * with the organisation's own branding theme, so the output matches what Xero
 * itself prints. Kept separate from xeroRequest() because that parses JSON.
 */
async function xeroPdf(path) {
  const token = await getAccessToken();
  const tenantId = await getTenantId();

  const attempt = async (bearer) =>
    fetch(buildUrl(path, {}), {
      method: "GET",
      headers: {
        Authorization: `Bearer ${bearer}`,
        "Xero-Tenant-Id": tenantId,
        Accept: "application/pdf",
      },
    });

  let res = await attempt(token);
  if (res.status === 401) {
    res = await attempt(await getAccessToken({ rejectToken: token }));
  }

  const contentType = res.headers.get("content-type") || "";
  if (!res.ok || contentType.includes("application/json")) {
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* keep text */ }
    throw new HttpsError(
      statusToCode(res.status),
      `Xero: ${describeXeroError(res.status, json, text)}`,
    );
  }

  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.subarray(0, 4).toString("latin1") !== "%PDF") {
    throw new HttpsError("internal", "Xero did not return a PDF.");
  }
  return { pdfBase64: buf.toString("base64"), byteLength: buf.length };
}

// ── Argument helpers ─────────────────────────────────────────────────────────

const str = (v) => typeof v === "string" && v.trim() !== "";
const obj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function requireArg(cond, name) {
  if (!cond) throw new HttpsError("invalid-argument", `${name} is required.`);
}

const enc = encodeURIComponent;

/** Xero's paging params, shared by the list ops. Default 100, max 1000. */
function paging(d) {
  return {
    page: d.page,
    pageSize: d.pageSize === undefined ? undefined : Math.min(Math.max(Number(d.pageSize) || 100, 1), 1000),
  };
}

// ── Operation allowlist ──────────────────────────────────────────────────────

const OPS = {
  // ── Connection ──
  /** Whether Xero is connected, without ever exposing a token. */
  connectionStatus: async () => {
    const snap = await tokenRef().get();
    if (!snap.exists) return { connected: false };
    const d = snap.data();
    return {
      connected: Boolean(d.refreshToken && d.tenantId),
      tenantId: d.tenantId || null,
      tenantName: d.tenantName || null,
      lastRefreshAt: d.lastRefreshAt || null,
      accessTokenExpiresAt: d.expiresAt || null,
    };
  },

  // ── Contacts ──
  listContacts: (d) => xeroRequest("GET", "/Contacts", {
    query: {
      searchTerm: d.searchTerm,
      where: d.where,
      order: d.order,
      includeArchived: d.includeArchived,
      ...paging(d),
    },
  }),

  getContact: (d) => {
    requireArg(str(d.contactId), "contactId");
    return xeroRequest("GET", `/Contacts/${enc(d.contactId)}`);
  },

  createContact: (d) => {
    requireArg(obj(d.contact), "contact");
    requireArg(str(d.contact.Name), "contact.Name");
    return xeroRequest("POST", "/Contacts", {
      body: { Contacts: [d.contact] },
      idempotencyKey: d.idempotencyKey,
    });
  },

  // Xero updates via POST, not PUT.
  updateContact: (d) => {
    requireArg(str(d.contactId), "contactId");
    requireArg(obj(d.contact), "contact");
    return xeroRequest("POST", `/Contacts/${enc(d.contactId)}`, {
      body: { Contacts: [d.contact] },
      idempotencyKey: d.idempotencyKey,
    });
  },

  // ── Invoices ──
  listInvoices: (d) => xeroRequest("GET", "/Invoices", {
    query: {
      // Comma-separated, e.g. "AUTHORISED,PAID".
      Statuses: Array.isArray(d.statuses) ? d.statuses.join(",") : d.statuses,
      ContactIDs: Array.isArray(d.contactIds) ? d.contactIds.join(",") : d.contactIds,
      InvoiceNumbers: Array.isArray(d.invoiceNumbers) ? d.invoiceNumbers.join(",") : d.invoiceNumbers,
      searchTerm: d.searchTerm,
      where: d.where,
      order: d.order,
      // Summary rows only — line items are omitted, which is what keeps a
      // 1000-row page inside the response limit.
      summaryOnly: d.summaryOnly,
      ...paging(d),
    },
  }),

  getInvoice: (d) => {
    requireArg(str(d.invoiceId), "invoiceId");
    return xeroRequest("GET", `/Invoices/${enc(d.invoiceId)}`);
  },

  /** The invoice as Xero itself renders and prints it. */
  getInvoicePdf: (d) => {
    requireArg(str(d.invoiceId), "invoiceId");
    return xeroPdf(`/Invoices/${enc(d.invoiceId)}`);
  },

  /** The customer-facing pay/view link Xero emails out. */
  getOnlineInvoiceUrl: (d) => {
    requireArg(str(d.invoiceId), "invoiceId");
    return xeroRequest("GET", `/Invoices/${enc(d.invoiceId)}/OnlineInvoice`);
  },

  createInvoice: (d) => {
    requireArg(obj(d.invoice), "invoice");
    requireArg(obj(d.invoice.Contact), "invoice.Contact");
    requireArg(
      Array.isArray(d.invoice.LineItems) && d.invoice.LineItems.length > 0,
      "invoice.LineItems",
    );
    return xeroRequest("POST", "/Invoices", {
      body: { Invoices: [{ Type: "ACCREC", ...d.invoice }] },
      idempotencyKey: d.idempotencyKey,
    });
  },

  /**
   * Update an invoice.
   *
   * Two traps, both enforced by Xero rather than here:
   *  - the LineItems array REPLACES the existing one, so any line omitted is
   *    deleted. Send `LineItemID` on lines that should keep their identity.
   *  - line items are immutable once the invoice is AUTHORISED. The app's edit
   *    flow diffs first and falls back to void-and-reissue; this op is still
   *    the right call for the soft fields (Reference, DueDate, Contact).
   */
  updateInvoice: (d) => {
    requireArg(str(d.invoiceId), "invoiceId");
    requireArg(obj(d.invoice), "invoice");
    return xeroRequest("POST", `/Invoices/${enc(d.invoiceId)}`, {
      body: { Invoices: [d.invoice] },
      idempotencyKey: d.idempotencyKey,
    });
  },

  /**
   * Void an AUTHORISED invoice. Xero refuses once a payment or credit note is
   * allocated — that case needs a credit note, which is not wired up yet.
   */
  voidInvoice: (d) => {
    requireArg(str(d.invoiceId), "invoiceId");
    return xeroRequest("POST", `/Invoices/${enc(d.invoiceId)}`, {
      body: { Invoices: [{ InvoiceID: d.invoiceId, Status: "VOIDED" }] },
      idempotencyKey: d.idempotencyKey,
    });
  },

  /** Send the invoice from Xero, using the organisation's own email template. */
  emailInvoice: (d) => {
    requireArg(str(d.invoiceId), "invoiceId");
    return xeroRequest("POST", `/Invoices/${enc(d.invoiceId)}/Email`, { body: {} });
  },

  // ── Payments ──
  createPayment: (d) => {
    requireArg(obj(d.payment), "payment");
    requireArg(obj(d.payment.Invoice), "payment.Invoice");
    requireArg(obj(d.payment.Account), "payment.Account");
    requireArg(
      typeof d.payment.Amount === "number" && d.payment.Amount > 0,
      "payment.Amount (positive number)",
    );
    return xeroRequest("POST", "/Payments", {
      body: { Payments: [d.payment] },
      idempotencyKey: d.idempotencyKey,
    });
  },

  // ── Organisation config, for the setup dropdowns ──
  /**
   * Income accounts, to pick the sales account code line items post to.
   *
   * **Three types, not one.** Xero classes income as REVENUE, SALES or
   * OTHERINCOME, and which one a chart uses depends on how it was set up —
   * a chart migrated from another system may have no REVENUE accounts
   * whatsoever. Asking only for REVENUE returned an empty list on the live
   * organisation and made the sales-account picker look broken.
   */
  listAccounts: () => xeroRequest("GET", "/Accounts", {
    query: {
      where: 'Type=="REVENUE" OR Type=="SALES" OR Type=="OTHERINCOME"',
    },
  }),

  /**
   * Bank accounts, for recording a payment.
   *
   * Separate from listAccounts because a payment posts to the account the money
   * landed in, not the revenue account the invoice was raised against — Xero
   * rejects a payment against a revenue account.
   */
  listBankAccounts: () => xeroRequest("GET", "/Accounts", {
    query: { where: 'Type=="BANK"' },
  }),

  /** Tax rates, to pick which one is the 15% output VAT. */
  listTaxRates: () => xeroRequest("GET", "/TaxRates"),

  /**
   * The Products & Services catalogue — CLM's standard distribution rates.
   *
   * Filtered to sold items: Xero's Items list also carries purchase-only
   * records, which have no SalesDetails and would appear as priceless rows on
   * an invoice line picker.
   *
   * Not paged, deliberately. /Items has no paging parameters and returns the
   * whole catalogue in one call, which for a service business is tens of rows,
   * not thousands.
   */
  listItems: () => xeroRequest("GET", "/Items", {
    query: { where: "IsSold==true" },
  }),

  /** Branding themes control which template the PDF renders with. */
  listBrandingThemes: () => xeroRequest("GET", "/BrandingThemes"),

  /** Organisation details — currency, name, and whether it is a demo company. */
  getOrganisation: () => xeroRequest("GET", "/Organisation"),
};

// ── Callable ─────────────────────────────────────────────────────────────────

exports.xeroAccounting = onCall(
  {
    region: "us-central1",
    secrets: [XERO_CLIENT_ID, XERO_CLIENT_SECRET],
  },
  async (request) => {
    // Signed-in only, no role check — matching the deliberate decision made for
    // zohoBooks, that every account belongs to trusted office staff.
    //
    // **Anonymous sign-ins are excluded**, and that exclusion is what makes the
    // policy above true. Anonymous auth is enabled on this Firebase project
    // (though the app never calls signInAnonymously), so anyone who knows the
    // public web API key can mint a token in one unauthenticated HTTP call.
    // Without this check, "any signed-in user" silently means "anyone on the
    // internet", who could then read every CLM customer and invoice and raise
    // or void invoices in the live books.
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }
    const signInProvider = request.auth.token?.firebase?.sign_in_provider;
    if (signInProvider === "anonymous") {
      throw new HttpsError(
        "permission-denied",
        "Anonymous accounts cannot access Xero. Sign in with a staff account.",
      );
    }

    const { op, ...data } = request.data || {};
    if (!str(op) || !Object.prototype.hasOwnProperty.call(OPS, op)) {
      throw new HttpsError(
        "invalid-argument",
        `Unknown Xero operation "${op}". Allowed: ${Object.keys(OPS).join(", ")}`,
      );
    }

    return OPS[op](data);
  },
);

/**
 * Keep the refresh token alive.
 *
 * A Xero refresh token that goes 60 days unused is dead, and reviving it needs
 * a human at a browser. Daily use makes that cliff unreachable, and turns a
 * silent 60-day failure into a canary that fires the first day something is
 * wrong with the credentials.
 */
exports.xeroTokenHeartbeat = onSchedule(
  {
    schedule: "every day 03:30",
    timeZone: "Africa/Johannesburg",
    region: "us-central1",
    secrets: [XERO_CLIENT_ID, XERO_CLIENT_SECRET],
  },
  async () => {
    const snap = await tokenRef().get();
    if (!snap.exists) {
      console.warn("[xero] heartbeat skipped — Xero is not connected yet.");
      return;
    }
    // Force the rotation rather than reusing a still-valid access token: it is
    // the *refresh* token whose age matters.
    await getAccessToken({ forceRefresh: true });
    const org = await xeroRequest("GET", "/Organisation");
    const name = org?.Organisations?.[0]?.Name || "unknown";
    console.log(`[xero] heartbeat ok — connected to "${name}".`);
  },
);
