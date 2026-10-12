#!/usr/bin/env node

/**
 * Update app version in Firestore after deployment.
 *
 * Usage: node tools/update_firestore_version.js <version>
 * Example: node tools/update_firestore_version.js 2.02.10
 *
 * Authentication methods (tried in order):
 * 1. GOOGLE_APPLICATION_CREDENTIALS env var → service account key file
 * 2. FIREBASE_CREDENTIALS env var → service account key file
 * 3. ~/.firebase/clmschedule-key.json → well-known service account key
 * 4. gcloud user token (REST API), trying in order: $CLM_GCLOUD_ACCOUNT,
 *    richardatclm@gmail.com (the account with access to the clmschedule
 *    project), then gcloud's active account. The active account is often a
 *    personal one with no access, which is why it is tried last.
 */

const path = require("path");
const fs = require("fs");
const { execSync, spawnSync } = require("child_process");

const PROJECT_ID = "clmschedule";
const DEFAULT_GCLOUD_ACCOUNT = "richardatclm@gmail.com";

const version = process.argv[2];
if (!version) {
  console.error("Usage: node tools/update_firestore_version.js <version>");
  console.error("Example: node tools/update_firestore_version.js 2.02.10");
  process.exit(1);
}

// ── Helper: Firestore REST PATCH (merge) via curl ────────────────────────────
function firestorePatchRest(accessToken) {
  const docPath = `projects/${PROJECT_ID}/databases/(default)/documents/appConfig/version`;
  const url = `https://firestore.googleapis.com/v1/${docPath}` +
    `?updateMask.fieldPaths=version&updateMask.fieldPaths=forceUpdate&updateMask.fieldPaths=lastUpdated`;

  const body = JSON.stringify({
    fields: {
      version:     { stringValue: version },
      forceUpdate: { booleanValue: true },
      lastUpdated: { timestampValue: new Date().toISOString() },
    },
  });

  // Write body to a temp file to avoid shell quoting issues with the token
  const tmpFile = `/tmp/fs_version_payload_${process.pid}.json`;
  const outFile = `/tmp/fs_version_response_${process.pid}.json`;
  fs.writeFileSync(tmpFile, body, "utf8");
  try {
    // No -f: it hides the HTTP status. macOS curl over HTTP/2 even reports a
    // 403 as "exit code 56" (a network error). HTTP/1.1 plus an explicit
    // status code gives a readable failure instead.
    const result = spawnSync(
      "curl",
      [
        "-s", "--http1.1",
        "-o", outFile,
        "-w", "%{http_code}",
        "-X", "PATCH", url,
        "-H", `Authorization: Bearer ${accessToken}`,
        "-H", "Content-Type: application/json",
        "-d", `@${tmpFile}`,
      ],
      { encoding: "utf8", timeout: 15000 }
    );
    if (result.status !== 0) {
      const detail = result.stderr || `curl exit code ${result.status}`;
      throw new Error(`network error: ${detail.trim()}`);
    }
    const status = parseInt(result.stdout, 10);
    if (status < 200 || status >= 300) {
      let message = "";
      try {
        message = JSON.parse(fs.readFileSync(outFile, "utf8")).error.message;
      } catch (_) {}
      const err = new Error(`HTTP ${status}${message ? ` — ${message}` : ""}`);
      err.httpStatus = status;
      throw err;
    }
  } finally {
    try { fs.unlinkSync(tmpFile); } catch (_) {}
    try { fs.unlinkSync(outFile); } catch (_) {}
  }
}

// ── Helper: get gcloud access token ──────────────────────────────────────────
// [account] null means gcloud's active account.
function getGcloudToken(account) {
  try {
    const cmd = account
      ? `gcloud auth print-access-token ${account} 2>/dev/null`
      : "gcloud auth print-access-token 2>/dev/null";
    const token = execSync(cmd, { encoding: "utf8" }).trim();
    if (token && token.length > 20) return token;
  } catch (_) {
    // gcloud not installed or not logged in
  }
  return null;
}

// ── Admin SDK path ─────────────────────────────────────────────────────────
const adminPath = path.join(__dirname, "..", "functions", "node_modules", "firebase-admin");

