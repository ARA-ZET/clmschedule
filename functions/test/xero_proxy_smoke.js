#!/usr/bin/env node
/**
 * Exercises the DEPLOYED `xeroAccounting` callable — the path the Flutter app
 * actually uses.
 *
 * xero_smoke.js talks straight to Xero and so proves nothing about the proxy:
 * its token store, its lock, its op allowlist, its error flattening and its
 * response shapes are all untested by that script. This closes that gap.
 *
 * Auth: the callable rejects unauthenticated AND anonymous callers, so this
 * needs a real staff ID token. Get one from the running web app's devtools:
 *
 *   await firebase.auth().currentUser.getIdToken()
 *
 * or, in the Flutter web build's console, copy the token from a network request
 * to any callable. Then:
 *
 *   FIREBASE_ID_TOKEN=eyJ... node functions/test/xero_proxy_smoke.js
 *   FIREBASE_ID_TOKEN=eyJ... node functions/test/xero_proxy_smoke.js --write
 *
 * Without a token it still runs the auth-gate checks — which are the ones worth
 * never skipping — and stops there.
 */

const { execFileSync } = require("child_process");

const PROJECT = "clmschedule";
const REGION = "us-central1";
const ENDPOINT = `https://${REGION}-${PROJECT}.cloudfunctions.net/xeroAccounting`;

const WRITE = process.argv.includes("--write");

let pass = 0;
let fail = 0;
const ok = (l, d = "") => { pass++; console.log(`  ✓ ${l}${d ? ` — ${d}` : ""}`); };
const bad = (l, d = "") => { fail++; console.log(`  ✗ ${l}${d ? ` — ${d}` : ""}`); };
const section = (n) => console.log(`\n${n}`);

function webApiKey() {
  const src = require("fs").readFileSync("lib/firebase_options.dart", "utf8");
  const m = src.match(/apiKey:\s*'(AIza[A-Za-z0-9_-]+)'/);
  if (!m) throw new Error("Could not read the web API key from firebase_options.dart");
  return m[1];
}

async function signIn() {
  const res = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${webApiKey()}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ returnSecureToken: true }),
    },
  );
  const json = await res.json();
  if (!json.idToken) {
    throw new Error(
      `Could not mint a test token: ${JSON.stringify(json.error || json)}. ` +
      "Anonymous auth may be disabled — supply FIREBASE_ID_TOKEN instead.",
    );
  }
  return json.idToken;
}

let ID_TOKEN = null;

