<<<<<<< HEAD

````markdown
=======

# CLM Schedule

A Flutter application for managing team scheduling and job assignments. This app provides a drag-and-drop interface for managing jobs and distributors, with real-time updates and offline support using Firebase.

## Features

- Real-time schedule updates with Firebase Firestore
- Drag-and-drop job assignments
- Offline-first functionality
- Editable job cards with client information
- Map integration for job locations
- Color-coded job status indicators
- Multi-platform support (iOS, Android, Web)

## Prerequisites

Before you begin, ensure you have the following installed:

- Flutter SDK (3.8.0 or later)
- Dart SDK (3.8.0 or later)
- Git
- A code editor (VS Code, Android Studio, or IntelliJ)
- Firebase CLI (for deployment and configuration)

## Setup Instructions

1. **Clone the Repository**

   ```bash
   git clone https://github.com/ARA-ZET/clmschedule.git
   cd clmschedule
   ```

2. **Install Dependencies**

   ```bash
   flutter pub get
   ```

3. **Firebase Configuration**

   - Create a new project in the [Firebase Console](https://console.firebase.google.com/)
   - Enable Firestore Database in your Firebase project
   - Download the configuration files:
     - For Android: Download `google-services.json` and place it in `android/app/`
     - For iOS: Download `GoogleService-Info.plist` and place it in `ios/Runner/`
     - For macOS: Download `GoogleService-Info.plist` and place it in `macos/Runner/`

4. **Environment Setup**

   ```bash
   # Copy the environment template
   cp .env.example .env
   ```

   - Open the `.env` file and fill in your configuration:

     ```
     # Firebase Configuration
     FIREBASE_API_KEY=your_firebase_api_key_here
     FIREBASE_APP_ID=your_app_id_here
     FIREBASE_MESSAGING_SENDER_ID=your_messaging_sender_id_here
     FIREBASE_PROJECT_ID=your_project_id_here
     FIREBASE_STORAGE_BUCKET=your_storage_bucket_here
     FIREBASE_AUTH_DOMAIN=your_auth_domain_here
     FIREBASE_IOS_CLIENT_ID=your_ios_client_id_here
     FIREBASE_IOS_BUNDLE_ID=your_ios_bundle_id_here

     # Google Maps Configuration
     GOOGLE_MAPS_API_KEY=your_google_maps_api_key_here
     ```

5. **Google Maps Setup**

   - Go to [Google Cloud Console](https://console.cloud.google.com/)
   - Create a new project or select an existing one
   - Enable the following APIs:
     - Maps JavaScript API
     - Maps SDK for Android
     - Maps SDK for iOS
   - Create an API key with appropriate restrictions
   - Add the API key to your `.env` file
   - For web deployment, run:
     ```bash
     dart run tools/replace_maps_key.dart
     ```

6. **Generate Configuration Files**

   ```bash
   flutter pub run build_runner build --delete-conflicting-outputs
   ```

7. **Run the App**
   ```bash
   flutter run
   ```

## Project Structure

```
lib/
├── models/          # Data models (Distributor, Job, Schedule)
├── providers/       # State management (ScheduleProvider)
├── services/        # Firebase services (FirestoreService)
├── utils/          # Utility functions and seed data
└── widgets/        # UI components
```

## Development Workflow

1. **Adding New Features**

   - Create a new branch for your feature
   - Implement the feature
   - Test thoroughly
   - Create a pull request

2. **Running Tests**

   ```bash
   flutter test
   ```

3. **Building for Production**
   ```bash
   flutter build <platform>
   ```
   Replace `<platform>` with:
   - `apk` for Android
   - `ios` for iOS
   - `web` for web deployment
   - `macos` for macOS

## Firebase Collections

The app uses the following Firestore collections:

- `/distributors/{id}` - Contains distributor information

  - Fields: name

- `/jobs/{id}` - Contains job information
  - Fields: client, workingArea, mapLink, distributorId, date, startTime, endTime, status

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## Troubleshooting

1. **Build Errors**

   - Run `flutter clean`
   - Delete the `build` folder
   - Run `flutter pub get`
   - Run `flutter pub run build_runner build --delete-conflicting-outputs`

2. **Firebase Issues**
   - Ensure all configuration files are in place
   - Verify the `.env` file contains correct values
   - Check Firebase Console for any service disruptions

## Security Note

⚠️ **Important: Never commit the following files to version control:**

- `.env` file (contains all API keys and secrets)
- `google-services.json` (Firebase Android config)
- `GoogleService-Info.plist` (Firebase iOS/macOS config)
- `lib/firebase_options.dart` (generated Firebase config)
- `lib/env.dart` & `lib/env.g.dart` (generated environment files)
- `web/maps_config.js` (auto-generated with API keys)

These files contain sensitive information and are already in `.gitignore`.

### For Web Deployment:

The `web/maps_config.js` file is automatically generated during build using the `GOOGLE_MAPS_API_KEY` from your `.env` file. Before building for web, run:

```bash
dart run tools/replace_maps_key.dart
```

### Environment Setup Checklist:

1. ✅ Copy `.env.example` to `.env`
2. ✅ Fill in all required API keys and configuration
3. ✅ Verify `.env` is in `.gitignore`
4. ✅ Run build_runner to generate config files
5. ✅ Never commit real API keys to version control
````
