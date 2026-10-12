#!/usr/bin/env node
/**
 * Phase 1 verification for the Xero integration.
 *
 * Exercises the whole invoice lifecycle against Xero and prints the
 * organisation-specific values needed to finish the setup (revenue account
 * codes and the 15% output VAT tax type, which go into
 * `companies/clm.providerConfig`).
 *
 * Safety: refuses to touch anything that is not a Demo Company unless --live is
 * passed. It creates a contact and a R0.01 invoice, then voids the invoice —
 * harmless on a demo org, noise in real books.
 *
 * Usage:
 *   node functions/test/xero_smoke.js            # demo org only
 *   node functions/test/xero_smoke.js --safe     # READ-ONLY: writes nothing, any org
 *   node functions/test/xero_smoke.js --live     # allow writes to a real organisation
 *   node functions/test/xero_smoke.js --keep     # don't void the test invoice
 *   node functions/test/xero_smoke.js --refresh  # force a token rotation first
 *
 * The stored access token lasts 30 minutes; this refreshes it automatically
 * when it has gone stale, so the test is runnable at any time.
 *
 * --safe is the mode to use against live books. It proves the connection,
 * the token store and the read path, and harvests the account code and tax type
 * for companies/clm.providerConfig — without leaving a contact or a voided
 * invoice number behind. It cannot verify the write-path assumptions; those
 * need a demo org.
 *
 * Reads the stored token from Firestore via `gcloud auth print-access-token`,
 * the same way ~/xero_connect.js writes it. Run that first.
 */

const { execFileSync } = require("child_process");

const PROJECT = "clmschedule";
const TOKEN_DOC = "secureTokens/xero";
const API_BASE = "https://api.xero.com/api.xro/2.0";

const args = process.argv.slice(2);
const ALLOW_LIVE = args.includes("--live");
const KEEP = args.includes("--keep");
const SAFE = args.includes("--safe");
const FORCE_REFRESH = args.includes("--refresh");

let pass = 0;
let fail = 0;

function ok(label, detail = "") {
  pass++;
  console.log(`  ✓ ${label}${detail ? ` — ${detail}` : ""}`);
}
function bad(label, detail = "") {
  fail++;
  console.log(`  ✗ ${label}${detail ? ` — ${detail}` : ""}`);
}
function section(name) {
  console.log(`\n${name}`);
}

function gcloudToken() {
  return execFileSync("gcloud", ["auth", "print-access-token"], { encoding: "utf8" }).trim();
}

/** Unwrap Firestore REST's typed values back into plain JS. */
function fromFirestoreFields(fields) {
  const out = {};
  for (const [k, v] of Object.entries(fields || {})) {
    if ("stringValue" in v) out[k] = v.stringValue;
    else if ("integerValue" in v) out[k] = Number(v.integerValue);
    else if ("doubleValue" in v) out[k] = v.doubleValue;
    else if ("booleanValue" in v) out[k] = v.booleanValue;
    else if ("nullValue" in v) out[k] = null;
  }
  return out;
}

async function readTokenDoc() {
  const url =
    `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/${TOKEN_DOC}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${gcloudToken()}` } });
  if (res.status === 404) {
    throw new Error(`${TOKEN_DOC} does not exist. Run: node ~/xero_connect.js`);
  }
  if (!res.ok) throw new Error(`Firestore read failed (HTTP ${res.status}): ${await res.text()}`);
  return fromFirestoreFields((await res.json()).fields);
}

function readSecret(name) {
  try {
    return execFileSync("firebase", ["functions:secrets:access", name, "--project", PROJECT], {
      encoding: "utf8",
    }).trim().replace(/[\r\n]/g, "");
  } catch {
    return "";
  }
}

function toFirestoreFields(obj) {
  const fields = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v === null || v === undefined) fields[k] = { nullValue: null };
    else if (typeof v === "number") fields[k] = { integerValue: String(Math.trunc(v)) };
    else fields[k] = { stringValue: String(v) };
  }
  return fields;
}

/**
 * Rotate the refresh token and store the new pair.
 *
 * Mirrors what functions/lib/xero_accounting.js does, so running this both
 * unblocks the test and proves the rotation path actually works — which
 * nothing has exercised yet, since the stored token came straight from consent.
 *
 * The updateMask matters: a PATCH without one REPLACES the document, which
 * would silently drop tenantId and strand the integration.
 */
