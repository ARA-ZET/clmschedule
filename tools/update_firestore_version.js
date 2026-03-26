#!/usr/bin/env node

/**
 * Update app version in Firestore after deployment.
 * Replaces the Dart version that fails due to objective_c build hook issues.
 *
 * Usage: node tools/update_firestore_version.js <version>
 */

const path = require("path");
const admin = require(path.join(__dirname, "..", "functions", "node_modules", "firebase-admin"));

const version = process.argv[2];
if (!version) {
  console.error("Usage: node tools/update_firestore_version.js <version>");
  console.error("Example: node tools/update_firestore_version.js 2.02.10");
  process.exit(1);
}

// Initialize with application default credentials (same project)
admin.initializeApp({ projectId: "clmschedule" });

const db = admin.firestore();

async function main() {
  console.log(`Updating version to: ${version}`);
  try {
    await db.collection("appConfig").doc("version").set(
      {
        version: version,
        forceUpdate: true,
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    console.log("✓ Successfully updated version in Firestore");
    console.log(
      `All users will be prompted to reload to get version ${version}`
    );
    process.exit(0);
  } catch (e) {
    console.error(`✗ Error updating version: ${e.message}`);
    process.exit(1);
  }
}

main();
