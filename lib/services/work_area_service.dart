import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:xml/xml.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/work_area.dart';

final workAreaServiceRiverpod = riverpod.Provider<WorkAreaService>(
  (ref) => WorkAreaService(FirebaseFirestore.instance),
);

class WorkAreaService {
  final FirebaseFirestore _firestore;
  final String collectionName = 'workAreas';

  WorkAreaService(this._firestore);

  // Parse KML file and create WorkAreas
  Future<List<WorkArea>> createFromKml(String kmlFileName) async {
    final workAreas = <WorkArea>[];

    try {
      // Load KML file from assets
      if (kDebugMode) {
        print('Loading KML file: maps/$kmlFileName');
      }
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

      if (kDebugMode) {
        print(
          'Cleaned KML content. First 100 chars: ${kmlString.substring(0, kmlString.length > 100 ? 100 : kmlString.length)}',
        );
      }

      XmlDocument? document;
      try {
        document = XmlDocument.parse(kmlString);
        if (kDebugMode) {
          print('Successfully parsed XML document');
        }
      } catch (e) {
        if (kDebugMode) {
          print('XML parsing error: $e');
        }
        if (kDebugMode) {
          print(
            'First 100 characters of KML: ${kmlString.substring(0, kmlString.length > 100 ? 100 : kmlString.length)}',
          );
        }
        rethrow;
      }

      // Find all Placemarks
      final placemarks = document.findAllElements('Placemark');
      if (kDebugMode) {
        print('Found ${placemarks.length} placemarks');
      }

      for (final placemark in placemarks) {
        try {
          // Try to extract name from either 'n' element or 'name' element
          var nameElement = placemark.findElements('n').firstOrNull ??
              placemark.findElements('name').firstOrNull;
          if (nameElement == null) {
            if (kDebugMode) {
              print('Skipping placemark: no name element found');
            }
            continue;
          }
          final name = nameElement.innerText.trim();
          if (name.isEmpty) {
            if (kDebugMode) {
              print('Skipping placemark: empty name');
            }
            continue;
          }
          if (kDebugMode) {
            print('Processing placemark: $name');
          }

          // Extract description if available
          final description =
              placemark.findElements('description').firstOrNull?.innerText ??
                  '';

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
          if (kDebugMode) {
            print('Parsing coordinates for area: $name');
          }
          if (kDebugMode) {
            print('Raw coordinates: $coordinates');
          }

          final points = coordinates
              .trim()
              .split(RegExp(r'[\n\s]+')) // Split on newlines and whitespace
              .where((s) => s.isNotEmpty)
              .map((coord) {
                try {
                  final parts = coord.split(',');
                  if (parts.length < 2) {
                    if (kDebugMode) {
                      print('Invalid coordinate format: $coord');
                    }
                    return null;
                  }

                  final lat = double.tryParse(parts[1].trim());
                  final lng = double.tryParse(parts[0].trim());

                  if (lat == null || lng == null) {
                    if (kDebugMode) {
                      print('Invalid coordinate numbers: $coord');
                    }
                    return null;
                  }

                  // Validate coordinate ranges
                  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
                    if (kDebugMode) {
                      print('Coordinate out of range: lat=$lat, lng=$lng');
                    }
                    return null;
                  }

                  return LatLng(lat, lng);
                } catch (e) {
                  if (kDebugMode) {
                    print('Failed to parse coordinate: $coord, error: $e');
                  }
                  return null;
                }
              })
              .where((point) => point != null)
              .cast<LatLng>()
              .toList();

          if (points.isEmpty) {
            if (kDebugMode) {
              print('No valid coordinates found for area: $name');
            }
            continue;
          }
          if (kDebugMode) {
            print(
              'Successfully parsed ${points.length} coordinates for area: $name',
            );
          }

          if (points.isEmpty) continue;

          try {
            if (kDebugMode) {
              print('Creating WorkArea object for: $name');
            }
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

            if (kDebugMode) {
              print('Saving to Firestore: $name');
            }
            // Save to Firestore
            final docRef = await _firestore
                .collection(collectionName)
                .add(workArea.toFirestore());
            if (kDebugMode) {
              print(
                'Successfully saved to Firestore: $name with ID: ${docRef.id}',
              );
            }
            workAreas.add(workArea.copyWith(id: docRef.id));
          } catch (e) {
            if (kDebugMode) {
              print('Failed to save area to Firestore: $name, error: $e');
            }
            continue;
          }
        } catch (e) {
          if (kDebugMode) {
            print('Failed to parse placemark: $e');
          }
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
        if (kDebugMode) {
          print('No outerBoundaryIs element found');
        }
        return null;
      }

      final linearRing = outerBoundary.findElements('LinearRing').firstOrNull;
      if (linearRing == null) {
        if (kDebugMode) {
          print('No LinearRing element found');
        }
        return null;
      }

      final coordinatesElement =
          linearRing.findElements('coordinates').firstOrNull;
      if (coordinatesElement == null) {
        if (kDebugMode) {
          print('No coordinates element found');
        }
        return null;
      }

      final coordinates = coordinatesElement.innerText.trim();
      if (coordinates.isEmpty) {
        if (kDebugMode) {
          print('Coordinates element is empty');
        }
        return null;
      }

      return coordinates;
    } catch (e) {
      if (kDebugMode) {
        print('Error extracting coordinates: $e');
      }
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
