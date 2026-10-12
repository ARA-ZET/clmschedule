/**
 * Zoho Books API v3 proxy.
 *
 * The client_secret and refresh_token never reach the Flutter app. This app
 * ships as a web build (see deploy_web.sh), where --dart-define values are
 * compiled into the JS bundle and readable from devtools — so the credentials
 * live here as Firebase secrets and every Zoho call is proxied.
 *
 * Set the three secrets once:
 *   firebase functions:secrets:set ZOHO_CLIENT_ID
 *   firebase functions:secrets:set ZOHO_CLIENT_SECRET
 *   firebase functions:secrets:set ZOHO_REFRESH_TOKEN
 *
 * This is deliberately NOT a generic pass-through. `op` is matched against a
 * fixed allowlist below, each entry pinning its own HTTP method and path
 * template, so a signed-in user cannot reach arbitrary Zoho endpoints.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");

const ZOHO_CLIENT_ID = defineSecret("ZOHO_CLIENT_ID");
const ZOHO_CLIENT_SECRET = defineSecret("ZOHO_CLIENT_SECRET");
const ZOHO_REFRESH_TOKEN = defineSecret("ZOHO_REFRESH_TOKEN");

// ── Organisation config ──────────────────────────────────────────────────────
// Data centre suffix — books.zoho.com => "com".
const ZOHO_DC = "com";
// Junk & Stuff — the organisation used when a caller names none, which is
// every call made before Happy Sun got its own books.
const ZOHO_ORG_ID = "747658013";

const API_BASE = `https://www.zohoapis.${ZOHO_DC}/books/v3`;
const ACCOUNTS_BASE = `https://accounts.zoho.${ZOHO_DC}`;

// ── Access token cache ───────────────────────────────────────────────────────
// Zoho access tokens last ~1h. Cached in module scope so a warm instance
// reuses one token across calls; a cold start just refreshes again.
// Refreshed 5 minutes early to avoid racing the expiry.
const TOKEN_SKEW_MS = 5 * 60 * 1000;
let _accessToken = null;
let _accessTokenExpiresAt = 0;
let _refreshInFlight = null;

async function refreshAccessToken() {
  // Single-flight: concurrent calls on the same instance share one refresh
  // instead of each burning a request against Zoho's rate limit.
  if (_refreshInFlight) return _refreshInFlight;

  _refreshInFlight = (async () => {
    const body = new URLSearchParams({
      refresh_token: ZOHO_REFRESH_TOKEN.value(),
      client_id: ZOHO_CLIENT_ID.value(),
      client_secret: ZOHO_CLIENT_SECRET.value(),
      grant_type: "refresh_token",
    });

    const res = await fetch(`${ACCOUNTS_BASE}/oauth/v2/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });

    const text = await res.text();
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      throw new HttpsError("internal", `Zoho token endpoint returned non-JSON (HTTP ${res.status}).`);
    }

    // The token endpoint signals failure with an `error` field, not `code`.
    if (!res.ok || json.error || !json.access_token) {
      throw new HttpsError(
        "permission-denied",
        `Zoho token refresh failed: ${json.error || `HTTP ${res.status}`}. ` +
        "Check the ZOHO_REFRESH_TOKEN / ZOHO_CLIENT_ID / ZOHO_CLIENT_SECRET secrets.",
      );
    }

    _accessToken = json.access_token;
    // expires_in is seconds; default to 1h if Zoho omits it.
    const ttlMs = (Number(json.expires_in) || 3600) * 1000;
    _accessTokenExpiresAt = Date.now() + ttlMs;
    return _accessToken;
  })();

  try {
    return await _refreshInFlight;
  } finally {
    _refreshInFlight = null;
  }
}

async function getAccessToken() {
  if (_accessToken && Date.now() < _accessTokenExpiresAt - TOKEN_SKEW_MS) {
    return _accessToken;
  }
  return refreshAccessToken();
}

// ── Request plumbing ─────────────────────────────────────────────────────────

/**
 * Perform one Zoho Books call. Retries once on 401 with a fresh token, since a
 * cached token can be revoked server-side before its nominal expiry.
 */
async function zohoRequest(method, path, { query = {}, body = null, orgId = ZOHO_ORG_ID } = {}) {
  const attempt = async (token) => {
    const url = new URL(`${API_BASE}${path}`);
    // null = an org-less endpoint (/organizations itself).
    if (orgId) url.searchParams.set("organization_id", orgId);
    for (const [k, v] of Object.entries(query)) {
      if (v !== undefined && v !== null && v !== "") {
        url.searchParams.set(k, String(v));
      }
    }

    const headers = { Authorization: `Zoho-oauthtoken ${token}` };
    if (body !== null) headers["Content-Type"] = "application/json";

    return fetch(url.toString(), {
      method,
      headers,
      body: body === null ? undefined : JSON.stringify(body),
    });
  };

  let res = await attempt(await getAccessToken());
  if (res.status === 401) {
    _accessToken = null;
    res = await attempt(await refreshAccessToken());
  }

  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    throw new HttpsError("internal", `Zoho returned non-JSON (HTTP ${res.status}): ${text.slice(0, 300)}`);
  }

  // Zoho signals success with "code": 0. Anything else is an error, even on
  // HTTP 200 — so check the payload, not just the status.
  if (json.code !== 0) {
    const message = json.message || `HTTP ${res.status}`;
    // 429 / Zoho's rate-limit codes deserve a retryable status for the client.
    const status = res.status === 429 ? "resource-exhausted"
      : res.status === 404 ? "not-found"
        : res.status === 401 || res.status === 403 ? "permission-denied"
          : "failed-precondition";
    throw new HttpsError(status, `Zoho Books: ${message}`, { zohoCode: json.code ?? null });
  }

  return json;
}

