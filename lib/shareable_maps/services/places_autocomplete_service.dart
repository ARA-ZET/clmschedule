import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../../env.dart';

// Conditional import for JS interop on web
import 'places_stub.dart' if (dart.library.js_interop) 'places_web.dart'
    as places_js;

/// A suggestion returned by the Google Places Autocomplete API.
class PlaceSuggestion {
  final String placeId;
  final String description;
  final String mainText;
  final String secondaryText;

  const PlaceSuggestion({
    required this.placeId,
    required this.description,
    required this.mainText,
    required this.secondaryText,
  });
}

/// Service for Google Places Autocomplete, biased to Cape Town.
/// On web, uses the Google Maps JavaScript Places library via JS interop
/// to avoid CORS restrictions. On mobile, uses the REST API.
class PlacesAutocompleteService {
  static const _baseUrl =
      'https://maps.googleapis.com/maps/api/place/autocomplete/json';
  static const _detailsUrl =
      'https://maps.googleapis.com/maps/api/place/details/json';

  // Cape Town bias: lat -33.925, lng 18.425, radius ~50 km
  static const _capeTownLat = -33.925;
  static const _capeTownLng = 18.425;
  static const _radiusMeters = 50000;

  String get _apiKey => Env.googleMapsApiKey;

  /// Fetch autocomplete suggestions for [input].
  /// Returns at most 5 results, biased to Cape Town, South Africa.
  Future<List<PlaceSuggestion>> getSuggestions(String input) async {
    if (input.trim().isEmpty) return [];

    // On web, use JS interop to call the Places library directly
    if (kIsWeb) {
      return _getWebSuggestions(input);
    }
    return _getHttpSuggestions(input);
  }

  /// Get the lat/lng for a place by its [placeId].
  Future<LatLng?> getPlaceDetails(String placeId) async {
    if (placeId.isEmpty) return null;

    // On web, use JS interop
    if (kIsWeb) {
      return _getWebPlaceDetails(placeId);
    }
    return _getHttpPlaceDetails(placeId);
  }

  // === Web (JS interop) implementations ===

  Future<List<PlaceSuggestion>> _getWebSuggestions(String input) async {
    try {
      return await places_js.getAutocompleteSuggestions(input);
    } catch (e) {
      debugPrint('Places JS autocomplete error: $e');
      return [];
    }
  }

  Future<LatLng?> _getWebPlaceDetails(String placeId) async {
    try {
      return await places_js.getPlaceDetailsLatLng(placeId);
    } catch (e) {
      debugPrint('Places JS details error: $e');
      return null;
    }
  }

  // === HTTP (mobile/desktop) implementations ===

  Future<List<PlaceSuggestion>> _getHttpSuggestions(String input) async {
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'input': input,
      'key': _apiKey,
      'location': '$_capeTownLat,$_capeTownLng',
      'radius': '$_radiusMeters',
      'components': 'country:za',
      'language': 'en',
    });

    try {
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        debugPrint('Places API error: ${response.statusCode}');
        return [];
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final predictions = json['predictions'] as List<dynamic>? ?? [];

      return predictions.take(5).map((p) {
        final structured =
            (p['structured_formatting'] == null ? null : Map<String, dynamic>.from(p['structured_formatting'] as Map)) ?? {};
        return PlaceSuggestion(
          placeId: p['place_id'] as String? ?? '',
          description: p['description'] as String? ?? '',
          mainText: structured['main_text'] as String? ?? '',
          secondaryText: structured['secondary_text'] as String? ?? '',
        );
      }).toList();
    } catch (e) {
      debugPrint('Places autocomplete error: $e');
      return [];
    }
  }

  Future<LatLng?> _getHttpPlaceDetails(String placeId) async {
    final uri = Uri.parse(_detailsUrl).replace(queryParameters: {
      'place_id': placeId,
      'key': _apiKey,
      'fields': 'geometry',
    });

    try {
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        debugPrint('Place Details API error: ${response.statusCode}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final result = (json['result'] == null ? null : Map<String, dynamic>.from(json['result'] as Map));
      final geometry = result?['geometry'] as Map<String, dynamic>?;
      final location = geometry?['location'] as Map<String, dynamic>?;

      if (location != null) {
        return LatLng(
          (location['lat'] as num).toDouble(),
          (location['lng'] as num).toDouble(),
        );
      }
      return null;
    } catch (e) {
      debugPrint('Place details error: $e');
      return null;
    }
  }
}
