# App Version Management System

This system provides real-time version updates for the CLM Schedule app using Firestore. When you publish a new version, all connected users will automatically be notified and prompted to refresh.

## Architecture

### Components

1. **AppVersion Model** (`/lib/models/app_version.dart`)
   - Stores version information: version number, update date/time, message, force update flag

2. **AppVersionService** (`/lib/services/app_version_service.dart`)
   - Manages Firestore operations for version data
   - Collection: `app_config`, Document: `current_version`

3. **AppVersionProvider** (`/lib/providers/app_version_provider.dart`)
   - Provides real-time version monitoring via Firestore streams
   - Compares current version with Firestore version
   - Notifies listeners when update is available

4. **AppUpdateDialog** (`/lib/widgets/app_update_dialog.dart`)
   - User-facing dialog that shows update information
   - Displays current vs new version, update message, timestamp
   - "Refresh Now" button reloads the app
   - Can force update (prevent dismissal)

5. **Update Tool** (`/tools/update_app_version.dart`)
   - Command-line tool to publish new versions to Firestore

## Firestore Structure

```
app_config (collection)
└── current_version (document)
    ├── version: "1.2.3"
    ├── lastUpdated: Timestamp
    ├── updateMessage: "Bug fixes and improvements"
    └── forceUpdate: false
```

## How It Works

1. **On App Startup**:
   - AppVersionProvider initializes with current app version (from VersionService)
   - Starts listening to Firestore `app_config/current_version` document
   - Compares Firestore version with local version

2. **When Version Changes**:
   - Firestore stream detects change and notifies AppVersionProvider
   - Provider sets `needsUpdate = true` if versions differ
   - Main app listener shows AppUpdateDialog to user

3. **User Actions**:
   - **"Refresh Now"**: Reloads the web page (`window.location.reload()`)
   - **"Later"**: Dismisses dialog (only if `forceUpdate = false`)
   - **Force Update**: Dialog cannot be dismissed until user refreshes

## Publishing a New Version

### Step 1: Update the Version in Code

Update the version in your `VersionService`:

```dart
// lib/services/version_service.dart
final String currentVersion = '1.2.3'; // Update this
```

### Step 2: Deploy Your App

Build and deploy your app as usual:

```bash
flutter build web
# Deploy to your hosting (Firebase Hosting, etc.)
```

### Step 3: Update Firestore Version

Use the command-line tool to notify users:

```bash
# Normal update (users can dismiss dialog)
dart run tools/update_app_version.dart 1.2.3 "Bug fixes and improvements"

# Force update (users must refresh)
dart run tools/update_app_version.dart 2.0.0 "Critical security update" --force
```

### Step 4: Monitor Users

All connected users will immediately see the update dialog. They can either:

- Refresh now (gets new version)
- Click "Later" if force update is disabled
- Be forced to refresh if force update is enabled

## Usage Examples

### Regular Feature Update

```bash
dart run tools/update_app_version.dart 1.3.0 "Added new inventory features and improved performance"
```

Result:

- Users see dialog with update message
- Can dismiss and continue using old version
- Will be prompted again on next app load

### Critical Bug Fix

```bash
dart run tools/update_app_version.dart 1.2.4 "Fixed critical data sync issue" --force
```

Result:

- Users see dialog with update message
- Cannot dismiss dialog
- Must click "Refresh Now" to continue using app

### Major Version Release

```bash
dart run tools/update_app_version.dart 2.0.0 "Major update: New UI, improved scheduling, offline support" --force
```

Result:

- Force update ensures all users get breaking changes
- Update message explains major changes
- Users must refresh to continue

## Testing

### Test Version Update Flow

1. **Start the app** with current version (e.g., 1.0.0)

2. **Open Firestore Console**:
   - Go to `app_config/current_version`
   - Manually change the version to 1.0.1
   - Set `updateMessage` to "Test update"
   - Set `forceUpdate` to false or true

3. **Observe behavior**:
   - App should immediately show update dialog
   - Dialog should show version comparison
   - Test "Refresh Now" and "Later" buttons

### Test Force Update

1. Set `forceUpdate: true` in Firestore
2. Try to dismiss dialog (should not work)
3. Click "Refresh Now" (page should reload)

## Troubleshooting

### Dialog Not Showing

**Problem**: Version changed in Firestore but no dialog appears

**Solutions**:

1. Check browser console for errors
2. Verify Firestore rules allow read access to `app_config`
3. Ensure AppVersionProvider is properly initialized
4. Check that `needsUpdate` property is true in provider

### Version Not Detected

**Problem**: Provider shows `needsUpdate = false` even though versions differ

**Solutions**:

1. Verify `VersionService.currentVersion` matches your actual app version
2. Check Firestore document has correct version format (string)
3. Ensure provider's `initialize()` was called with current version

### Refresh Not Working

**Problem**: Clicking "Refresh Now" doesn't reload page

**Solutions**:

1. Check browser console for JavaScript errors
2. Verify `dart:html` import is present (web only)
3. Ensure `_refreshApp()` method is being called
4. Test `window.location.reload()` in browser console

## Firestore Security Rules

Add these rules to allow all users to read version info:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Allow all users to read app version
    match /app_config/current_version {
      allow read: if true;
      allow write: if request.auth != null &&
                    get(/databases/$(database)/documents/users/$(request.auth.uid)).data.isAdmin == true;
    }
  }
}
```

This allows:

- ✅ All users (even unauthenticated) can read version
- ✅ Only admin users can update version
- ✅ Version updates via tool require admin authentication

## Best Practices

1. **Version Numbering**: Use semantic versioning (MAJOR.MINOR.PATCH)
   - MAJOR: Breaking changes
   - MINOR: New features (backwards compatible)
   - PATCH: Bug fixes

2. **Force Updates**: Use sparingly
   - Security fixes: YES
   - Critical bugs: YES
   - New features: NO
   - UI improvements: NO

3. **Update Messages**: Be clear and concise
   - Good: "Fixed data sync issue and improved performance"
   - Bad: "Various improvements"

4. **Timing**: Update during off-peak hours
   - Check user activity patterns
   - Avoid updates during critical business hours
   - Consider time zones

5. **Testing**: Always test in development first
   - Use separate Firestore project for testing
   - Test force update behavior
   - Verify refresh works correctly

## Future Enhancements

Potential improvements to consider:

1. **Version History**: Store all past versions in Firestore
2. **Staged Rollouts**: Release to percentage of users
3. **User Acknowledgment**: Track which users have updated
4. **Auto-refresh**: Automatically refresh after countdown
5. **Platform-Specific Versions**: Different versions for web/mobile
6. **Release Notes**: Show detailed changelog in dialog
7. **Update Scheduling**: Schedule updates for specific times