/**
 * Fetch a Zoho-rendered PDF and return it base64-encoded.
 *
 * Same endpoint as the JSON read, with `accept=pdf` — Zoho renders it with the
 * organisation's own invoice template, so the output matches what Zoho Books
 * itself prints. Kept separate from zohoRequest() because that one parses the
 * body as JSON and checks `code`; a PDF response has neither.
 */
async function zohoPdf(path, orgId = ZOHO_ORG_ID) {
  const attempt = async (token) => {
    const url = new URL(`${API_BASE}${path}`);
    url.searchParams.set("organization_id", orgId);
    url.searchParams.set("accept", "pdf");
    return fetch(url.toString(), {
      method: "GET",
      headers: {
        Authorization: `Zoho-oauthtoken ${token}`,
        Accept: "application/pdf",
      },
    });
  };

  let res = await attempt(await getAccessToken());
  if (res.status === 401) {
    _accessToken = null;
    res = await attempt(await refreshAccessToken());
  }

  const contentType = res.headers.get("content-type") || "";

  // An error comes back as JSON even though we asked for a PDF.
  if (!res.ok || contentType.includes("application/json")) {
    let message = `HTTP ${res.status}`;
    try {
      const json = JSON.parse(await res.text());
      message = json.message || message;
    } catch { /* keep the status-based message */ }
    throw new HttpsError(
      res.status === 404 ? "not-found" : "failed-precondition",
      `Zoho Books: ${message}`,
    );
  }

  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.subarray(0, 4).toString("latin1") !== "%PDF") {
    throw new HttpsError("internal", "Zoho did not return a PDF.");
  }

  return { pdfBase64: buf.toString("base64"), byteLength: buf.length };
}

// ── Organisations ────────────────────────────────────────────────────────────
// One Zoho login holds several organisations — Junk & Stuff and Happy Sun —
// and the refresh token reaches all of them; only `organization_id` differs.
// The caller names the org, but it is checked against the orgs this token can
// actually see, so the proxy never forwards an arbitrary id. Cached per
// instance: the org list changes about once a year.
const ORG_CACHE_MS = 60 * 60 * 1000;
let _orgIds = null;
let _orgIdsAt = 0;

async function listOrganizations() {
  return zohoRequest("GET", "/organizations", { orgId: null });
}

async function resolveOrgId(requested) {
  if (requested === undefined || requested === null || requested === "") return ZOHO_ORG_ID;
  const id = String(requested).trim();
  if (!/^\d+$/.test(id)) throw new HttpsError("invalid-argument", "organizationId must be numeric.");
  if (id === ZOHO_ORG_ID) return id;

  const known = () => _orgIds && _orgIds.has(id) && Date.now() - _orgIdsAt < ORG_CACHE_MS;
  if (!known()) {
    const json = await listOrganizations();
    _orgIds = new Set((json.organizations || []).map((o) => String(o.organization_id)));
    _orgIdsAt = Date.now();
  }
  if (!_orgIds.has(id)) {
    throw new HttpsError("permission-denied",
      `Zoho organisation ${id} is not reachable with this Zoho login.`);
  }
  return id;
}

// ── Operation allowlist ──────────────────────────────────────────────────────

const str = (v) => typeof v === "string" && v.trim() !== "";
const obj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function requireArg(cond, name) {
  if (!cond) throw new HttpsError("invalid-argument", `${name} is required.`);
}

