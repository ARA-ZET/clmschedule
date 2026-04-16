import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/erf_property.dart';
import '../services/csg_property_service.dart';
import '../services/erf_property_firestore_service.dart';
import '../../services/geocoding_service.dart';

/// Riverpod provider for ErfPropertyProvider.
final erfPropertyRiverpod =
    riverpod.ChangeNotifierProvider<ErfPropertyProvider>(
        (ref) => ErfPropertyProvider());

/// Provider for managing ERF property data.
///
/// Handles:
/// - Fetching properties from the CSG API by bounding box or point
/// - Persisting fetched properties to Firestore
/// - Looking up which ERF a given lat/lng falls within
/// - Reverse-linking addresses to ERF numbers
class ErfPropertyProvider extends ChangeNotifier {
  final CsgPropertyService _csgService = CsgPropertyService();
  final ErfPropertyFirestoreService _firestoreService =
      ErfPropertyFirestoreService();
  final GeocodingService _geocodingService = GeocodingService();

  List<ErfProperty> _properties = [];
  List<ErfProperty> get properties => _properties;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  int _totalFetched = 0;
  int get totalFetched => _totalFetched;

  StreamSubscription? _subscription;

  /// Initialize by loading saved properties from Firestore.
  void initialize() {
    _subscription = _firestoreService.streamProperties().listen(
      (properties) {
        _properties = properties;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('❌ ErfPropertyProvider stream error: $e');
      },
    );
  }

  /// Fetch ERF properties from the CSG API for a bounding box area
  /// and save them to Firestore.
  Future<int> fetchAndSaveArea({
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
    String? suburb,
  }) async {
    _isLoading = true;
    _error = null;
    _totalFetched = 0;
    notifyListeners();

    try {
      final results = await _csgService.queryAllInBoundingBox(
        minLat: minLat,
        minLng: minLng,
        maxLat: maxLat,
        maxLng: maxLng,
        onProgress: (loaded, hasMore) {
          _totalFetched = loaded;
          notifyListeners();
        },
      );

      // Tag with suburb name if provided
      final tagged = suburb != null
          ? results.map((p) => p.copyWith(suburb: suburb)).toList()
          : results;

      // Save to Firestore in batches of 500
      for (var i = 0; i < tagged.length; i += 500) {
        final end = (i + 500 < tagged.length) ? i + 500 : tagged.length;
        await _firestoreService.saveProperties(tagged.sublist(i, end));
      }

      _totalFetched = tagged.length;
      _isLoading = false;
      notifyListeners();

      debugPrint('✅ Fetched and saved ${tagged.length} properties');
      return tagged.length;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      debugPrint('❌ fetchAndSaveArea error: $e');
      return 0;
    }
  }

  /// Find which ERF property contains a given point.
  ///
  /// First checks locally cached properties, then queries the CSG API.
  Future<ErfProperty?> findPropertyAtPoint(LatLng point) async {
    // Check cached properties first
    for (final property in _properties) {
      if (_isPointInPolygon(point, property.polygon)) {
        return property;
      }
    }

    // Query CSG API
    final results = await _csgService.queryByPoint(
      latitude: point.latitude,
      longitude: point.longitude,
    );

    if (results.isNotEmpty) {
      // Save to Firestore for future lookups
      await _firestoreService.saveProperty(results.first);
      return results.first;
    }

    return null;
  }

  /// Look up ERF for a street address by geocoding it first,
  /// then finding which ERF polygon contains that point.
  Future<ErfProperty?> findPropertyByAddress(String address) async {
    final coords = await _geocodingService.geocodeAddress(address);
    if (coords == null) return null;

    return findPropertyAtPoint(LatLng(coords['lat']!, coords['lng']!));
  }

  /// Update the street address for a saved property.
  Future<void> updatePropertyAddress(
      String propertyId, String streetAddress, String suburb) async {
    await _firestoreService.updateAddress(propertyId, streetAddress, suburb);
  }

  /// Get saved properties for a specific suburb.
  Future<List<ErfProperty>> getPropertiesForSuburb(String suburb) async {
    return _firestoreService.getPropertiesBySuburb(suburb);
  }

  /// Ray-casting algorithm to check if a point is inside a polygon.
  bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) return false;

    bool inside = false;
    int j = polygon.length - 1;

    for (int i = 0; i < polygon.length; i++) {
      if ((polygon[i].latitude > point.latitude) !=
              (polygon[j].latitude > point.latitude) &&
          point.longitude <
              (polygon[j].longitude - polygon[i].longitude) *
                      (point.latitude - polygon[i].latitude) /
                      (polygon[j].latitude - polygon[i].latitude) +
                  polygon[i].longitude) {
        inside = !inside;
      }
      j = i;
    }

    return inside;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
