import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load Google Maps API key from local.properties
val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localProperties.load(FileInputStream(localPropertiesFile))
}
val googleMapsApiKey = localProperties.getProperty("GOOGLE_MAPS_API_KEY") ?: "AIzaSyBcY9Z77L3oE3Cuw-2trlyM5N2IuRh7S6k"

android {
    namespace = "com.example.clmschedule"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.clmschedule"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        // Inject Google Maps API key
        manifestPlaceholders["GOOGLE_MAPS_API_KEY"] = googleMapsApiKey
    }

    flavorDimensions += "app"
    
    productFlavors {
        create("clm") {
            dimension = "app"
            // Use same base applicationId for Firebase compatibility
            versionNameSuffix = "-clm"
            manifestPlaceholders["appName"] = "CLM Schedule"
            buildConfigField("boolean", "ENABLE_HAPPY_SUN", "true")
            buildConfigField("boolean", "ENABLE_COLLECTION_SCHEDULE", "true")
        }
        
        create("happysun") {
            dimension = "app"
            // Use same base applicationId for Firebase compatibility
            versionNameSuffix = "-happysun"
            manifestPlaceholders["appName"] = "Happy Sun"
            buildConfigField("boolean", "ENABLE_HAPPY_SUN", "true")
            buildConfigField("boolean", "ENABLE_COLLECTION_SCHEDULE", "false")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