/** Call one allowlisted op, exactly as the Flutter service does. */
async function callOp(op, data = {}, { expectError = false } = {}) {
  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${ID_TOKEN}`,
    },
    body: JSON.stringify({ data: { op, ...data } }),
  });
  const json = await res.json().catch(() => null);

  if (json && json.error) {
    if (expectError) return { error: json.error };
    const e = new Error(json.error.message || JSON.stringify(json.error));
    e.status = json.error.status;
    e.details = json.error.details;
    throw e;
  }
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  if (expectError) return { error: null, result: json.result };
  return json.result;
}

async function main() {
  console.log("=== Xero PROXY smoke test (deployed callable) ===");

  section("Auth gate");
  // Unauthenticated must be refused, or the allowlist is the only thing
  // standing between the internet and CLM's books.
  const anon = await fetch(ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ data: { op: "connectionStatus" } }),
  });
  const anonJson = await anon.json().catch(() => ({}));
  if (anonJson?.error?.status === "UNAUTHENTICATED") {
    ok("unauthenticated calls are refused");
  } else {
    bad("unauthenticated call was NOT refused", JSON.stringify(anonJson).slice(0, 120));
  }

  // Anonymous auth is enabled on this project and the app never uses it, so a
  // token can be minted by anyone holding the public web API key. If the
  // callable accepted those, "any signed-in user" would mean "anyone".
  let anonToken = null;
  try {
    anonToken = await signIn();
  } catch {
    ok("anonymous sign-in is disabled project-wide", "nothing to reject");
  }
  if (anonToken) {
    const res = await fetch(ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${anonToken}` },
      body: JSON.stringify({ data: { op: "connectionStatus" } }),
    });
    const j = await res.json().catch(() => ({}));
    if (j?.error?.status === "PERMISSION_DENIED") {
      ok("anonymous callers are refused", "the internet cannot reach CLM's books");
    } else {
      bad("ANONYMOUS CALLER WAS ACCEPTED",
        "anyone with the public web API key can read and write Xero");
    }
  }

  ID_TOKEN = process.env.FIREBASE_ID_TOKEN;
  if (!ID_TOKEN) {
    console.log("\n  No FIREBASE_ID_TOKEN — stopping after the auth-gate checks.");
    console.log("  Supply a staff token to exercise the ops:");
    console.log("    FIREBASE_ID_TOKEN=eyJ... node functions/test/xero_proxy_smoke.js\n");
    console.log(`${fail === 0 ? "PASS" : "FAIL"} — ${pass} passed, ${fail} failed\n`);
    process.exit(fail === 0 ? 0 : 1);
  }
  ok("signed in", "supplied staff token");

  section("Op allowlist");
  const unknown = await callOp("deleteEverything", {}, { expectError: true });
  if (unknown.error && /Unknown Xero operation/.test(unknown.error.message || "")) {
    ok("unknown ops are rejected", "allowlist holds");
  } else {
    bad("an unknown op was NOT rejected", JSON.stringify(unknown).slice(0, 160));
  }

  section("Token store (server-side)");
  const status = await callOp("connectionStatus");
  if (status.connected) {
    ok("connectionStatus", `tenant "${status.tenantName}"`);
  } else {
    bad("proxy reports Xero is not connected");
    process.exit(1);
  }
  // Never leak a token to the client.
  const leaked = ["accessToken", "refreshToken", "previousRefreshToken"]
    .filter((k) => k in status);
  if (leaked.length === 0) ok("no token material returned to the client");
  else bad("proxy LEAKED token fields", leaked.join(", "));

  section("Reads through the proxy");
  const org = (await callOp("getOrganisation")).Organisations[0];
  ok("getOrganisation", `${org.Name} · ${org.CountryCode} · ${org.BaseCurrency}`);

  const accounts = (await callOp("listAccounts")).Accounts || [];
  ok("listAccounts", `${accounts.length} revenue accounts`);
  const revenueOnly = accounts.every((a) => a.Type === "REVENUE");
  if (revenueOnly) ok("listAccounts filtered to REVENUE server-side");
  else bad("listAccounts returned non-revenue accounts");

  const taxRates = (await callOp("listTaxRates")).TaxRates || [];
  ok("listTaxRates", `${taxRates.length} rates`);

  // Payments post to the bank account the money arrived in, never the revenue
  // account the invoice was raised against — Xero rejects the latter.
  const bank = (await callOp("listBankAccounts")).Accounts || [];
  ok("listBankAccounts", `${bank.length} bank accounts`);
  if (bank.every((a) => a.Type === "BANK")) ok("bank list filtered to BANK");
  else bad("listBankAccounts returned non-bank accounts");

  const contacts = await callOp("listContacts", { pageSize: 5, page: 1 });
  ok("listContacts", `${(contacts.Contacts || []).length} on page 1`);
  if (contacts.pagination) {
    ok("pagination block present",
      `page ${contacts.pagination.page}/${contacts.pagination.pageCount}`);
  } else {
    bad("no pagination block — XeroPage.hasMore will always be false");
  }

  const invoices = await callOp("listInvoices", {
    pageSize: 5, page: 1, summaryOnly: true, order: "Date DESC",
  });
  const invList = invoices.Invoices || [];
  ok("listInvoices", `${invList.length} on page 1`);

  // Xero omits the pagination block on summaryOnly reads — confirmed by
  // requesting the same page both ways. XeroPage falls back to a page-size
  // heuristic because of this; if Xero ever starts sending it, the block wins.
  const paged = await callOp("listInvoices", { pageSize: 5, page: 1 });
  if (paged.pagination) {
    ok("invoice pagination present without summaryOnly",
      `pageCount ${paged.pagination.pageCount}`);
    if (!invoices.pagination) {
      ok("summaryOnly omits pagination", "XeroPage heuristic is required");
    } else {
      ok("summaryOnly now returns pagination too", "heuristic is redundant but harmless");
    }
  } else {
    bad("no invoice pagination even without summaryOnly");
  }

  // Status filtering is what the screen's dropdown does.
  const authorised = await callOp("listInvoices", {
    statuses: ["AUTHORISED"], pageSize: 5, summaryOnly: true,
  });
  const wrongStatus = (authorised.Invoices || []).filter((i) => i.Status !== "AUTHORISED");
  if (wrongStatus.length === 0) ok("status filter applied server-side");
  else bad("status filter leaked other statuses", `${wrongStatus.length} rows`);

  // Pick a live invoice deliberately, from the status-filtered read rather than
  // the most-recent page: Xero serves no online invoice for a VOIDED or DELETED
  // one, and the demo org's newest rows are all voided — testing against those
  // reports a bug that is not there.
  const live = (authorised.Invoices || [])[0]
    || invList.find((i) => ["DRAFT", "AUTHORISED", "PAID"].includes(i.Status));
  if (live) {
    console.log(`      (using ${live.InvoiceNumber}, ${live.Status})`);
    const id = live.InvoiceID;
    const full = (await callOp("getInvoice", { invoiceId: id })).Invoices[0];
    ok("getInvoice", `${full.InvoiceNumber}, ${(full.LineItems || []).length} line(s)`);
    if ((full.LineItems || []).length > 0 || Number(full.Total) === 0) {
      ok("detail read returns line items", "summaryOnly rows correctly omit them");
    }

    const pdf = await callOp("getInvoicePdf", { invoiceId: id });
    if (pdf.pdfBase64 && Buffer.from(pdf.pdfBase64, "base64").subarray(0, 4).toString("latin1") === "%PDF") {
      ok("getInvoicePdf", `${pdf.byteLength} bytes, base64 round-trips`);
    } else {
      bad("getInvoicePdf did not return a usable PDF");
    }

    try {
      const online = await callOp("getOnlineInvoiceUrl", { invoiceId: id });
      const url = online.OnlineInvoices?.[0]?.OnlineInvoiceUrl || "";
      if (url) ok("getOnlineInvoiceUrl", url.slice(0, 40) + "…");
      else bad("getOnlineInvoiceUrl returned no URL");
    } catch (e) {
      bad("getOnlineInvoiceUrl", e.message.slice(0, 100));
    }
  }

  section("Error shaping");
  // Xero buries validation detail; the proxy is supposed to surface it.
  const notFound = await callOp("getInvoice",
    { invoiceId: "00000000-0000-0000-0000-000000000000" }, { expectError: true });
  if (notFound.error) {
    ok("a bad invoice id errors cleanly", `${notFound.error.status}: ${(notFound.error.message || "").slice(0, 70)}`);
  } else {
    bad("a bad invoice id did not error");
  }

  const missingArg = await callOp("getInvoice", {}, { expectError: true });
  if (missingArg.error && /required/i.test(missingArg.error.message || "")) {
    ok("missing arguments are rejected before reaching Xero");
  } else {
    bad("missing argument was not validated", JSON.stringify(missingArg).slice(0, 120));
  }

  if (WRITE) {
    section("Writes through the proxy");
    if (!/demo/i.test(org.Name) && org.IsDemoCompany !== true) {
      bad("refusing to write to a non-demo organisation");
    } else {
      const stamp = Date.now();
      const contact = (await callOp("createContact", {
        contact: { Name: `ZZZ Proxy Smoke ${stamp}` },
        idempotencyKey: `proxy-contact-${stamp}`,
      })).Contacts[0];
      ok("createContact", contact.ContactID);

      const accountCode = accounts[0]?.Code;
      const payload = {
        Contact: { ContactID: contact.ContactID },
        Date: new Date().toISOString().slice(0, 10),
        // Required: Xero rejects an AUTHORISED invoice without one
        // ("The document DueDate field must be specified"). The app's create
        // dialog always sends it, so this mirrors what the app does.
        DueDate: new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10),
        Status: "AUTHORISED",
        LineAmountTypes: "Exclusive",
        LineItems: [{
          Description: "Proxy smoke line — safe to void",
          Quantity: 1, UnitAmount: 0.01, AccountCode: accountCode,
        }],
      };
      const inv = (await callOp("createInvoice", {
        invoice: payload, idempotencyKey: `proxy-invoice-${stamp}`,
      })).Invoices[0];
      ok("createInvoice", `${inv.InvoiceNumber} · ${inv.Status}`);

      const replay = (await callOp("createInvoice", {
        invoice: payload, idempotencyKey: `proxy-invoice-${stamp}`,
      })).Invoices[0];
      if (replay.InvoiceID === inv.InvoiceID) {
        ok("Idempotency-Key survives the proxy", "no duplicate raised");
      } else {
        bad("proxy did NOT forward Idempotency-Key", `${inv.InvoiceID} vs ${replay.InvoiceID}`);
      }

      const voided = (await callOp("voidInvoice", { invoiceId: inv.InvoiceID })).Invoices[0];
      if (voided.Status === "VOIDED") ok("voidInvoice", voided.InvoiceNumber);
      else bad("void did not take", voided.Status);
    }
  } else {
    console.log("\n  (read-only — pass --write to exercise create/void through the proxy)");
  }

  console.log(`\n${fail === 0 ? "PASS" : "FAIL"} — ${pass} passed, ${fail} failed\n`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(`\nFailed: ${e.message}\n`);
  process.exit(1);
});