async function refreshStoredToken(stored) {
  const clientId = readSecret("XERO_CLIENT_ID");
  const clientSecret = readSecret("XERO_CLIENT_SECRET");
  if (!clientId || !clientSecret) {
    throw new Error("Could not read XERO_CLIENT_ID / XERO_CLIENT_SECRET from Secret Manager.");
  }
  const basic = Buffer.from(`${clientId}:${clientSecret}`).toString("base64");

  const exchange = async (refreshToken) => {
    const res = await fetch("https://identity.xero.com/connect/token", {
      method: "POST",
      headers: {
        Authorization: `Basic ${basic}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: refreshToken }),
    });
    const json = await res.json().catch(() => null);
    if (!res.ok || !json?.access_token) {
      const e = new Error(json?.error || `HTTP ${res.status}`);
      e.isInvalidGrant = json?.error === "invalid_grant";
      throw e;
    }
    return json;
  };

  let used = stored.refreshToken;
  let json;
  try {
    json = await exchange(used);
  } catch (e) {
    // Xero keeps a consumed refresh token alive for 30 minutes so a lost
    // response can be retried.
    if (e.isInvalidGrant && stored.previousRefreshToken) {
      used = stored.previousRefreshToken;
      json = await exchange(used);
    } else {
      throw e;
    }
  }

  const expiresAt = Date.now() + (Number(json.expires_in) || 1800) * 1000;
  const patch = {
    refreshToken: json.refresh_token,
    previousRefreshToken: used,
    accessToken: json.access_token,
    expiresAt,
    lastRefreshAt: Date.now(),
  };

  const mask = Object.keys(patch).map((f) => `updateMask.fieldPaths=${f}`).join("&");
  const url =
    `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/${TOKEN_DOC}?${mask}`;
  const res = await fetch(url, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${gcloudToken()}`, "Content-Type": "application/json" },
    body: JSON.stringify({ fields: toFirestoreFields(patch) }),
  });
  if (!res.ok) {
    throw new Error(`Failed to persist the rotated token (HTTP ${res.status}): ${await res.text()}`);
  }

  return { accessToken: json.access_token, expiresAt };
}

let ACCESS_TOKEN = null;
let TENANT_ID = null;
let lastLimits = "";

async function xero(method, path, { query, body, idempotencyKey, accept } = {}) {
  const url = new URL(`${API_BASE}${path}`);
  url.searchParams.set("unitdp", "4");
  for (const [k, v] of Object.entries(query || {})) {
    if (v !== undefined && v !== null && v !== "") url.searchParams.set(k, String(v));
  }

  const headers = {
    Authorization: `Bearer ${ACCESS_TOKEN}`,
    "Xero-Tenant-Id": TENANT_ID,
    Accept: accept || "application/json",
  };
  if (body) headers["Content-Type"] = "application/json";
  if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;

  const res = await fetch(url.toString(), {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });

  lastLimits =
    `day ${res.headers.get("x-daylimit-remaining") ?? "?"} · ` +
    `min ${res.headers.get("x-minlimit-remaining") ?? "?"}`;

  if (accept === "application/pdf" && res.ok) {
    return Buffer.from(await res.arrayBuffer());
  }

  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* below */ }

  if (!res.ok) {
    const parts = [];
    if (json?.Detail) parts.push(json.Detail);
    else if (json?.Message) parts.push(json.Message);
    for (const el of json?.Elements || []) {
      for (const ve of el.ValidationErrors || []) parts.push(ve.Message);
    }
    const err = new Error(parts.join(" — ") || text.slice(0, 300) || `HTTP ${res.status}`);
    err.status = res.status;
    throw err;
  }
  return json;
}

