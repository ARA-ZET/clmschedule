#!/usr/bin/env node
/**
 * List — and optionally revoke — the Xero organisations this app is connected to.
 *
 * A Xero OAuth app can be authorised against several organisations at once. The
 * proxy only ever talks to the one recorded in `secureTokens/xero.tenantId`, so
 * the others are not reachable from the app — but leaving them connected means
 * a future re-consent can silently land on the wrong books, which is exactly
 * how the demo company stayed connected for weeks.
 *
 * Usage:
 *   node functions/test/xero_connections.js              # list only (safe)
 *   node functions/test/xero_connections.js --prune      # revoke every org except the stored tenant
 *   node functions/test/xero_connections.js --revoke ID  # revoke one connection by its id
 *
 * Revoking a connection removes this app's access to that organisation. It
 * changes nothing inside the organisation itself — no invoices, contacts or
 * settings are touched — and it can be re-granted by running the consent flow
 * again.
 *
 * REFUSES to revoke the organisation currently recorded in secureTokens/xero,
 * whatever you pass: that is the one the app actually uses.
 */

const { execFileSync } = require("child_process");

const PROJECT = "clmschedule";
const TOKEN_DOC = "secureTokens/xero";
const CONNECTIONS_URL = "https://api.xero.com/connections";

const args = process.argv.slice(2);
const PRUNE = args.includes("--prune");
const REVOKE_INDEX = args.indexOf("--revoke");
const REVOKE_ID = REVOKE_INDEX === -1 ? null : args[REVOKE_INDEX + 1];

function gcloudToken() {
  return execFileSync("gcloud", ["auth", "print-access-token"], {
    encoding: "utf8",
  }).trim();
}

function fromFirestoreFields(fields = {}) {
  const out = {};
  for (const [k, v] of Object.entries(fields)) {
    out[k] = v.stringValue ?? v.integerValue ?? v.nullValue ?? null;
  }
  return out;
}

async function readTokenDoc() {
  const url =
    `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/${TOKEN_DOC}`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${gcloudToken()}` },
  });
  if (res.status === 404) {
    throw new Error(`${TOKEN_DOC} does not exist. Run: node ~/xero_connect.js`);
  }
  if (!res.ok) {
    throw new Error(`Firestore read failed (HTTP ${res.status}): ${await res.text()}`);
  }
  return fromFirestoreFields((await res.json()).fields);
}

function readSecret(name) {
  try {
    return execFileSync(
      "firebase",
      ["functions:secrets:access", name, "--project", PROJECT],
      { encoding: "utf8" },
    ).trim().replace(/[\r\n]/g, "");
  } catch {
    return "";
  }
}

/**
 * A fresh access token.
 *
 * Deliberately does NOT rotate the stored refresh token: this is a read-mostly
 * management script, and burning the app's refresh token from here would be a
 * surprising side effect. Uses the stored access token when it is still valid.
 */
async function accessToken(stored) {
  const notExpired = stored.expiresAt && Date.now() < Number(stored.expiresAt) - 60_000;
  if (notExpired && stored.accessToken) return stored.accessToken;

  const id = readSecret("XERO_CLIENT_ID");
  const secret = readSecret("XERO_CLIENT_SECRET");
  if (!id || !secret) {
    throw new Error(
      "Could not read XERO_CLIENT_ID / XERO_CLIENT_SECRET from Secret Manager, " +
      "and the stored access token has expired.",
    );
  }

  const basic = Buffer.from(`${id}:${secret}`).toString("base64");
  const res = await fetch("https://identity.xero.com/connect/token", {
    method: "POST",
    headers: {
      Authorization: `Basic ${basic}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: stored.refreshToken,
    }),
  });
  const json = await res.json().catch(() => null);
  if (!res.ok || !json?.access_token) {
    throw new Error(`Token refresh failed: ${json?.error || `HTTP ${res.status}`}`);
  }

  console.log(
    "  ! the stored access token had expired, so this run rotated the refresh\n" +
    "    token. The deployed function keeps working — it reads the same doc —\n" +
    "    but note that a rotation happened.",
  );

  // Persist, or the deployed function is left holding a consumed token.
  const expiresAt = Date.now() + (Number(json.expires_in) || 1800) * 1000;
  const url =
    `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/${TOKEN_DOC}` +
    "?updateMask.fieldPaths=accessToken&updateMask.fieldPaths=refreshToken" +
    "&updateMask.fieldPaths=previousRefreshToken&updateMask.fieldPaths=expiresAt";
  await fetch(url, {
    method: "PATCH",
    headers: {
      Authorization: `Bearer ${gcloudToken()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      fields: {
        accessToken: { stringValue: json.access_token },
        refreshToken: { stringValue: json.refresh_token },
        previousRefreshToken: { stringValue: stored.refreshToken },
        expiresAt: { integerValue: String(expiresAt) },
      },
    }),
  });

  return json.access_token;
}

async function main() {
  const stored = await readTokenDoc();
  const token = await accessToken(stored);

  const res = await fetch(CONNECTIONS_URL, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
  });
  if (!res.ok) {
    throw new Error(`GET /connections failed (HTTP ${res.status}): ${await res.text()}`);
  }
  const connections = await res.json();

  console.log("\n=== Xero connections ===\n");
  console.log(`Stored tenant: ${stored.tenantName || "(unnamed)"}  ${stored.tenantId}\n`);

  for (const c of connections) {
    const active = c.tenantId === stored.tenantId;
    console.log(
      `  ${active ? "*" : " "} ${c.tenantName}  (${c.tenantType})` +
      `\n      tenantId=${c.tenantId}` +
      `\n      connectionId=${c.id}${active ? "   <- IN USE by the app" : ""}\n`,
    );
  }

  const others = connections.filter((c) => c.tenantId !== stored.tenantId);
  if (others.length === 0) {
    console.log("Only the organisation in use is connected. Nothing to remove.\n");
    return;
  }

  if (!PRUNE && !REVOKE_ID) {
    console.log(
      `${others.length} other organisation(s) are connected.\n` +
      "Re-run with --prune to revoke them, or --revoke <connectionId> for one.\n",
    );
    return;
  }

  const targets = PRUNE
    ? others
    : connections.filter((c) => c.id === REVOKE_ID);

  if (targets.length === 0) {
    console.log(`No connection matched id ${REVOKE_ID}.\n`);
    return;
  }

  for (const c of targets) {
    // Belt and braces: --revoke could name the live one by hand.
    if (c.tenantId === stored.tenantId) {
      console.log(`  REFUSED ${c.tenantName} — this is the organisation the app uses.`);
      continue;
    }

    const del = await fetch(`${CONNECTIONS_URL}/${c.id}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${token}` },
    });
    console.log(
      del.ok || del.status === 204
        ? `  revoked ${c.tenantName}`
        : `  FAILED  ${c.tenantName} (HTTP ${del.status}) ${await del.text()}`,
    );
  }
  console.log();
}

main().catch((e) => {
  console.error(`\n${e.message}\n`);
  process.exit(1);
});
