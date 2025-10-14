# KML Integration Guide

This guide explains how to use the updated KML system with separate downloading and parsing components.

## Components Overview

### 1. KmlParserService (Updated)

**Location**: `lib/services/kml_parser_service.dart`

**Purpose**: Parse KML/KMZ data and create custom polygons (download functionality removed)

**Key Methods**:

- `parseKmlData(Uint8List kmlData, String fileName)` - Main entry point for parsing
- `parseKmlFromBytes(Uint8List fileBytes, String fileName)` - Parse KML bytes
- `extractKmlFromKmz(Uint8List kmzBytes)` - Extract KML from KMZ archive

### 2. MyMapsKmlDownloader (New)

**Location**: `lib/widgets/mymaps_kml_downloader.dart`

**Purpose**: Download KML files from Google My Maps URLs with callback support

**Key Features**:

- Beautiful UI with dotted border
- Google My Maps URL validation
- Progress indication
- Error handling with specific messages
- Callback function to pass downloaded data to parent widget

### 3. KmlMapDemo (New)

**Location**: `lib/widgets/kml_map_demo.dart`

**Purpose**: Complete example showing how to integrate both components

## Usage Examples

### Basic Integration

```dart
import 'package:flutter/foundation.dart';
import '../services/kml_parser_service.dart';
import '../widgets/mymaps_kml_downloader.dart';

class MyMapPage extends StatefulWidget {
  @override
  _MyMapPageState createState() => _MyMapPageState();
}

class _MyMapPageState extends State<MyMapPage> {
  List<CustomPolygon> _polygons = [];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // KML Downloader
        MyMapsKmlDownloader(
          onKmlDataRetrieved: _handleKmlData,
        ),

        // Your map widget here
        Expanded(
          child: GoogleMap(
            // ... map configuration
            polygons: _createMapPolygons(),
          ),
        ),
      ],
    );
  }

  void _handleKmlData(Uint8List kmlBytes, String fileName) async {
    try {
      final polygons = await KmlParserService.parseKmlData(kmlBytes, fileName);
      setState(() {
        _polygons = polygons;
      });
    } catch (e) {
      // Handle error
      print('Error parsing KML: $e');
    }
  }

  Set<Polygon> _createMapPolygons() {
    return _polygons.map((customPolygon) => Polygon(
      polygonId: PolygonId(customPolygon.name),
      points: customPolygon.points,
      strokeColor: customPolygon.color,
      fillColor: customPolygon.color.withOpacity(0.3),
    )).toSet();
  }
}
```

### Advanced Integration with Error Handling

```dart
void _handleKmlData(Uint8List kmlBytes, String fileName) async {
  setState(() {
    _isProcessing = true;
    _statusMessage = 'Processing KML file: $fileName...';
  });

  try {
    // Parse KML data
    final polygons = await KmlParserService.parseKmlData(kmlBytes, fileName);

    setState(() {
      _polygons = polygons;
      _statusMessage = 'Successfully loaded ${polygons.length} polygons';
      _isProcessing = false;
    });

    // Fit camera to show all polygons
    if (polygons.isNotEmpty) {
      _fitCameraToPolygons();
    }

  } catch (e) {
    setState(() {
      _statusMessage = 'Error: ${e.toString()}';
      _isProcessing = false;
    });

    // Show error dialog
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('KML Processing Error'),
        content: Text(e.toString()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('OK'),
          ),
        ],
      ),
    );
  }
}
```

## Key Changes Made

### 1. Removed from KmlParserService:

- All HTTP download functionality
- CORS proxy logic
- URL conversion methods
- Network error handling

### 2. Added to KmlParserService:

- `parseKmlData()` method as main entry point
- KMZ detection by file extension and content
- Streamlined API focused on parsing only

### 3. MyMapsKmlDownloader Features:

- Clean, reusable UI component
- Callback-based architecture
- Comprehensive error messages
- Google My Maps URL validation
- Web-only restriction (as intended)

### 4. KmlMapDemo Features:

- Complete working example
- Error handling and user feedback
- Polygon information display
- Camera fitting to show all polygons
- Progress indication

## Benefits

1. **Separation of Concerns**: Download logic separated from parsing logic
2. **Reusable Components**: Both downloader and parser can be used independently
3. **Better Error Handling**: More specific error messages and user guidance
4. **Cleaner API**: Simple, focused methods for each component
5. **UI Integration**: Ready-to-use UI component with callbacks

## Dependencies Added

```yaml
dependencies:
  dotted_border: ^2.1.0 # For the downloader UI
```

## Running the Demo

To see the complete integration in action, you can add the demo to your app:

```dart
// In your main app or routing
Navigator.push(
  context,
  MaterialPageRoute(builder: (context) => KmlMapDemo()),
);
```

The demo provides a fully functional example of downloading KML files from Google My Maps and displaying them on a Google Map with custom polygons.
