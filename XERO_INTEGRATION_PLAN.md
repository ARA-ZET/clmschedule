# Xero Integration Plan — Community Life Media invoicing

**Status:** **Connected to the live CLM books**; config + verification outstanding · **Drafted:** 2026-08-19 · **Last worked:** 2026-08-25 · **Target company:** Community Life Media (`companies/clm`)

> **Where this is up to.** Phases 1–5 are done. The proxy is deployed
> (`xeroAccounting`, `xeroTokenHeartbeat`), and the app can raise, amend, share,
> pay and void CLM invoices from both the Job List row action and the Add/Edit
> Job dialog. 331 tests green.
>
> **Cutover is under way.** `~/xero_connect.js` has been run: `secureTokens/xero`
> now points at **Community Life Media (Pty) Ltd · ZAR · ZA**, whose books
> already carry real invoices (INV-943x). Steps 3–7 below remain.
>
> ⚠️ **Do not run the full smoke test any more.** It creates a contact and a
> R0.01 invoice; on the live books that is a real contact and a real gap in the
> invoice sequence. `--safe` only. The three unverified write-path assumptions
> in §8 Phase 1 need a *demo* org and are not worth reconnecting one for — the
> app already exercises all three in normal use.

Community Life Media is the last of the three businesses without in-app invoicing.
Junk & Stuff bills through Zoho Books; Happy Sun is manual; CLM invoices are
raised by hand in Xero today. This plan wires CLM's Job List work through to the
Xero Accounting API with the same feature set the Zoho path already has.

---

## 0. Debug pass — 2026-08-19

Everything up to this point had been verified by talking **straight to Xero**.
The `xeroAccounting` callable — its token store, lock, op allowlist, error
flattening and response shapes — had never been exercised at all, even though it
is the only path the app uses.
[`functions/test/xero_proxy_smoke.js`](functions/test/xero_proxy_smoke.js)
closes that gap. Four real defects came out of it.

### 1. Anyone on the internet could read and write CLM's books · **fixed**

The callable gated on `request.auth` only, matching the deliberate "any
signed-in user" policy inherited from `zohoBooks`. But **anonymous auth is
enabled on this Firebase project**, and the app never calls
`signInAnonymously` — so a token could be minted with one unauthenticated HTTP
call using the public web API key. This was not theoretical: the first version
of the proxy test read the customer list and raised an invoice that way.

`xeroAccounting` now rejects `sign_in_provider == "anonymous"`, which restores
the intended meaning of "signed-in staff". The test asserts the rejection.

> [!WARNING]
> **`zohoBooks` still has this exposure** and was left alone, because the
> memory on that integration says not to tighten it without asking. Junk &
> Stuff's customers and invoices are reachable the same way. Either apply the
> same three-line check, or disable anonymous auth for the project — the app
> does not use it.

### 2. The invoice list silently showed only its first page · **fixed**

`XeroPage.hasMore` trusted Xero's `pagination` block. **Xero omits that block
entirely when `summaryOnly=true`**, which the invoice list always sends —
verified by requesting the same page both ways (`pageCount: 16` versus no block
at all). `hasMore` was therefore permanently false, so "Load more" never
appeared and everything past row 100 was invisible with no error to notice.

`XeroPage` now falls back to a page-size heuristic when the block is absent: a
full page may have more, a short page is the last. A real block still wins.

Also found in the same probe: **Xero ignores `pageSize` unless `page` is sent
too** — it returns the entire set and no pagination block. The service now
supplies `page: 1` whenever a page size is given.

### 3. Voided invoices offered a pay link that 404s · **fixed**

`GET /Invoices/{id}/OnlineInvoice` returns a link for DRAFT, AUTHORISED and
PAID, and HTTP 404 for VOIDED and DELETED. The detail screen offered "Copy pay
link" regardless, so a voided invoice produced *"the resource you're looking for
cannot be found"* — which reads like a broken integration rather than the
expected answer. Gated behind `XeroInvoiceStatus.hasOnlineInvoice`.

### 4. A corrected customer name would have been silently ignored · **fixed**

The contact `Idempotency-Key` was `clm-contact-{jobId}`. If the invoice step
failed and the user reopened the dialog having fixed the customer's name, Xero
would replay the original request and return the contact with the **old** name.
The key now includes the normalised name, so an identical retry still replays
while a genuinely different customer creates a new one.

The invoice key stays keyed on the job alone, deliberately: if a previous
attempt raised an invoice but failed to link it, replaying that invoice is
exactly right, and including the amount would let a corrected figure produce a
duplicate in the books.

### Also confirmed

- **The deployed function was stale** — deployed 10:20Z against a source last
  changed 12:03Z, so the 401-retry fix was not live. Redeployed.
- Xero **requires `DueDate`** on an AUTHORISED invoice; the app always sends one.
- The Job List updates itself after invoicing — `JobListProvider` holds a
  Firestore snapshot listener, so the row flips from "create" to the invoice
  number without a manual refresh.
- Unauthenticated calls, unknown ops and missing arguments are all rejected
  before reaching Xero; no token material is returned to the client.
- `Idempotency-Key` survives the proxy — a repeated create returns the original
  invoice id.

---

## 1. What already exists (and why this is cheaper than it looks)

The groundwork was laid deliberately when companies were introduced.