async function tryAdminSdk(credInit) {
  const admin = require(adminPath);
  // Each require() returns the same module instance; re-init would throw if
  // already initialised, so we use a fresh app each time.
  const appName = `update-version-${Date.now()}`;
  const app = admin.initializeApp(credInit, appName);
  try {
    const db = admin.firestore(app);
    await db.collection("appConfig").doc("version").set(
      {
        version,
        forceUpdate: true,
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  } finally {
    await app.delete();
  }
}

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  console.log(`📦 Updating app version to: ${version}`);
  console.log(`🎯 Target: appConfig/version in Firestore\n`);

  const wellKnownKey = path.join(
    process.env.HOME || "~",
    ".firebase",
    "clmschedule-key.json"
  );

  const serviceAccountPath =
    (process.env.GOOGLE_APPLICATION_CREDENTIALS &&
      fs.existsSync(process.env.GOOGLE_APPLICATION_CREDENTIALS) &&
      process.env.GOOGLE_APPLICATION_CREDENTIALS) ||
    (process.env.FIREBASE_CREDENTIALS &&
      fs.existsSync(process.env.FIREBASE_CREDENTIALS) &&
      process.env.FIREBASE_CREDENTIALS) ||
    (fs.existsSync(wellKnownKey) && wellKnownKey) ||
    null;

  // ── Strategy 1: service account key via Admin SDK ──
  if (serviceAccountPath) {
    try {
      console.log(`Using service account key: ${serviceAccountPath}`);
      const serviceAccount = require(serviceAccountPath);
      const admin = require(adminPath);
      await tryAdminSdk({
        projectId: PROJECT_ID,
        credential: admin.credential.cert(serviceAccount),
      });
      console.log("✅ Successfully updated version in Firestore");
      console.log(`📱 All users will be notified of version ${version}`);
      console.log("🔄 Users can click 'Refresh Now' to load the new version");
      process.exit(0);
    } catch (e) {
      console.warn(`⚠️  Service account key failed: ${e.message}`);
      console.warn("   Falling back to gcloud user token...\n");
    }
  }

  // ── Strategy 2: gcloud user token via REST API ──
  const accounts = [
    ...new Set([process.env.CLM_GCLOUD_ACCOUNT, DEFAULT_GCLOUD_ACCOUNT].filter(Boolean)),
    null, // gcloud's active account
  ];
  let triedAny = false;
  let lastError = null;
  for (const account of accounts) {
    const label = account || "active gcloud account";
    const token = getGcloudToken(account);
    if (!token) continue;
    triedAny = true;
    console.log(`Using gcloud user token (REST API): ${label}`);
    try {
      firestorePatchRest(token);
      console.log("✅ Successfully updated version in Firestore");
      console.log(`📱 All users will be notified of version ${version}`);
      console.log("🔄 Users can click 'Refresh Now' to load the new version");
      process.exit(0);
    } catch (e) {
      lastError = e;
      console.warn(`⚠️  ${label}: ${e.message}`);
      // Only a permissions problem is worth retrying with another account.
      if (e.httpStatus !== 401 && e.httpStatus !== 403) break;
    }
  }

  if (!triedAny) {
    console.error("❌ No valid credentials found.");
    console.error("\n📋 Fix options (choose one):");
    console.error(`  A) Run:  gcloud auth login ${DEFAULT_GCLOUD_ACCOUNT}`);
    console.error("  B) Download a service account key:");
    console.error("     https://console.firebase.google.com/project/clmschedule/settings/serviceaccounts/adminsdk");
    console.error("     Save as: ~/.firebase/clmschedule-key.json");
    process.exit(1);
  }

  console.error(`❌ Error updating version: ${lastError && lastError.message}`);
  console.error("\nDebugging tips:");
  console.error(`- Log in with an account that has access: gcloud auth login ${DEFAULT_GCLOUD_ACCOUNT}`);
  console.error("- Or pick one explicitly: CLM_GCLOUD_ACCOUNT=you@example.com ./deploy_web.sh");
  console.error("- Check Firebase Console: appConfig/version");
  process.exit(1);
}

main();
