// Simple script to update version in Firestore
// Run with: node update_version.js 2.01.07

const admin = require('firebase-admin');

// Initialize with your service account or let it use default credentials
admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'clmschedule'
});

const db = admin.firestore();
const version = process.argv[2] || '2.01.07';

db.collection('appConfig').doc('version').set({
  version: version,
  forceUpdate: true,
  lastUpdated: admin.firestore.FieldValue.serverTimestamp()
}, { merge: true })
.then(() => {
  console.log('✓ Version updated to:', version);
  process.exit(0);
})
.catch((error) => {
  console.error('Error updating version:', error);
  process.exit(1);
});
