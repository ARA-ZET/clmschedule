import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:xml/xml.dart';
import 'package:flutter/foundation.dart';
import '../models/work_area.dart';

class WorkAreaService {
  final FirebaseFirestore _firestore;
  final String collectionName = 'workAreas';

  WorkAreaService(this._firestore);

  // Parse KML file and create WorkAreas
  Future<List<WorkArea>> createFromKml(String kmlFileName) async {
    final workAreas = <WorkArea>[];

    try {
      // Load KML file from assets
      print('Loading KML file: maps/$kmlFileName');
      String kmlString = await rootBundle.loadString('maps/$kmlFileName');
      if (kDebugMode) {
        print('KML file loaded, length: ${kmlString.length}');
      }

      // Clean up any UTF-8 BOM or extra characters
      kmlString = kmlString.replaceAll(
        RegExp(r'^[\uFEFF\u{EF}\u{BB}\u{BF}fl]+'),
        '',
      );

      // Ensure the XML declaration is at the start
      if (!kmlString.trimLeft().startsWith('<?xml')) {
        kmlString = '<?xml version="1.0" encoding="UTF-8"?>\n$kmlString';
      }

      print(
        'Cleaned KML content. First 100 chars: ${kmlString.substring(0, kmlString.length > 100 ? 100 : kmlString.length)}',
      );

      XmlDocument? document;
      try {
        document = XmlDocument.parse(kmlString);
        print('Successfully parsed XML document');
      } catch (e) {
        print('XML parsing error: $e');
        print(
          'First 100 characters of KML: ${kmlString.substring(0, kmlString.length > 100 ? 100 : kmlString.length)}',
        );
        rethrow;
      }

      // Find all Placemarks
      final placemarks = document.findAllElements('Placemark');
      print('Found ${placemarks.length} placemarks');

      for (final placemark in placemarks) {
        try {
          // Try to extract name from either 'n' element or 'name' element
          var nameElement = placemark.findElements('n').firstOrNull ??
              placemark.findElements('name').firstOrNull;
          if (nameElement == null) {
            print('Skipping placemark: no name element found');
            continue;
          }
          final name = nameElement.text.trim();
          if (name.isEmpty) {
            print('Skipping placemark: empty name');
            continue;
          }
          print('Processing placemark: $name');

          // Extract description if available
          final description =
              placemark.findElements('description').firstOrNull?.text ?? '';

          // Find coordinates
          String? coordinates;

          // Check for MultiGeometry first
          final multiGeometry =
              placemark.findElements('MultiGeometry').firstOrNull;
          if (multiGeometry != null) {
            // Use the first polygon in MultiGeometry
            final polygon = multiGeometry.findElements('Polygon').firstOrNull;
            if (polygon != null) {
              coordinates = _extractCoordinates(polygon);
            }
          } else {
            // Try single Polygon
            final polygon = placemark.findElements('Polygon').firstOrNull;
            if (polygon != null) {
              coordinates = _extractCoordinates(polygon);
            }
          }

          if (coordinates == null) continue;

          // Parse coordinates into points
          print('Parsing coordinates for area: $name');
          print('Raw coordinates: $coordinates');

          final points = coordinates
              .trim()
              .split(RegExp(r'[\n\s]+')) // Split on newlines and whitespace
              .where((s) => s.isNotEmpty)
              .map((coord) {
                try {
                  final parts = coord.split(',');
                  if (parts.length < 2) {
                    print('Invalid coordinate format: $coord');
                    return null;
                  }

                  final lat = double.tryParse(parts[1].trim());
                  final lng = double.tryParse(parts[0].trim());

                  if (lat == null || lng == null) {
                    print('Invalid coordinate numbers: $coord');
                    return null;
                  }

                  // Validate coordinate ranges
                  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
                    print('Coordinate out of range: lat=$lat, lng=$lng');
                    return null;
                  }

                  return LatLng(lat, lng);
                } catch (e) {
                  print('Failed to parse coordinate: $coord, error: $e');
                  return null;
                }
              })
              .where((point) => point != null)
              .cast<LatLng>()
              .toList();

          if (points.isEmpty) {
            print('No valid coordinates found for area: $name');
            continue;
          }
          print(
            'Successfully parsed ${points.length} coordinates for area: $name',
          );

          if (points.isEmpty) continue;

          try {
            print('Creating WorkArea object for: $name');
            // Create new WorkArea
            final workArea = WorkArea(
              id: '', // Will be set by Firestore
              name: name,
              description: description,
              polygonPoints: points,
              kmlFileName: kmlFileName,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            );

            print('Saving to Firestore: $name');
            // Save to Firestore
            final docRef = await _firestore
                .collection(collectionName)
                .add(workArea.toFirestore());
            print(
              'Successfully saved to Firestore: $name with ID: ${docRef.id}',
            );
            workAreas.add(workArea.copyWith(id: docRef.id));
          } catch (e) {
            print('Failed to save area to Firestore: $name, error: $e');
            continue;
          }
        } catch (e) {
          print('Failed to parse placemark: $e');
          // Continue with next placemark
        }
      }
    } catch (e) {
      throw Exception('Failed to parse KML file: $e');
    }

    return workAreas;
  }

  String? _extractCoordinates(XmlElement polygon) {
    try {
      final outerBoundary = polygon.findElements('outerBoundaryIs').firstOrNull;
      if (outerBoundary == null) {
        print('No outerBoundaryIs element found');
        return null;
      }

      final linearRing = outerBoundary.findElements('LinearRing').firstOrNull;
      if (linearRing == null) {
        print('No LinearRing element found');
        return null;
      }

      final coordinatesElement =
          linearRing.findElements('coordinates').firstOrNull;
      if (coordinatesElement == null) {
        print('No coordinates element found');
        return null;
      }

      final coordinates = coordinatesElement.text.trim();
      if (coordinates.isEmpty) {
        print('Coordinates element is empty');
        return null;
      }

      return coordinates;
    } catch (e) {
      print('Error extracting coordinates: $e');
      return null;
    }
  }

  // Get all work areas
  Stream<List<WorkArea>> getWorkAreas() {
    return _firestore.collection(collectionName).snapshots().map((snapshot) {
      return snapshot.docs.map((doc) => WorkArea.fromFirestore(doc)).toList();
    });
  }

  // Get a single work area
  Future<WorkArea?> getWorkArea(String id) async {
    final doc = await _firestore.collection(collectionName).doc(id).get();
    if (!doc.exists) return null;
    return WorkArea.fromFirestore(doc);
  }

  // Update a work area
  Future<void> updateWorkArea(WorkArea workArea) async {
    await _firestore
        .collection(collectionName)
        .doc(workArea.id)
        .update(workArea.toFirestore());
  }

  // Delete a work area
  Future<void> deleteWorkArea(String id) async {
    await _firestore.collection(collectionName).doc(id).delete();
  }

  // Create a new work area from polygon points
  Future<WorkArea> createWorkArea({
    required String name,
    required String description,
    required List<LatLng> polygonPoints,
  }) async {
    final workArea = WorkArea(
      id: '', // Will be set by Firestore
      name: name,
      description: description,
      polygonPoints: polygonPoints,
      kmlFileName: '', // User-created areas don't have KML files
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    // Save to Firestore
    final docRef =
        await _firestore.collection(collectionName).add(workArea.toFirestore());

    return workArea.copyWith(id: docRef.id);
  }
}