const OPS = {
  // The organisations this Zoho login can reach — used to look up an org id
  // for a company's settings. Not org-scoped itself.
  listOrganizations: () => listOrganizations(),

  // ── Customers ──
  createCustomer: (d, orgId) => {
    requireArg(obj(d.contact), "contact");
    requireArg(str(d.contact.contact_name), "contact.contact_name");
    return zohoRequest("POST", "/contacts", {
      orgId,
      body: { ...d.contact, contact_type: "customer" },
    });
  },

  listCustomers: (d, orgId) => zohoRequest("GET", "/contacts", {
    orgId,
    query: {
      contact_type: "customer",
      search_text: d.searchText,
      page: d.page,
      per_page: d.perPage,
    },
  }),

  // Needed before an update: the list response omits `contact_persons`, and
  // editing a contact's details requires the primary contact_person_id.
  getCustomer: (d, orgId) => {
    requireArg(str(d.contactId), "contactId");
    return zohoRequest("GET", `/contacts/${encodeURIComponent(d.contactId)}`, { orgId });
  },

  updateCustomer: (d, orgId) => {
    requireArg(str(d.contactId), "contactId");
    requireArg(obj(d.contact), "contact");
    return zohoRequest("PUT", `/contacts/${encodeURIComponent(d.contactId)}`, {
      orgId,
      body: d.contact,
    });
  },

  // ── Items ──
  /**
   * The item catalogue — Junk & Stuff's standard services and their rates.
   *
   * `status: "active"` so archived items do not turn up in a picker. Paged,
   * unlike Xero's /Items, because Zoho caps `per_page` at 200.
   */
  listItems: (d, orgId) => zohoRequest("GET", "/items", {
    orgId,
    query: {
      // Zoho's List Items endpoint filters through `filter_by`, not a `status`
      // parameter — `status` is a field ON an item, not a query for the list.
      filter_by: "Status.Active",
      search_text: d.searchText,
      page: d.page,
      per_page: d.perPage,
    },
  }),

  // ── Invoices ──
  createInvoice: (d, orgId) => {
    requireArg(obj(d.invoice), "invoice");
    requireArg(str(d.invoice.customer_id), "invoice.customer_id");
    requireArg(Array.isArray(d.invoice.line_items) && d.invoice.line_items.length > 0,
      "invoice.line_items");
    // Only bypass Zoho's auto-numbering when we're actually supplying a number.
    const keepOwnNumber = str(d.invoice.invoice_number);
    return zohoRequest("POST", "/invoices", {
      orgId,
      query: keepOwnNumber ? { ignore_auto_number_generation: "true" } : {},
      body: d.invoice,
    });
  },

  updateInvoice: (d, orgId) => {
    requireArg(str(d.invoiceId), "invoiceId");
    requireArg(obj(d.invoice), "invoice");
    return zohoRequest("PUT", `/invoices/${encodeURIComponent(d.invoiceId)}`, {
      orgId,
      body: d.invoice,
    });
  },

  getInvoice: (d, orgId) => {
    requireArg(str(d.invoiceId), "invoiceId");
    return zohoRequest("GET", `/invoices/${encodeURIComponent(d.invoiceId)}`, { orgId });
  },

  // The invoice as Zoho Books itself renders and prints it.
  getInvoicePdf: (d, orgId) => {
    requireArg(str(d.invoiceId), "invoiceId");
    return zohoPdf(`/invoices/${encodeURIComponent(d.invoiceId)}`, orgId);
  },

  listInvoices: (d, orgId) => zohoRequest("GET", "/invoices", {
    orgId,
    query: {
      status: d.status,
      customer_id: d.customerId,
      search_text: d.searchText,
      // Sorting and date-ranging are done by Zoho so a paged client stays
      // correct. Note Zoho rejects sort_column=status.
      sort_column: d.sortColumn,
      sort_order: d.sortOrder,
      date_start: d.dateStart,
      date_end: d.dateEnd,
      page: d.page,
      per_page: d.perPage,
    },
  }),

  // Status changes go through the action endpoints — PUT-ing `status` is
  // ignored by Zoho.
  markInvoiceSent: (d, orgId) => {
    requireArg(str(d.invoiceId), "invoiceId");
    return zohoRequest("POST", `/invoices/${encodeURIComponent(d.invoiceId)}/status/sent`, { orgId });
  },

  voidInvoice: (d, orgId) => {
    requireArg(str(d.invoiceId), "invoiceId");
    return zohoRequest("POST", `/invoices/${encodeURIComponent(d.invoiceId)}/status/void`, { orgId });
  },

  draftInvoice: (d, orgId) => {
    requireArg(str(d.invoiceId), "invoiceId");
    return zohoRequest("POST", `/invoices/${encodeURIComponent(d.invoiceId)}/status/draft`, { orgId });
  },

  // "Paid" is not a toggle — it's a recorded payment.
  recordPayment: (d, orgId) => {
    requireArg(obj(d.payment), "payment");
    requireArg(str(d.payment.customer_id), "payment.customer_id");
    requireArg(typeof d.payment.amount === "number" && d.payment.amount > 0,
      "payment.amount (positive number)");
    return zohoRequest("POST", "/customerpayments", { orgId, body: d.payment });
  },
};

exports.zohoBooks = onCall(
  {
    region: "us-central1",
    secrets: [ZOHO_CLIENT_ID, ZOHO_CLIENT_SECRET, ZOHO_REFRESH_TOKEN],
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in.");
    }

    const { op, ...data } = request.data || {};
    if (!str(op) || !Object.prototype.hasOwnProperty.call(OPS, op)) {
      throw new HttpsError(
        "invalid-argument",
        `Unknown Zoho operation "${op}". Allowed: ${Object.keys(OPS).join(", ")}`,
      );
    }

    const { organizationId, ...args } = data;
    const orgId = op === "listOrganizations" ? null : await resolveOrgId(organizationId);
    return OPS[op](args, orgId);
  },
);
