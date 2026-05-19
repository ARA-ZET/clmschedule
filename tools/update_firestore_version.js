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
 * 4. gcloud auth print-access-token → active gcloud user login (REST API)
 */

const path = require("path");
const fs = require("fs");
const { execSync, spawnSync } = require("child_process");

const PROJECT_ID = "clmschedule";

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
  fs.writeFileSync(tmpFile, body, "utf8");
  try {
    const result = spawnSync(
      "curl",
      [
        "-s", "-f",
        "-X", "PATCH", url,
        "-H", `Authorization: Bearer ${accessToken}`,
        "-H", "Content-Type: application/json",
        "-d", `@${tmpFile}`,
      ],
      { encoding: "utf8", timeout: 15000 }
    );
    if (result.status !== 0) {
      const detail = result.stderr || result.stdout || `exit code ${result.status}`;
      throw new Error(detail.trim());
    }
  } finally {
    try { fs.unlinkSync(tmpFile); } catch (_) {}
  }
}

// ── Helper: get gcloud access token ──────────────────────────────────────────
function getGcloudToken() {
  try {
    const token = execSync("gcloud auth print-access-token 2>/dev/null", {
      encoding: "utf8",
    }).trim();
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
  console.log("Using gcloud user token (REST API)...");
  const token = getGcloudToken();
  if (!token) {
    console.error("❌ No valid credentials found.");
    console.error("\n📋 Fix options (choose one):");
    console.error("  A) Run:  gcloud auth login");
    console.error("  B) Download a service account key:");
    console.error("     https://console.firebase.google.com/project/clmschedule/settings/serviceaccounts/adminsdk");
    console.error("     Save as: ~/.firebase/clmschedule-key.json");
    process.exit(1);
  }

  try {
    firestorePatchRest(token);
    console.log("✅ Successfully updated version in Firestore");
    console.log(`📱 All users will be notified of version ${version}`);
    console.log("🔄 Users can click 'Refresh Now' to load the new version");
    process.exit(0);
  } catch (e) {
    console.error(`❌ Error updating version: ${e.message}`);
    console.error("\nDebugging tips:");
    console.error("- Ensure you are logged in: gcloud auth login");
    console.error("- Verify the account has Firestore write permissions");
    console.error("- Check Firebase Console: appConfig/version");
    process.exit(1);
  }
}

main();
