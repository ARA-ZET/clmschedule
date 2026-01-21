# Quick Start: Version Management System

## Overview

Your app now has a real-time version management system that automatically notifies users when updates are available.

## For Administrators: Publishing Updates

### 1. Update Your App Code

Make your changes and update the version in `pubspec.yaml`:

```yaml
version: 1.2.3+4
```

### 2. Build and Deploy

```bash
# Build for web
flutter build web

# Deploy to Firebase Hosting (or your hosting service)
firebase deploy --only hosting
```

### 3. Notify Users

Run the update tool to notify all connected users:

```bash
# Regular update (users can dismiss)
dart run tools/update_app_version.dart 1.2.3 "Added new features and fixed bugs"

# Force update (users must refresh)
dart run tools/update_app_version.dart 1.2.3 "Critical security fix" --force
```

That's it! All users will immediately see the update dialog.

## For Users: Getting Updates

When an update is available, you'll see a dialog showing:

- Your current version
- The new version available
- What's new in this update
- When the update was published

You can:

- **Click "Refresh Now"**: Get the update immediately
- **Click "Later"**: Continue using the current version (if allowed)

If it's a critical update, you'll need to refresh to continue using the app.

## Testing the System

### Test in Development

1. **Check current version**:

   ```bash
   flutter pub run package_info_plus
   ```

2. **Start your app**

3. **Open Firestore Console**:
   - Go to: https://console.firebase.google.com
   - Select your project
   - Navigate to: Firestore Database → `app_config` → `current_version`

4. **Change the version**:
   - Click on the document
   - Change `version` to a different number (e.g., "1.0.1")
   - Change `updateMessage` to "Test update"
   - Set `forceUpdate` to `false` or `true`
   - Save

5. **Observe**: The dialog should appear immediately in your running app

### Test the Update Tool

```bash
# Install dependencies first
flutter pub get

# Test normal update
dart run tools/update_app_version.dart 1.0.1 "Test message"

# Test force update
dart run tools/update_app_version.dart 1.0.2 "Test force update" --force
```

## Common Scenarios

### Scenario 1: Bug Fix Release

```bash
# No force update needed - users can update when ready
dart run tools/update_app_version.dart 1.2.4 "Fixed issue with job scheduling and improved performance"
```

### Scenario 2: New Feature Release

```bash
# Users can update at their convenience
dart run tools/update_app_version.dart 1.3.0 "New: Inventory management and bulk job operations"
```

### Scenario 3: Critical Security Fix

```bash
# Force update - users must refresh immediately
dart run tools/update_app_version.dart 1.2.5 "Critical security update - please refresh now" --force
```

### Scenario 4: Major Version Update

```bash
# Force update for breaking changes
dart run tools/update_app_version.dart 2.0.0 "Major update with new UI and features. Please refresh to continue" --force
```

## Firestore Document Structure

The version information is stored in Firestore:

**Collection**: `app_config`  
**Document**: `current_version`

```json
{
  "version": "1.2.3",
  "lastUpdated": "2024-01-15T10:30:00Z",
  "updateMessage": "Bug fixes and improvements",
  "forceUpdate": false
}
```

## Security

Add Firestore security rules:

```javascript
match /app_config/current_version {
  // Everyone can read version info
  allow read: if true;

  // Only admins can update
  allow write: if request.auth != null &&
               get(/databases/$(database)/documents/users/$(request.auth.uid)).data.isAdmin == true;
}
```

## Troubleshooting

### Dialog not showing?

1. Check browser console for errors
2. Verify Firestore rules allow read access
3. Make sure version in Firestore is different from app version

### Can't update version?

1. Ensure you have admin permissions in Firestore
2. Check Firebase authentication is working
3. Verify security rules allow write access for admins

### Need help?

See [APP_VERSION_MANAGEMENT.md](APP_VERSION_MANAGEMENT.md) for detailed documentation.