| Piece | Where | State |
|---|---|---|
| `AccountingProvider` enum incl. `xero` | [company.dart:8-30](lib/models/company.dart#L8-L30) | Built. `isImplemented` currently returns false for `xero` — one line to flip. |
| CLM seeded with `AccountingProvider.xero` | [company.dart](lib/models/company.dart) `Company.seed` | Built. |
| `providerConfig: Map<String,String>` for tenant ids etc. | [company.dart](lib/models/company.dart) | Built, unused. |
| `providerForJobType()` routing | [company_provider.dart:58](lib/providers/company_provider.dart#L58) | Built, **not yet consulted by any invoicing code**. |
| `createsInvoices` per job type | [custom_job_type.dart](lib/models/custom_job_type.dart) | Built. |
| `chargesVat` per job type + `vatSettingsRiverpod` (15%) | [custom_job_type.dart:68](lib/models/custom_job_type.dart#L68), [vat_settings_provider.dart](lib/providers/vat_settings_provider.dart) | Built, dormant — Zoho charges no VAT so nothing consumes it. **Xero will be the first consumer.** |
| `amountExclVat` / `amountInclVat` / `priceIsInclVat` | [job_list_item.dart:113-121](lib/models/job_list_item.dart#L113-L121) | Built, dormant. |
| Credential-proxy pattern | [functions/lib/zoho_books.js](functions/lib/zoho_books.js) | Proven. Xero's proxy is the same shape. |
| Saga (job-first, resumable, idempotent) | [invoice_save_saga.dart](lib/widgets/zoho/invoice_save_saga.dart) | Provider-agnostic in spirit, Zoho-typed in signature. |
| ~5,000 lines of invoicing UI | [lib/widgets/zoho/](lib/widgets/zoho/) | Reusable once the models are neutralised. |

**The gap:** the invoicing UI is gated on `appearsOnCollectionSchedule`
([add_edit_job_dialog.dart:148-156](lib/widgets/add_edit_job_dialog.dart#L148-L156)) —
i.e. "is this Junk & Stuff" — not on the company's accounting provider. CLM jobs
live in the Job List and never see an invoicing section at all.

---

## 2. Decisions taken

| # | Decision | Consequence |
|---|---|---|
| D1 | **Standard OAuth 2.0 app** (not a paid Custom Connection) | Refresh tokens rotate on every use and die after 60 days idle. Needs a persisted, lock-protected mutable token store — §4. This is the single largest piece of new backend work. |
| D2 | **Invoices created `AUTHORISED`** | Live and sendable immediately, matching Zoho's feel — **and still editable while unpaid**, which measurement showed and the original plan got wrong. Costs nothing over DRAFT. §6. |
| D3 | **CLM charges 15% VAT** | First real use of `chargesVat` / `priceIsInclVat`. Maps onto Xero's `LineAmountTypes` + `TaxType` — §5. |
| D4 | **Full parity with the Zoho feature set at launch** | Invoices browser, contacts screen, PDF, share templates, status sync, void-on-cancel — all in scope before shipping. |

---

## 3. Xero API facts this plan is built on

Verified against Xero's current docs and developer blog (Aug 2026).

- **Endpoints.** Token: `https://identity.xero.com/connect/token`. Authorise:
  `https://login.xero.com/identity/connect/authorize`. Tenants:
  `GET https://api.xero.com/connections`. API base:
  `https://api.xero.com/api.xro/2.0`.
- **Every API call needs the `Xero-Tenant-Id` header** plus `Authorization: Bearer`.
  Unlike Zoho there is no `organization_id` query param.
- **Access token: 30 minutes.** Refresh token: 60 days if unused, and it
  **rotates** — using it invalidates it and returns a new one. The old one stays
  usable for a **30-minute grace window**, which is what makes a lost write
  recoverable rather than fatal.
- **Rate limits, per tenant:** 60 calls/minute, 5 concurrent, and — critically —
  **1,000 calls/day for an uncertified app**, not the 5,000 a certified one gets.
  Confirmed against the live headers: a fresh demo org reported
  `X-DayLimit-Remaining: 995` after five calls. This app is private and
  uncertified, so **1,000/day is the real budget** and the design has to fit
  inside it (§9). Responses carry `X-DayLimit-Remaining` /
  `X-MinLimit-Remaining`; breaching gives HTTP 429 with a `Retry-After`.
- **Invoice create (`POST /Invoices`)** requires `Type: "ACCREC"`, a `Contact`
  (ContactID or Name) and ≥1 line item. Each line item requires `Description`,
  `UnitAmount` and `AccountCode`. `TaxType` is optional and overrides the
  account's default.
- **Status transitions available to the API:** `DRAFT→SUBMITTED|AUTHORISED|DELETED`,
  `SUBMITTED→DRAFT|AUTHORISED|DELETED`, `AUTHORISED→VOIDED`. There is **no
  API path back from AUTHORISED to DRAFT**, and voiding is refused once a
  payment or credit note is allocated.
- **Updating an invoice replaces the whole line-item array.** Lines you omit are
  deleted. Supplying `LineItemID` preserves a line's identity — the same trap as
  Zoho's `line_item_id`.
- **`LineAmountTypes`**: `Exclusive` | `Inclusive` | `NoTax`. Defaults to
  Exclusive for invoices when omitted.
- **`Idempotency-Key` header** (≤128 chars, UUID) is honoured on POST/PUT —
  retrying with the same key returns the original result instead of duplicating.
- **Paging:** `page` + `pageSize` (default 100, max 1000). Filtering via `where`
  / `order` / `Statuses` / `ContactIDs`, and `searchTerm` on Contacts.
- **PDF:** same GET as the JSON read with `Accept: application/pdf`.
  **Online invoice link:** `GET /Invoices/{id}/OnlineInvoice` → `OnlineInvoiceUrl`.
- **Xero assigns `InvoiceNumber` itself** unless you supply one.

---

## 4. Backend: the `xeroAccounting` callable

New file **`functions/lib/xero_accounting.js`**, exported from
[functions/index.js](functions/index.js) alongside `zohoBooks`. Same philosophy:
a fixed allowlist of named ops, never a generic relay, credentials never in the
web bundle.

### 4.1 Secrets

```
firebase functions:secrets:set XERO_CLIENT_ID
firebase functions:secrets:set XERO_CLIENT_SECRET
```

Only two — the refresh token cannot be a secret because it changes on every use.

### 4.2 Token store — the crux of D1

Rotating tokens live in Firestore at **`secureTokens/xero`** — a collection
that is **deliberately absent from `firestore.rules`**:

```jsonc
{
  "refreshToken": "…",      // rotates every refresh
  "accessToken":  "…",      // shared across function instances
  "expiresAt":    1755600000000,
  "tenantId":     "…",      // the CLM Xero organisation
  "refreshLock":  null,      // instance id holding the lock
  "lockExpiresAt": 0,
  "lastRefreshAt": 1755600000000,
  "previousRefreshToken": "…" // kept for the 30-min grace retry
}
```

> [!WARNING]
> **Do not put this document under `settings/`.** `firestore.rules` grants every
> signed-in user read/write on `settings/{document=**}`
> ([firestore.rules:166](firestore.rules#L166)), which would publish CLM's Xero
> refresh token to every account in the app.
>
> And a deny rule would **not** fix it: Firestore evaluates all matching rules
> and grants access if *any* `allow` matches, so
> `match /settings/xeroAuth { allow read, write: if false; }` is simply ignored
> in the presence of the wildcard — rule order is irrelevant. Narrowing the
> wildcard instead (`allow ... if signedIn() && docId != 'xeroAuth'`) would work
> but means unpicking a recursive `{document=**}` match that other settings docs
> rely on.
>
> The clean answer is the one this ruleset already provides: **an unlisted
> collection.** `firestore.rules` ends with an explicit fail-closed comment, so
> `secureTokens/xero` is unreachable from any client by default. Cloud Functions
> use the Admin SDK and bypass rules entirely.
>
> **The only rules work required is negative: never add `secureTokens` to
> `firestore.rules`.** Leave a comment at the fail-closed marker saying so, or
> someone will "helpfully" add it during a later sweep.

**Refresh algorithm** (`getAccessToken()`):

1. Module-scope cache hit and >5 min of life left → use it. (Same warm-instance
   trick as `zoho_books.js`.)
2. Otherwise read `secureTokens/xero`. If its `accessToken` is still valid,
   adopt it into module scope and use it — a second instance shouldn't refresh
   just because it cold-started.
3. Otherwise acquire `refreshLock` in a Firestore transaction (with a ~30 s
   `lockExpiresAt` so a crashed instance can't wedge the integration).
   Lock contended → short backoff, re-read, and the winner's new token is used.
4. POST `grant_type=refresh_token` with HTTP Basic `client_id:client_secret`.
5. **Persist the new refresh token before returning the access token.** If the
   write fails, the old token is still inside its 30-minute grace window, so
   log loudly and retry rather than swallow it.
6. Move the consumed token to `previousRefreshToken`; fall back to it on
   `invalid_grant` once, then give up with a clear "reconnect Xero" error.

**Heartbeat.** A refresh token unused for 60 days is dead and needs a human at a
browser. Add a scheduled function **`xeroTokenHeartbeat`** (daily) that just
calls `getAccessToken()`. Cheap, and it turns a silent 60-day cliff into a
daily canary.

### 4.3 First-time consent

A one-off local script **`~/xero_connect.js`** (kept **outside the repo**, same
as `~/zoho_refresh_token.sh`): spins a localhost redirect, opens the consent
URL, exchanges the code, calls `GET /connections` for the tenant id, and writes
the initial `settings/xeroAuth` document via the Admin SDK.

Scopes: `offline_access accounting.invoices accounting.payments
accounting.contacts accounting.settings.read`.

> [!IMPORTANT]
> **Use the granular scopes.** Xero replaced the broad `accounting.transactions`
> scope on **2 March 2026**, splitting it into `accounting.invoices`,
> `accounting.payments`, `accounting.banktransactions` and
> `accounting.manualjournals`. Apps created on or after that date **cannot
> request the old scope** — the consent screen fails with `invalid_scope`
> (HTTP 500) before it ever reaches the redirect, so the callback server sees
> nothing and there is no error to catch locally. `accounting.contacts` and
> `accounting.settings` were not part of the split.
>
> Existing pre-March-2026 apps keep the broad scope until **13 September 2027**;
> this one is new, so it was granular from the start.

If reconnecting turns out to be routine rather than once-a-year, promote this to
a pair of HTTP functions (`xeroConnect` / `xeroCallback`) with an admin-only
button in the app. Not v1.

### 4.4 Request plumbing

Mirrors `zohoRequest()` but with Xero's differences:

- `Xero-Tenant-Id` header on every call; `Accept: application/json`.
- Retry once on 401 with a forced refresh (a token can be revoked early).
- **429 handling:** read `Retry-After`, surface as `resource-exhausted` with the
  wait in the details so the client can say "Xero is rate-limiting, try in Ns"
  rather than a bare failure.
- Success is HTTP 2xx — Xero does **not** use Zoho's `"code": 0` convention.
  Errors come back as `{ Type, Message, Elements[].ValidationErrors[] }`;
  flatten `ValidationErrors` into the message or the UI will show a useless
  "A validation exception occurred".
- Pass `Idempotency-Key` through from the client on every POST.
- `unitdp=4` on money endpoints to avoid 2-decimal rounding surprises.

### 4.5 Operation allowlist

| Op | Method + path | Notes |
|---|---|---|
| `listContacts` | `GET /Contacts` | `searchTerm`, `page`, `pageSize`, `where`, `order` |
| `getContact` | `GET /Contacts/{id}` | |
| `createContact` | `POST /Contacts` | |
| `updateContact` | `POST /Contacts/{id}` | Xero uses POST, not PUT, for updates |
| `listInvoices` | `GET /Invoices` | `Statuses`, `ContactIDs`, `where`, `order`, `page`, `pageSize`, `searchTerm` |
| `getInvoice` | `GET /Invoices/{id}` | |
| `getInvoicePdf` | `GET /Invoices/{id}` + `Accept: application/pdf` | base64 back, as `zohoPdf` does |
| `getOnlineInvoiceUrl` | `GET /Invoices/{id}/OnlineInvoice` | the customer-facing pay link |
| `createInvoice` | `POST /Invoices` | `Type: ACCREC`, status per D2 |
| `updateInvoice` | `POST /Invoices/{id}` | guarded — §6 |
| `voidInvoice` | `POST /Invoices/{id}` `{Status:"VOIDED"}` | |
| `emailInvoice` | `POST /Invoices/{id}/Email` | Xero sends it with the org's own template |
| `createPayment` | `POST /Payments` | needs an `Account` (bank) code |
| `listAccounts` | `GET /Accounts?where=Type=="REVENUE"` | for the sales-account picker |
| `listTaxRates` | `GET /TaxRates` | for the VAT picker |
| `listBrandingThemes` | `GET /BrandingThemes` | optional, controls the PDF template |

Auth gate: `request.auth` only, matching the deliberate open-access decision
made for `zohoBooks`. Do not tighten one without the other.

---

## 5. VAT mapping (D3)

Xero's model lines up with the app's dormant fields almost exactly:

| App | Xero |
|---|---|
| `priceIsInclVat == true` | `LineAmountTypes: "Inclusive"` |
| `priceIsInclVat == false` | `LineAmountTypes: "Exclusive"` |
| job type `chargesVat == false` | `LineAmountTypes: "NoTax"` |
| `amountExclVat` / `amountInclVat` | `UnitAmount` (whichever matches the type above) |
| VAT rate (15%, `vatSettingsRiverpod`) | **not sent** — Xero owns the rate via `TaxType` |

**Do not hardcode the tax type or the account code.** Both are
organisation-specific and South Africa uses Xero's Global edition vocabulary.
Instead:

1. `listTaxRates` / `listAccounts` feed dropdowns in the
   [company management dialog](lib/widgets/company_management_dialog.dart),
   shown only when the provider is Xero.
2. The choice is stored in `Company.providerConfig` — the free-form map that
   exists for exactly this:
   ```
   tenantId, salesAccountCode, salesTaxType, brandingThemeId, currencyCode
   ```
3. Optional later: per-job-type account-code override, so distribution and
   printing land in different revenue accounts.

**Reconciliation check.** Xero computes tax per line and rounds; the app's
`amount` may differ by cents. After creating an invoice, compare Xero's `Total`
against the job's expected total and surface a warning if they diverge. Silent
divergence between the Job List and the books is the failure mode worth
engineering against.

---

## 6. Editing an invoice (D2) — simpler than first planned

> **Corrected 2026-08-19 by measurement.** This section originally specced a
> void-and-reissue flow, on the strength of secondary sources saying Xero
> "only allows updates to draft invoices". **That is wrong.** The smoke test
> amended the line items of an AUTHORISED invoice, and the change took effect
> and survived a re-read (`SubTotal 0.01 → 99`). The old design is gone; what
> follows is what the API actually does.

Creating at `AUTHORISED` turns out to cost nothing. The invoice is live and
sendable immediately, **and** it can still be amended — so the Zoho path's
"edit the job → amend the invoice" behaviour carries over unchanged, and the
two providers behave alike in the same Job List.

The edit flow is a two-way branch:

1. **Invoice unpaid** (`AmountDue == Total`, no credit notes) → **amend in
   place**, line items included. Send the full `LineItems` array via
   `XeroInvoice.toUpdateJson()`, each line carrying its `LineItemID`.
2. **Invoice paid or part-paid** → Xero rejects the amendment, and rejects a
   void too. Block the edit and say why. A credit note is the correct
   instrument and is **out of scope for v1**.

Two API rules still bite and are already enforced in the model:

- **The `LineItems` array replaces the existing one.** Any line omitted is
  deleted. Confirmed by measurement: sending one line without a `LineItemID`
  left the invoice with exactly one line and a newly-assigned id — the original
  was dropped, not merged.
- **A line without its `LineItemID` loses its identity.** It is deleted and
  recreated rather than amended, so `toUpdateJson()` always carries the id.

### What this changes elsewhere in the plan

- **No `supersededInvoiceIds` chain is needed.** Dropped from §7.
- **No void-and-reissue confirmation dialog.** Voiding stays in the app, but
  only for its real purpose: cancelling a job.
- **The concern raised when D2 was chosen is void.** Ordinary edits no longer
  leave voided numbers in CLM's books, because ordinary edits no longer void
  anything. AUTHORISED is now strictly better than DRAFT here — live invoices,
  full editability, no extra approval step.

`Idempotency-Key` still applies to every create, derived deterministically from
the job id. Verified against the live API: posting the same invoice twice with
one key returned the same `InvoiceID` rather than duplicating — retry safety the
Zoho path never had.

---

## 7. Data model: one seam, not two parallel stacks

`JobListItem` carries five Zoho-specific fields
([job_list_item.dart:149-170](lib/models/job_list_item.dart#L149-L170)). Adding
five parallel `xero*` fields would work, but every call site then becomes
`hasZohoInvoice || hasXeroInvoice` forever.

Instead, follow the precedent this repo already set with
`CustomJobType.resolvedCompanyId` — **neutral fields with a legacy fallback**:

```dart
// New, written by both providers from here on.
final String invoiceProviderId;    // 'zoho' | 'xero'
final String accountingContactId;
final String accountingInvoiceId;
final String accountingInvoiceNumber;
final String accountingInvoiceStatus;  // provider wire value
final DateTime? accountingSyncedAt;

// Reads fall back so historical Zoho records keep rendering unchanged.
String get resolvedInvoiceId =>
    accountingInvoiceId.isNotEmpty ? accountingInvoiceId : zohoInvoiceId;
```

The `zoho*` fields stay on the model and keep being written by the Zoho path
until a later backfill retires them. No migration is required to ship Xero.

Also needed:
- `AccountingProvider.isImplemented` → include `xero`.
- A neutral `InvoiceStatus` enum with `fromZoho` / `fromXero` constructors, so
  `zoho_status_chip.dart` and the status-mapping settings work for both.
- `ZohoSyncSettingsProvider` generalises to per-provider status maps
  (`settings/invoiceSync` keyed by provider), since Xero's vocabulary
  (`DRAFT/SUBMITTED/AUTHORISED/PAID/VOIDED/DELETED`) differs from Zoho's.

---

## 8. Phased delivery

### Phase 0 — Xero account setup *(no code)*
1. Create the OAuth 2.0 app in the Xero developer portal against the CLM
   organisation. Redirect URI `http://localhost:8080/callback` for the consent
   script.
2. **Connect to Xero's Demo Company first**, not the live CLM books. Every
   phase below is developed and tested against the demo org; switching to live
   is a tenant-id change in `secureTokens/xero`.
3. Note the CLM chart of accounts: which revenue account distribution income
   codes to, and which tax rate is the 15% output VAT.

### Phase 1 — Backend proxy

**Written:**
- [x] [`functions/lib/xero_accounting.js`](functions/lib/xero_accounting.js) —
      token store with lock + grace-window fallback, request plumbing, error
      flattening, the op allowlist, and `xeroTokenHeartbeat`.
- [x] Exported from [`functions/index.js`](functions/index.js) alongside `zohoBooks`.
- [x] [`firestore.rules`](firestore.rules) — a `DO NOT ADD secureTokens` note at
      the fail-closed marker. No rule was added; that is the point.
- [x] `~/xero_connect.js` — one-off consent, outside the repo. Reads the client
      id/secret from Secret Manager (not typed), runs the auth-code flow on
      `localhost:8080`, lists the connected organisations, and refuses to write
      a non-demo tenant without typing `LIVE`.
- [x] [`functions/test/xero_smoke.js`](functions/test/xero_smoke.js) — the
      Phase 1 verification run.

**Verified against Xero's Demo Company (Global) on 2026-08-19 — `PASS, 15 passed, 0 failed`:**
token rotation, org read, revenue accounts, tax rates, contact paging and
create, invoice create as AUTHORISED, idempotent replay, **line-item amendment
in place**, soft-field update, PDF render, online invoice URL, and void.

All three assumptions were tested. Two held; **one did not** — see §6.

**Remaining before go-live:**
1. `firebase functions:secrets:set XERO_CLIENT_ID` / `XERO_CLIENT_SECRET`.
2. `firebase deploy --only functions:xeroAccounting,functions:xeroTokenHeartbeat`
3. `node ~/xero_connect.js` → populates `secureTokens/xero`.
4. `node functions/test/xero_smoke.js` → must print PASS.
5. Confirm from a signed-in client that `secureTokens/xero` reads are **denied**.
6. Record the printed `salesAccountCode` and `salesTaxType`, which go into
   `companies/clm.providerConfig` in Phase 3.

> [!NOTE]
> **Demo Company values are not CLM's values.** Xero's demo org is "Demo Company
> (Global)" — USD, country code CA, with Canadian tax rates (`OUTPUT` at 8.25%,
> `TAX001` at 8.75%) and no 15% rate at all. The revenue accounts happen to be
> Xero's standard chart (`200 Sales`, `260 Other Revenue`, `270 Interest
> Income`), which the live CLM org very likely shares — but **`salesTaxType`
> must be re-harvested against the real organisation** before go-live. Run
> `node functions/test/xero_smoke.js --safe` once pointed at the live tenant to
> read the South African rates.

The smoke test does more than exercise CRUD; it checks three assumptions this
plan is built on, and prints a warning if any turns out to be wrong:

- `Idempotency-Key` replays the original invoice instead of duplicating it
  (the saga's retry safety depends on it);
- line-item edits on an AUTHORISED invoice are **rejected** — **this one was
  wrong**, and the test caught it: they are accepted, take effect, and persist.
  §6 was rewritten around the measurement;
- soft-field edits on an AUTHORISED invoice **are** accepted (branch 1 of §6).

*Exit criterion: full CRUD against the Xero demo company from the deployed
callable, and a refresh that survives being raced.*

### Phase 2 — Dart models + service ✅

- [x] [`lib/models/xero_contact.dart`](lib/models/xero_contact.dart)
- [x] [`lib/models/xero_invoice.dart`](lib/models/xero_invoice.dart) —
      `XeroInvoice`, `XeroLineItem`, `XeroInvoiceStatus`, `XeroLineAmountType`
- [x] [`lib/models/xero_org.dart`](lib/models/xero_org.dart) — `XeroAccount`,
      `XeroTaxRate`, `XeroOrganisation`, `XeroConnectionStatus`
- [x] [`lib/services/xero_accounting_service.dart`](lib/services/xero_accounting_service.dart)
- [x] [`test/xero_models_test.dart`](test/xero_models_test.dart) — 31 tests, green

Four Xero behaviours are pinned by tests because they are where this will
silently go wrong:

- **Dates come in two formats in the same response.** `/Date(1552262400000+0000)/`
  on `Date` / `DueDate` / `UpdatedDateUTC`, ISO on the parallel `DateString` /
  `DueDateString`. Handling only one yields null dates on half the payloads.
- **There is no `OVERDUE` status.** Overdue is `AUTHORISED` + past due date +
  `AmountDue > 0`, computed in `XeroInvoice.isOverdue`. Anything switching on
  status alone will never show it — a real difference from Zoho, which has an
  explicit overdue state.
- **`toSoftUpdateJson()` must carry no line items**, since sending them to an
  AUTHORISED invoice is rejected. That is branch 1 of §6, enforced by the model
  rather than left to the caller.
- **Phones are a typed array**, not fields — the same shape of trap as Zoho's
  `contact_persons`. Reads flatten `DEFAULT`/`MOBILE`; writes rebuild it.

One Xero constraint has no equivalent in the Zoho path and needs handling in
Phase 4: **contact names must be unique across the organisation.** The CLM seed
name is "client, area", which collides the second time the same client is billed
for the same area. `XeroException.isDuplicateName` detects it; the create flow
must offer to reuse the existing contact rather than failing the save.

*Exit criterion met: green tests, no UI, nothing existing modified.*

### Phase 3 — The seam (part-built)

- [x] **Neutral `JobListItem` fields with Zoho fallback** —
      `invoiceProviderId`, `accountingContactId`, `accountingInvoiceId`,
      `accountingInvoiceNumber`, `accountingInvoiceStatus`,
      `accountingSyncedAt`, read through `resolved*` getters. Wired through
      `fromMap`, `toMap`, `copyWith` **and `withPreservedSystemFields`** — that
      last one is not optional: `moveJobListItemToMonth` recreates the document
      from `toMap()` and deletes the original, so a field missed there is
      destroyed the first time a job's date moves to another month, not merely
      stale. Covered by [test/xero_seam_test.dart](test/xero_seam_test.dart).
- [x] **`AccountingProvider.isImplemented` includes `xero`.** The guard in
      `company_ownership_test.dart` that asserted the opposite was updated
      rather than deleted — its point (never offer a provider with no code
      behind it) still stands.
- [x] **Xero config UI** —
      [`lib/widgets/xero/xero_company_config.dart`](lib/widgets/xero/xero_company_config.dart),
      shown in the company management dialog when the provider is Xero. Reads
      accounts and tax rates live from the connected tenant; writes
      `salesAccountCode` / `salesTaxType` into `providerConfig`. Handles the
      not-connected case, and flags a saved value that does not exist on the
      currently connected organisation — which is exactly what switching from
      the demo company to the live books produces.
- [x] Route invoicing off `providerForJobType()` instead of
      `appearsOnCollectionSchedule`. **The switch that makes CLM jobs
      invoiceable at all**, and the riskiest edit in the integration: it is the
      line the live Zoho path also runs through.

      The rule was pulled out of the dialog into
      `AccountingProvider.forJobType()` so it could be tested without a
      Firestore-backed provider, and it keeps the legacy flag as a **fallback**
      rather than replacing it — a company document with no provider recorded
      still resolves a collection-schedule type to Zoho, so a misconfiguration
      cannot make Junk & Stuff's jobs uninvoiceable. `createsInvoices: false` is
      checked first and is absolute. Guarded by five tests in
      [test/company_ownership_test.dart](test/company_ownership_test.dart), the
      first of which exists only to assert Junk & Stuff is unchanged.
- [x] **`InvoiceSaveSaga` generalised** to `InvoiceSaveSaga<C, I>`, with
      `providerName` and two label functions supplied by the caller. Zoho and
      Xero now share one copy of the ordering, retry and idempotency rules
      rather than two that would drift. Driven with Xero's types in
      [test/xero_invoicing_test.dart](test/xero_invoicing_test.dart) — compiling
      against both types proves nothing; those prove it still refuses to
      double-create.

*Exit criterion: a CLM job shows an invoicing section; a Junk & Stuff job still
behaves exactly as before. Full suite green at every step — 251 tests as of the
config UI landing.*

### Phase 4 — Invoicing flow (CLM can invoice; dialog integration pending)

- [x] [`XeroContactPicker`](lib/widgets/xero/xero_contact_picker.dart) —
      searches server-side through `searchTerm` rather than loading the whole
      book. Create-vs-reuse keys on `existsInXero`, never on "is the value
      non-null".
- [x] [`CreateXeroInvoiceDialog`](lib/widgets/xero/create_xero_invoice_dialog.dart)
      — raises an AUTHORISED invoice for an existing Job List item, through the
      generalised saga, with idempotency keys derived from the job id so a
      retried save cannot bill twice.
- [x] `JobListService.linkAccountingInvoiceTxn` — the provider-neutral link.
      **Its VAT handling is the real difference** from `linkZohoInvoiceTxn`,
      which writes `amount == exclVat == inclVat` because Junk & Stuff charges
      none. CLM does, so the split is taken from the invoice itself — Xero
      computed it, rounding included — rather than recomputed locally where it
      could disagree by cents. Needs `accountingInvoiceLinks` in
      `firestore.rules` (added).
- [x] Row action in the Job List, shown only for job types whose company
      invoices through Xero, and replaced by the invoice number and status once
      one exists so a job cannot quietly acquire two.

**Deliberate ordering change.** The plan had the gate flip
(`providerForJobType()` in `add_edit_job_dialog.dart`) as the way to turn CLM
invoicing on. Doing it that way would have shown the invoicing section — wired
to Zoho's picker and Zoho's saga — on jobs that bill through Xero, which is
worse than showing nothing. Invoicing from the Job List row was built first
instead: it delivers CLM invoicing without touching a 3,000-line shared dialog.

**Done since:** "Add Job + Invoice" in one step from `AddEditJobDialog`, and
invoice editing (amend in place per §6, via `XeroEditInvoiceDialog` off the
detail screen).

The dialog now dispatches on the job type's provider: `_buildInvoicingSection()`
and `_saveJobWithInvoice()` each branch to a Zoho or Xero implementation, and
`_sagaActive` covers both sagas so an invoiced Xero job cannot be written twice
by "Skip Allocation". **Both button layouts call the same dispatcher**, which is
what keeps the mobile/desktop trap below from reopening. The VAT toggle does
something real here for the first time — `XeroLineAmountType.forJob()` reads the
job type's `chargesVat` and the job's `priceIsInclVat`, where the Zoho path
writes one figure three times.

#### Original Phase 4 checklist
1. Contact picker + create form for Xero (generalise
   `customer_picker_field.dart` / `customer_form_dialog.dart`).
2. Line-items editor over the neutral model, with the VAT toggle live for the
   first time.
3. Create → AUTHORISED, with `Idempotency-Key`, through the saga.
4. Edit → the two-way branch of §6: amend in place while unpaid, block with an
   explanation once paid.
5. Total reconciliation warning (§5).

> [!CAUTION]
> **`AddEditJobDialog` has two separate button layouts** — a `Column` for
> mobile (<768px) and a `Wrap` for desktop — and they must be kept in sync.
> Wiring only one of them is exactly the bug that cost a full debugging round
> on the Zoho integration: the desktop button silently called the non-invoicing
> save path. Change both, and verify in a desktop-width browser, not just the
> mobile layout.

> [!NOTE]
> Apps-menu screens sit under `_bodyNavKey`. `showDialog` defaults to the root
> navigator, so `Navigator.pop(context)` inside a dialog pops the *page*
> instead of the dialog. Use the dialog's own context.

### Phase 5 — Parity surface (D4)
1. [x] [`XeroAccountingScreen`](lib/widgets/xero/xero_accounting_screen.dart) —
   one destination with **Invoices** and **Customers** as tabs, rather than two
   screens behind a menu. They are two views of the same ledger and moving
   between them is common, so a back-and-push round trip was friction.
2. [x] [`XeroInvoicesView`](lib/widgets/xero/xero_invoices_view.dart) —
   server-side paging (`page`/`pageSize`), status filtering, `order` sorting,
   `summaryOnly`. Xero's sort/filter grammar differs from Zoho's; the table
   widget generalised, the query builder did not.
3. [x] [`XeroInvoiceDetailScreen`](lib/widgets/xero/xero_invoice_detail_screen.dart)
   — line items, the VAT split, and the actions Xero actually permits: print,
   download the Xero-rendered PDF, copy/open the customer pay link, email from
   Xero, and void. **Void is hidden rather than offered and then rejected** —
   Xero only permits it from AUTHORISED with no payment allocated. The list
   fetches with `summaryOnly` (no line items), so this always re-reads rather
   than trusting the row.
4. [x] [`XeroContactDetailScreen`](lib/widgets/xero/xero_contact_detail_screen.dart)
   — contact details plus their invoices. Re-reads the contact because
   `Balances.AccountsReceivable.Outstanding` only appears on a detail fetch,
   never on a list row.
5. [x] [`XeroCustomersView`](lib/widgets/xero/xero_customers_view.dart) —
   pages server-side and searches through `searchTerm`, rather than loading the
   whole book the way the Zoho screen does. On 1,000 calls/day that matters.

   Both are body-only views with no Scaffold, kept alive by
   `AutomaticKeepAliveClientMixin`. Flutter builds a `TabBarView` child only
   when first shown, so **opening the screen costs one API call, not two**, and
   switching tabs afterwards costs none.

   Both reuse `zoho_table.dart`'s chrome (`ZohoTable`, `ZohoPalette`,
   `ZohoToolbar`, `ZohoSearchField`, `ZohoFilterDropdown`), which is generic
   despite the name. **Renaming those to something provider-neutral is a
   pending tidy-up** — reusing a `ZohoTable` inside a Xero screen reads oddly,
   but duplicating ~540 lines would read worse.

#### UI pass — 2026-08-25

**Both providers now have the same shape.** Zoho's two Collection Schedule
menu items became one `ZohoBooksScreen` with Invoices | Customers tabs, mirroring
`XeroAccountingScreen` exactly; `ZohoInvoicesScreen`/`ZohoCustomersScreen` are
now body-only `…View` widgets with `AutomaticKeepAliveClientMixin`, so switching
tabs costs no refetch. Files renamed to `zoho_*_view.dart` to match.

**Gaps closed on the Xero side:** a date-range filter (`XeroDateRange`), the
share-message-templates button, and the shared `ZohoAsyncBody` for
loading/empty/error instead of hand-rolled states. Xero has no date parameter,
so the range is expressed as a `where` clause using its own `DateTime(y,m,d)`
literal — same feature as Zoho's `date_start`/`date_end`, entirely different
grammar. Empty states now name which filter is responsible rather than saying
"No invoices", which reads as "Xero is empty".

**Two real defects found in the shared chrome:**

- **Row hover never worked.** `ZohoTable` set a `hoverColor` on the row's
  `InkWell`, but the child was a `Container` with an opaque background. An
  InkWell's highlight is painted by the Material *behind* its child, so the
  background hid it completely. Fixed by painting the row with `Ink`, which
  puts the decoration on the Material itself. Rows also get a pointer cursor
  now — they are links to a detail screen.
- **Nothing marked a column as sortable** until it was already sorted, since
  the arrow rendered only on the active column. Sortable headers now show a
  faint arrow on hover.

> [!NOTE]
> **Zoho's customer list still loads all 826 contacts up front**, where Xero
> pages server-side. Deliberately left alone: six call sites — including
> `CustomerPickerField` on the live invoicing path and the invoice detail
> screen's `getById` email lookup — depend on that list being complete in
> memory, and would silently fail for any contact off the loaded page. Xero
> pages because of the 1,000-call daily cap; Zoho's limits are far more
> generous, so this would trade a working live path for very little.

   `XeroStatusChip` is separate rather than shared, because Xero has no
   OVERDUE status: the chip takes the derived `isOverdue` and overrides the
   label, otherwise a red-flag invoice renders as an unremarkable "Awaiting
   payment".
7. [x] **PDF download + share, and message templates.** `invoice_share.dart`
   and `InvoiceMessageTemplate` both keyed off `ZohoInvoice`; they now render
   [`InvoiceMessageSubject`](lib/models/invoice_message_subject.dart), a
   provider-neutral flattening with `fromZoho` / `fromXero` factories. One set
   of templates therefore serves both businesses — the wording you send a
   customer does not depend on which ledger raised the invoice.

   Two traps are pinned by tests:

   - **Paid is derived differently per provider.** The Zoho flattening keeps
     Zoho's original "a zero balance means settled" rule. Xero's keys on the
     status alone, because a Xero DRAFT also reports `AmountDue: 0` and reusing
     Zoho's rule would file every draft under the *paid* templates.
   - **The pay link is injected, not read.** Zoho carries `invoice_url` on the
     invoice; Xero's `OnlineInvoiceUrl` needs its own API call, so the Xero
     detail screen resolves it *before* opening the share sheet — templates
     render `{pay_link}` at build time, so a lazily-fetched link would be
     missing from the message actually sent, not merely from the preview.

   New token: `{pay_link}`. The settings dialog picks it up automatically,
   since its chips iterate `InvoiceMessageToken.values`.

5. [x] **Batched status sync + void-on-cancel parity.**

   [`XeroInvoiceStatusSync`](lib/services/xero_invoice_status_sync.dart)
   refreshes every Xero status on screen in **one** `GET /Invoices` call, using
   the comma-separated `InvoiceNumbers=` filter. This is a budget problem
   before it is a correctness one: 200 invoiced jobs fetched individually is a
   fifth of the daily 1,000-call allowance spent drawing one screen.

   The decision logic is pure and static so it can be tested without a network
   or a clock — [test/xero_status_sync_test.dart](test/xero_status_sync_test.dart),
   11 tests, every one of them about *not* asking Xero for something:

   - Zoho rows share the Job List and are excluded; so are jobs with no invoice
     number, and VOIDED/DELETED invoices, which cannot change again. **PAID is
     not treated as terminal** — deleting the payment in Xero reverts it to
     AUTHORISED and the Job List must be able to follow that.
   - Statuses younger than 10 minutes are taken at face value, which is what
     makes the `accountingSyncedAt` cache load-bearing rather than a nicety.
   - An in-memory `_nextEligible` throttles the *next* call even when a run
     changed nothing or failed, so calling `refresh()` from `build` is safe.
     A failure backs off for one minute rather than the full window.
   - Only genuine changes are written, batched through
     `JobListService.updateAccountingInvoiceStatuses` — a per-row write would
     hand back the saving the batched read just made. An invoice Xero did not
     report is left alone rather than blanked: a number missing from the
     response is far likelier to be an invoice in another organisation than one
     that has ceased to exist.

   **Void-on-cancel parity.** `confirmDeleteJobAndInvoice`,
   `voidInvoiceForJob` and `maybeVoidInvoiceForJob` were Zoho-only, so deleting
   or cancelling a CLM job silently left a live Xero invoice behind. All three
   now load through one neutral `_InvoiceSummary` and route the void by the
   job's own provider. Xero's rule is stricter and is stated rather than
   attempted: a void is offered only from AUTHORISED with nothing allocated.
   The delete flow also drops the `accountingInvoiceLinks` entry, matching what
   it already did for `zohoInvoiceLinks`.
6. [x] Nav entries. **One business, one home screen.** Junk & Stuff invoices
   through Zoho and is reached from the Collection Schedule
   ([collection_schedule_grid.dart:291](lib/widgets/collection_schedule_grid.dart#L291));
   CLM invoices through Xero and is reached from the Job List toolbar, via a
   button next to the month picker that opens the tabbed screen. Offering both in both places would make it
   easy to raise an invoice against the wrong company's books, so neither menu
   lists the other provider.

   The Job List's non-functional fullscreen button was removed to make room —
   `TogglerProvider` never tracked a joblist fullview state, so
   `toggleFullview(Mode.joblist)` fell through both branches and did nothing.
   `MonthNavigationWidget` gained a `trailingActions` slot for the menu;
   fullscreen is now gated to the Schedule and Collection Schedule, which do
   read the state.

### Phase 6 — Cutover *(outstanding — this is all that is left)*

Verified still on the demo org as of 2026-08-25:
`node functions/test/xero_smoke.js --safe` → *tenant "Demo Company (Global)"
· USD · CA · no 15% output rate*.

Step 1 is interactive — it opens a browser for Xero's consent screen — so it
cannot be scripted and has to be run by hand.

1. [x] **Connect the live organisation.** Done — `secureTokens/xero` points at
   *Community Life Media (Pty) Ltd · ZAR · ZA*.
2. [x] **Re-harvest the org-specific config.** Done via
   `node functions/test/xero_smoke.js --safe`:

   | Field | Value |
   |---|---|
   | `salesAccountCode` | **`200`** — Sales |
   | `salesTaxType` | **`OUTPUT3`** — Standard Rate Sales, 15% |

   > [!CAUTION]
   > **The smoke test recommended the wrong rate here, and it was fixed.** It
   > took "the first 15% rate", which on a real ZA organisation is
   > `ACC28PLUS` — *"Accommodation exceeding 28 days"*. Xero seeds ZA orgs with
   > **six** rates at 15%: two accommodation rates, change-in-use, export of
   > second-hand goods, capital goods, and the one actually wanted. Coding
   > distribution income to any of the others gets the *percentage* right and
   > the **VAT201 line wrong** — an accounting error that would not show up
   > anywhere in the app.
   >
   > The recommendation now prefers **the sales account's own default tax
   > type**, which is authoritative because it is what Xero itself applies to a
   > line posted to that account (account `200 Sales` defaults to `OUTPUT3`).
   > It falls back to an exact "Standard Rate Sales" name match, and only then
   > to the first 15% rate — printing a loud warning to confirm with the
   > bookkeeper if it ever gets that far.
3. **Write the config** into `companies/clm.providerConfig` through
   Settings → Companies (the Xero config UI reads the accounts and tax rates
   live from the connected tenant and flags a saved value that does not exist
   on it — which is exactly what switching from demo to live produces).
4. **Set `createsInvoices` per CLM job type.** Still an open question below:
   internal work such as returning flyers must not offer an invoice, and
   `createsInvoices` defaults to true.
5. **Deploy.** `firebase deploy --only functions:xeroAccounting,functions:xeroTokenHeartbeat`
   then `./deploy_web.sh` (ships `firestore:rules` + `hosting:main`).
6. **Confirm the token is unreachable** from a signed-in client — a read of
   `secureTokens/xero` must be denied.
7. **Raise one real invoice**, check it against Xero's web UI (particularly the
   VAT split), and void it.
8. Update `MEMORY.md` with a `project_xero_integration.md` entry — the same
   treatment the Zoho integration got.

> [!WARNING]
> **The whole integration is still uncommitted.** Every Xero file is untracked
> or modified on `dev`. Commit before deploying, or a rollback has nothing to
> roll back to.

---

## 9. Risks and open items

| Risk | Mitigation |
|---|---|
| **Refresh-token rotation loses the token** and locks the integration out | Lock + persist-before-return + the 30-min grace fallback (§4.2). Worst case is a re-run of `~/xero_connect.js`. |
| **`settings/**` is readable by every signed-in user**, and Firestore deny rules cannot override an existing `allow` | Keep the token in the unlisted `secureTokens` collection, which fails closed. Verified as Phase 1 step 1, before the first token write. |
| **60-day idle expiry** | `xeroTokenHeartbeat` daily. |
| **1,000 calls/day** (uncertified app), 60/min | The tightest constraint in the whole integration — see the sizing note below. Never bulk-sync contacts the way the Zoho path loads all 826; page server-side with `searchTerm`. Refresh invoice statuses in **one batched call**, never per job. If it still proves tight, a paid Custom Connection lifts the ceiling. |
| ~~Void & reissue leaves gaps in CLM's invoice numbering~~ | **No longer applies** — measurement showed unpaid AUTHORISED invoices amend in place, so ordinary edits void nothing. |
| **Paid invoices can be neither amended nor voided** | Blocked with an explanation in v1; credit notes are a follow-up. |
| **VAT rounding divergence** between Job List and Xero | Post-create total comparison with a visible warning (§5). |
| **Breaking the working Zoho path** during the Phase 3 seam | Phase 3 exit criterion is an explicit Junk & Stuff regression pass. The `zoho*` fields are not removed, only supplemented. |
| Xero's `where` grammar is unlike Zoho's params | Query building stays provider-specific; only the table widget is shared. |

### Living inside 1,000 calls/day

This is tighter than it sounds and it constrains Phase 5 in particular.

- **Never refresh status per job.** A Job List of 200 CLM jobs, each fetching
  its own invoice, is 200 calls — a fifth of the day's budget for one screen.
  Use a single `GET /Invoices` with `InvoiceNumbers=` or `ContactIDs=` and
  `pageSize` up to 1000: **one call refreshes every status on screen**.
- The `accountingInvoiceStatus` / `accountingSyncedAt` cache on `JobListItem`
  (§7) therefore stops being a nicety and becomes load-bearing. Treat a status
  older than some interval as stale rather than re-reading on every build.
- `summaryOnly=true` on list calls drops line items, which is what keeps a
  1000-row page inside the response limit.
- The daily heartbeat costs 2 calls. Irrelevant, but worth knowing it is there.
- Rough budget for a normal day: ~50 invoices raised (≈150 calls including
  contact lookups and status confirmations), a handful of invoice-screen page
  loads, and periodic batched status refreshes. Comfortable — but only because
  nothing loops per row.

### Open questions
- Which CLM job types actually raise invoices? (`createsInvoices` needs setting
  per type — "returning flyers" is internal work, per the existing comment in
  `custom_job_type.dart`.)
- Should Xero *send* the invoice email (`POST /Invoices/{id}/Email`, uses Xero's
  own template), or does CLM keep sharing via WhatsApp as Junk & Stuff does?
- ~~Does CLM want a Xero **Item catalogue** for standard services?~~
  **Answered: yes, built 2026-08-25.** `GET /Items` (filtered `IsSold==true`)
  added to the proxy allowlist, `XeroItem` model, and `xeroItemsRiverpod` which
  loads the catalogue **once per session** — it is consulted from a settings
  dropdown, from every invoice line, and again on each job type change, so a
  fetch per consultation would be a fast route through the daily budget.

  `CustomJobType.accountingItemCode` binds a job type to an item; changing the
  job type on Add Job re-seeds the invoice line from it, **but only while that
  line is still the auto-seeded one** — someone who has edited the description
  or added rows has said more about the invoice than the job type has.

  Two Xero shapes worth knowing: price, account and tax rate live under nested
  `SalesDetails` (absent entirely on purchase-only items), and `Description` is
  the *sales* description while `PurchaseDescription` is an internal buying
  note that must never reach a customer's invoice. Both pinned by tests.
- Credit notes — needed soon, or genuinely deferrable?

---

## 10. Rough sizing

| Phase | Scope |
|---|---|
| 0 — Xero setup | Config only, no code |
| 1 — Backend proxy | ~450 lines JS + rules change + consent script. **The token store is the hard part.** |
| 2 — Models + service | ~600 lines Dart, mostly mirroring existing files |
| 3 — The seam | Small in lines, **highest regression risk** — it touches the live Zoho path |
| 4 — Invoicing flow | Moderate; mostly generalising existing widgets |
| 5 — Parity surface | Largest by volume, lowest risk — screens over a proven service |
| 6 — Cutover | Config + verification |

---

## References

- [Xero Accounting API](https://developer.xero.com/documentation/api/accounting/overview)
- [Invoices endpoint](https://developer.xero.com/documentation/api/accounting/invoices)
- [OAuth 2.0 flow](https://developer.xero.com/documentation/guides/oauth2/auth-flow/)
- [Token management best practices](https://devblog.xero.com/xero-api-token-management-best-practices-and-troubleshooting-01853f4244a9)
- [Rate limits](https://developer.xero.com/documentation/best-practices/api-call-efficiencies/rate-limits)
- [Tax and the Xero API](https://developer.xero.com/documentation/guides/how-to-guides/tax-in-xero)
- [Paging: 100 → 1000](https://devblog.xero.com/conquer-data-overload-mastering-paging-in-the-xero-api-03ceacfeb184)
- [Ultimate guide to invoicing with the Xero API](https://devblog.xero.com/introducing-the-ultimate-guide-to-invoicing-with-the-xero-api-378aac9c3094)
