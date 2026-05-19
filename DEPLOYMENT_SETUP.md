# CLM Schedule Web Deployment Setup

## Overview

When you deploy a new web app version, the system automatically notifies users via an "Update Available" dialog. Users can then click "Refresh Now" to load the new version.

For this feature to work, you need:

1. ✅ Firebase Hosting (already set up)
2. ✅ Firestore database (already set up)
3. ❌ **Firebase service account credentials** (needs setup)

## The Error You're Getting

```
✗ Error updating version: 2 UNKNOWN: Getting metadata from plugin failed with error: invalid_grant
```

This means the deployment script can't authenticate with Firebase to update the version. The fix is simple - you just need to set up the service account credentials.

## Step 1: Get Your Service Account Key

1. Go to Firebase Console: https://console.firebase.google.com/project/clmschedule/settings/serviceaccounts/adminsdk
2. Click **"Generate New Private Key"**
3. A JSON file will be downloaded (e.g., `clmschedule-XXXXX.json`)
4. **Important**: Keep this file private - don't commit it to git!

## Step 2: Set Up the Credentials

### Option A: System-Wide Setup (Recommended)

```bash
# 1. Create the credentials directory
mkdir -p ~/.firebase

# 2. Move your downloaded key to this directory
# (Replace the filename with your actual downloaded file)
mv ~/Downloads/clmschedule-XXXXX.json ~/.firebase/clmschedule-key.json

# 3. Set the environment variable (add to your shell config)
# For macOS (zsh), add this line to ~/.zshrc:
export GOOGLE_APPLICATION_CREDENTIALS=~/.firebase/clmschedule-key.json

# 4. Load the updated config
source ~/.zshrc

# 5. Verify it's set
echo $GOOGLE_APPLICATION_CREDENTIALS
# Should output: /Users/Bunny/.firebase/clmschedule-key.json
```

### Option B: Per-Session Setup

If you prefer not to add it permanently, run this before each deployment:

```bash
export GOOGLE_APPLICATION_CREDENTIALS=~/.firebase/clmschedule-key.json
./deploy_web.sh
```

### Option C: Alternative - Direct Path in Script

Edit `deploy_web.sh` and add before the Node.js call:

```bash
# Add after line that checks for credentials
export GOOGLE_APPLICATION_CREDENTIALS=~/.firebase/clmschedule-key.json
```

## Step 3: Verify Setup

Test that everything works:

```bash
# Check the credentials file exists
ls -la ~/.firebase/clmschedule-key.json

# Check environment variable is set
echo $GOOGLE_APPLICATION_CREDENTIALS

# Quick test - run the version update script
node tools/update_firestore_version.js 2.04.23
```

Expected output:

```
✅ Successfully updated version in Firestore
📱 All users will be notified of version 2.04.23
```

## Step 4: Deploy Your App

Now your deployment should work end-to-end:

```bash
./deploy_web.sh
```

Complete output should show:

```
Step 3: Updating version in Firestore...
✓ Version updated in Firestore
  Users will see update notification dialog

=== Deployment Complete ===
📱 Users using old version will see: 'Update Available' dialog
   They can click 'Refresh Now' to load the new version
```

## What Happens After Deployment

### For Users:

1. Users have the app open in their browser
2. A dialog appears: **"Update Available"** with:
   - Current version they're running
   - New version available
   - "Refresh Now" button (required) or "Later" button (optional)
3. Clicking "Refresh Now" reloads the page with the new version

### For You:

- Check Firestore: `appConfig` collection → `version` document
- You should see:
  ```json
  {
    "version": "2.04.23",
    "forceUpdate": true,
    "lastUpdated": <current timestamp>
  }
  ```

## Security Notes

⚠️ **Important**:

- **Never** commit the service account key to git!
- **Never** share the key file publicly
- The key is stored in `~/.firebase/` (your home directory) for personal use
- If you need team deployments, consider using GitHub Actions with encrypted secrets

## Troubleshooting

### Problem: "GOOGLE_APPLICATION_CREDENTIALS not found"

```bash
# Solution:
export GOOGLE_APPLICATION_CREDENTIALS=~/.firebase/clmschedule-key.json
./deploy_web.sh
```

### Problem: "Invalid credentials" error

- Delete `~/.firebase/clmschedule-key.json`
- Download a fresh key from Firebase Console
- Try again

### Problem: Permission denied on key file

```bash
# Fix permissions
chmod 600 ~/.firebase/clmschedule-key.json
```

### Problem: Still getting "invalid_grant"

1. Verify the key file is valid JSON:

   ```bash
   cat ~/.firebase/clmschedule-key.json | head -20
   ```

2. Check the environment variable is set:

   ```bash
   echo $GOOGLE_APPLICATION_CREDENTIALS
   ```

3. Try generating a new key from Firebase Console

## Next Steps

After you complete the setup:

1. Run `./deploy_web.sh` to deploy your app
2. Check Firebase Console to verify version was updated
3. Open your app in two browser tabs - you should see the update dialog on both

## Manual Update (If Script Fails)

If the script still fails, you can manually update the version:

1. Go to Firebase Console: https://console.firebase.google.com/project/clmschedule/firestore
2. Go to Collection: `appConfig` → Document: `version`
3. Click **Edit** and update:
   ```
   version: "2.04.23"
   forceUpdate: true
   ```
4. Click **Save**

Users will see the update notification on their next page load.

---

**Questions?** Check `lib/services/app_version_service.dart` and `lib/widgets/app_update_dialog.dart` for implementation details.