async function main() {
  console.log("=== Xero Phase 1 smoke test ===");

  section("Token store");
  const stored = await readTokenDoc();
  TENANT_ID = stored.tenantId;
  ok("read secureTokens/xero", `tenant "${stored.tenantName}"`);

  const stale = !stored.expiresAt || Date.now() > stored.expiresAt - 60_000;
  if (stale || FORCE_REFRESH) {
    // Worth doing on its own merits: until something rotates the token, the
    // refresh path is untested and the 60-day clock is the only thing proving
    // it works — far too late to find out.
    const refreshed = await refreshStoredToken(stored);
    ACCESS_TOKEN = refreshed.accessToken;
    ok("rotated the refresh token", stale ? "stored one had expired" : "--refresh");
  } else {
    ACCESS_TOKEN = stored.accessToken;
    ok("access token is valid",
      `${Math.round((stored.expiresAt - Date.now()) / 60000)} min left`);
  }

  section("Organisation");
  const org = (await xero("GET", "/Organisation")).Organisations[0];
  const isDemo = org.IsDemoCompany === true || /demo/i.test(org.Name || "");
  ok("GET /Organisation", `${org.Name} · ${org.BaseCurrency} · ${org.CountryCode}`);
  if (SAFE) {
    console.log("  --safe: read-only run, nothing will be written to this organisation");
  } else if (isDemo) {
    ok("this is a demo company", "safe to write test data");
  } else if (ALLOW_LIVE) {
    console.log("  ! NOT a demo company — writing test data because --live was passed");
  } else {
    bad("refusing to write to a non-demo organisation",
      "use --safe for a read-only check, or --live to write anyway");
    process.exit(1);
  }

  section("Config values for companies/clm.providerConfig");
  const accounts = (await xero("GET", "/Accounts", {
    query: { where: 'Type=="REVENUE" OR Type=="SALES" OR Type=="OTHERINCOME"' },
  })).Accounts || [];
  ok(`GET /Accounts (REVENUE)`, `${accounts.length} found`);
  for (const a of accounts.slice(0, 10)) {
    console.log(`      salesAccountCode=${a.Code}  ${a.Name}  (default tax ${a.TaxType})`);
  }

  const taxRates = (await xero("GET", "/TaxRates")).TaxRates || [];
  const outputRates = taxRates.filter(
    (t) => /output|sales/i.test(t.Name || "") || (t.CanApplyToRevenue && t.EffectiveRate > 0),
  );
  ok("GET /TaxRates", `${taxRates.length} total, ${outputRates.length} usable on revenue`);
  for (const t of outputRates.slice(0, 10)) {
    console.log(`      salesTaxType=${t.TaxType}  ${t.Name}  ${t.EffectiveRate}%`);
  }
  if (accounts.length === 0) {
    bad("no revenue accounts", "cannot build a line item");

    // Diagnostics: Xero classes income under several types, and a chart that
    // uses SALES or OTHERINCOME instead of REVENUE reads as "no accounts".
    const all = (await xero("GET", "/Accounts")).Accounts || [];
    const byType = {};
    for (const a of all) (byType[a.Type] ||= []).push(a);
    console.log("\n    All account types on this organisation:");
    for (const [type, list] of Object.entries(byType).sort()) {
      console.log(`      ${type}  (${list.length})`);
      if (["REVENUE", "SALES", "OTHERINCOME"].includes(type)) {
        for (const a of list.slice(0, 10)) {
          console.log(`         ${a.Code}  ${a.Name}  (default tax ${a.TaxType})`);
        }
      }
    }
    console.log();
    process.exit(1);
  }
  const salesAccount = accounts[0];
  const accountCode = salesAccount.Code;

  // Picking "the first 15% rate" is WRONG on a real South African organisation.
  // Xero seeds ZA orgs with several 15% output rates, and the first in list
  // order is ACC28PLUS ("Accommodation exceeding 28 days") — a hospitality
  // rate. Coding distribution income to it gets the percentage right and the
  // VAT201 line wrong, which is an accounting error, not a cosmetic one.
  //
  // Preference order:
  //   1. The sales account's own default tax type. This is authoritative — it
  //      is what Xero itself applies to a line posted to that account.
  //   2. A 15% rate literally named "standard rate sales".
  //   3. Any 15% rate, flagged loudly for a human to confirm.
  const fifteens = outputRates.filter((t) => Number(t.EffectiveRate) === 15);
  const byAccountDefault = fifteens.find(
    (t) => t.TaxType === salesAccount.TaxType,
  );
  const byStandardName = fifteens.find(
    (t) => /^standard rate sales$/i.test((t.Name || "").trim()),
  );

  const fifteen = byAccountDefault || byStandardName || fifteens[0];

  if (!fifteen) {
    console.log("  ! no 15% output rate on this org — expected on a non-ZA demo company");
  } else if (byAccountDefault) {
    ok(
      "found the 15% output rate",
      `use salesTaxType=${fifteen.TaxType} (${fifteen.Name}) — the default on ` +
      `account ${accountCode} ${salesAccount.Name}`,
    );
  } else if (byStandardName) {
    ok(
      "found the 15% output rate",
      `use salesTaxType=${fifteen.TaxType} (${fifteen.Name}) — matched by name; ` +
      `account ${accountCode} defaults to ${salesAccount.TaxType || "nothing"}`,
    );
  } else {
    console.log(
      `  ! ${fifteens.length} rates are at 15% and none is the account default ` +
      `or named "Standard Rate Sales".\n` +
      `    Falling back to salesTaxType=${fifteen.TaxType} (${fifteen.Name}) — ` +
      `CONFIRM THIS WITH THE BOOKKEEPER before invoicing. A rate that is 15%\n` +
      `    but the wrong type (accommodation, capital goods, export) reports ` +
      `on the wrong VAT201 line.`,
    );
  }

  const taxType = fifteen ? fifteen.TaxType : undefined;

  section("Items (Products & Services)");
  const items = (await xero("GET", "/Items", { query: { where: "IsSold==true" } })).Items || [];
  if (items.length === 0) {
    console.log("  ! no sold items in this organisation yet.");
    console.log("    Job types cannot be mapped to a catalogue item until you");
    console.log("    create them in Xero under Business > Products & Services,");
    console.log("    each with a sales price.");
  } else {
    ok("GET /Items (IsSold)", `${items.length} found`);
    for (const i of items.slice(0, 15)) {
      const sales = i.SalesDetails || {};
      const price = sales.UnitPrice != null ? `R${sales.UnitPrice}` : "(no price)";
      console.log(
        `      accountingItemCode=${i.Code}  ${i.Name || ""}  ${price}` +
        `${sales.AccountCode ? `  acct ${sales.AccountCode}` : ""}` +
        `${sales.TaxType ? `  tax ${sales.TaxType}` : ""}`,
      );
    }
    if (items.length > 15) console.log(`      ... and ${items.length - 15} more`);
  }

  section("Contacts");
  const contactPage = await xero("GET", "/Contacts", { query: { pageSize: 5, page: 1 } });
  ok("GET /Contacts paged", `${(contactPage.Contacts || []).length} on page 1`);

  if (SAFE) {
    section("Invoices (read-only)");
    const invPage = await xero("GET", "/Invoices", {
      query: { pageSize: 5, page: 1, summaryOnly: true, order: "Date DESC" },
    });
    const invoices = invPage.Invoices || [];
    ok("GET /Invoices paged", `${invoices.length} on page 1`);
    for (const i of invoices.slice(0, 5)) {
      console.log(`      ${i.InvoiceNumber}  ${i.Status}  ${i.Total}  ${i.Contact?.Name || ""}`);
    }

    section("Rate limits");
    console.log(`  remaining: ${lastLimits}`);

    console.log(`\n${fail === 0 ? "PASS (read-only)" : "FAIL"} — ${pass} passed, ${fail} failed`);
    console.log("\nNot verified by --safe, because all three need writes:");
    console.log("  · Idempotency-Key replays rather than duplicates");
    console.log("  · line-item edits on an AUTHORISED invoice are rejected");
    console.log("  · soft-field edits on an AUTHORISED invoice are accepted");
    console.log("Run the full test against a Xero Demo Company before Phase 4.\n");
    process.exit(fail === 0 ? 0 : 1);
  }

  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const created = await xero("POST", "/Contacts", {
    body: { Contacts: [{ Name: `ZZZ API Smoke Test ${stamp}`, EmailAddress: "smoke@example.invalid" }] },
    idempotencyKey: `smoke-contact-${stamp}`,
  });
  const contactId = created.Contacts[0].ContactID;
  ok("POST /Contacts", contactId);

  section("Invoice lifecycle");
  const idemKey = `smoke-invoice-${stamp}`;
  const invoicePayload = {
    Invoices: [{
      Type: "ACCREC",
      Contact: { ContactID: contactId },
      Date: new Date().toISOString().slice(0, 10),
      DueDate: new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10),
      Reference: "API smoke test",
      Status: "AUTHORISED",
      LineAmountTypes: "Exclusive",
      LineItems: [{
        Description: "Smoke test line — safe to void",
        Quantity: 1,
        UnitAmount: 0.01,
        AccountCode: accountCode,
        ...(taxType ? { TaxType: taxType } : {}),
      }],
    }],
  };

  const inv = (await xero("POST", "/Invoices", { body: invoicePayload, idempotencyKey: idemKey })).Invoices[0];
  ok("POST /Invoices AUTHORISED", `${inv.InvoiceNumber} · total ${inv.Total} · tax ${inv.TotalTax}`);
  if (!inv.InvoiceNumber) bad("no InvoiceNumber assigned on create");

  // The design leans on this: the saga retries a create after a network blip,
  // and must not raise a second invoice.
  const repeat = (await xero("POST", "/Invoices", { body: invoicePayload, idempotencyKey: idemKey })).Invoices[0];
  if (repeat.InvoiceID === inv.InvoiceID) {
    ok("Idempotency-Key replays the original", repeat.InvoiceID);
  } else {
    bad("Idempotency-Key created a DUPLICATE", `${inv.InvoiceID} vs ${repeat.InvoiceID}`);
    console.log("      ^ the saga's retry safety depends on this — investigate before Phase 4");
  }

  // Whether AUTHORISED invoices accept line-item edits decides the entire edit
  // flow: amend in place, or void and reissue. An HTTP 200 is NOT proof — Xero
  // can accept a payload and ignore fields — so assert the invoice actually
  // changed, and that the change survives a re-read.
  try {
    const updated = (await xero("POST", `/Invoices/${inv.InvoiceID}`, {
      body: { Invoices: [{ InvoiceID: inv.InvoiceID, LineItems: [{
        Description: "amended by smoke test", Quantity: 1, UnitAmount: 99, AccountCode: accountCode,
        ...(taxType ? { TaxType: taxType } : {}),
      }] }] },
    })).Invoices[0];

    if (Number(updated.SubTotal) !== 99) {
      bad("line-item edit was accepted but did NOT take effect",
        `SubTotal is ${updated.SubTotal}, expected 99 — Xero silently ignored it`);
      console.log("      ^ treat AUTHORISED invoices as immutable: keep void-and-reissue");
    } else {
      // Confirm it persisted rather than just being echoed back.
      const reread = (await xero("GET", `/Invoices/${inv.InvoiceID}`)).Invoices[0];
      if (Number(reread.SubTotal) === 99) {
        ok("line-item edit on AUTHORISED takes effect and persists",
          `SubTotal ${inv.SubTotal} → ${reread.SubTotal}`);
        console.log("      → invoices can be AMENDED IN PLACE while unpaid.");
        console.log("        Void-and-reissue is only needed once a payment is allocated.");
        const line = (reread.LineItems || [])[0];
        console.log(`      line count after edit: ${(reread.LineItems || []).length}` +
          `, LineItemID ${line?.LineItemID ? "assigned" : "missing"}`);
      } else {
        bad("edit was echoed back but did not persist",
          `re-read SubTotal is ${reread.SubTotal}`);
      }
    }
  } catch (e) {
    ok("line-item edit on AUTHORISED is rejected",
      `void-and-reissue is required: ${e.message.slice(0, 100)}`);
  }

  // Soft fields should still update in place — branch 1 of the edit flow.
  try {
    await xero("POST", `/Invoices/${inv.InvoiceID}`, {
      body: { Invoices: [{ InvoiceID: inv.InvoiceID, Reference: "API smoke test (amended)" }] },
    });
    ok("soft-field update on AUTHORISED works", "Reference amended in place");
  } catch (e) {
    bad("soft-field update rejected", e.message.slice(0, 120));
  }

  const pdf = await xero("GET", `/Invoices/${inv.InvoiceID}`, { accept: "application/pdf" });
  if (pdf.subarray(0, 4).toString("latin1") === "%PDF") {
    ok("GET invoice PDF", `${pdf.length} bytes`);
  } else {
    bad("PDF response was not a PDF");
  }

  try {
    const online = await xero("GET", `/Invoices/${inv.InvoiceID}/OnlineInvoice`);
    ok("GET /OnlineInvoice", (online.OnlineInvoices?.[0]?.OnlineInvoiceUrl || "").slice(0, 60) + "…");
  } catch (e) {
    bad("GET /OnlineInvoice", e.message.slice(0, 120));
  }

  if (KEEP) {
    console.log(`\n  --keep: leaving ${inv.InvoiceNumber} in place.`);
  } else {
    const voided = (await xero("POST", `/Invoices/${inv.InvoiceID}`, {
      body: { Invoices: [{ InvoiceID: inv.InvoiceID, Status: "VOIDED" }] },
    })).Invoices[0];
    if (voided.Status === "VOIDED") ok("void", `${voided.InvoiceNumber} is VOIDED`);
    else bad("void did not take", `status is ${voided.Status}`);
  }

  section("Rate limits");
  console.log(`  remaining: ${lastLimits}`);

  console.log(`\n${fail === 0 ? "PASS" : "FAIL"} — ${pass} passed, ${fail} failed\n`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(`\nFailed: ${e.message}\n`);
  process.exit(1);
});
