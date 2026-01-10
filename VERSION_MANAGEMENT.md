# Version Management System

This system ensures users always get the latest version of your web app by checking Firestore for version updates and prompting users to reload when a new version is deployed.

## How It Works

1. **App Startup**: When the app loads, it reads its version from `pubspec.yaml` and compares it with the version stored in Firestore
2. **Real-time Monitoring**: The app subscribes to version changes in Firestore
3. **Update Detection**: When a new version is detected, users see a dialog prompting them to reload
4. **Force Reload**: Clicking "Reload Now" clears the cache and loads the fresh version

## Deployment Process

### Option 1: Automated Deployment (Recommended)

1. Update version in `pubspec.yaml`:

   ```yaml
   version: 1.2.3+1
   ```

2. Make the deployment script executable (first time only):

   ```bash
   chmod +x deploy_web.sh
   ```

3. Run the deployment script:

   ```bash
   ./deploy_web.sh
   ```

   This script will:

   - Build the web app
   - Deploy to Firebase Hosting
   - Update the version in Firestore automatically

### Option 2: Manual Deployment

1. Update version in `pubspec.yaml`

2. Build and deploy:

   ```bash
   flutter clean
   flutter pub get
   dart run tools/replace_maps_key.dart
   flutter build web --release
   firebase deploy --only hosting
   ```

3. Update Firestore version:
   ```bash
   dart run tools/update_firestore_version.dart 1.2.3
   ```

### Option 3: Manual Firestore Update

If the script fails, you can manually update in Firebase Console:

1. Go to Firestore Database
2. Navigate to collection: `appConfig`
3. Edit document: `version`
4. Set fields:
   ```
   version: "1.2.3"
   forceUpdate: true
   lastUpdated: <current timestamp>
   ```

## Configuration Options

### Disable Force Update

If you want to allow users to continue using the old version:

In `tools/update_firestore_version.dart`, change:

```dart
'forceUpdate': false,  // Users won't be forced to reload immediately
```

### Customize Update Dialog

Edit `lib/widgets/new_version_dialog.dart` to customize the appearance and message of the update dialog.

## Firestore Structure

```
appConfig (collection)
└── version (document)
    ├── version: "1.2.3"
    ├── forceUpdate: true
    └── lastUpdated: timestamp
```

## Testing

To test the version checking system:

1. Deploy your app with version 1.0.0
2. Open the app in a browser
3. In Firebase Console, change the version to 1.0.1
4. The update dialog should appear automatically within a few seconds

## Troubleshooting

**Users still see old version after deployment:**

- Check if version was updated in Firestore
- Clear browser cache manually (Ctrl+Shift+R or Cmd+Shift+R)
- Check browser console for errors

**Version script fails:**

- Ensure Firebase is initialized properly
- Check if you have write permissions to Firestore
- Verify firebase_options.dart is up to date

## Security Rules

Add this rule to your Firestore security rules to allow public read access to version info:

```javascript
match /appConfig/{document=**} {
  allow read: if true;  // Public read access for version checking
  allow write: if false; // Only allow writes from admin/server
}
```

Or if you want to restrict to authenticated users only:

```javascript
match /appConfig/{document=**} {
  allow read: if request.auth != null;
  allow write: if false;
}
```
