// Stub for non-web platforms. These functions are never called on non-web
// because PlacesAutocompleteService gates on kIsWeb before calling them.

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'places_autocomplete_service.dart';

Future<List<PlaceSuggestion>> getAutocompleteSuggestions(String input) async {
  throw UnsupportedError('JS interop is only available on web');
}

Future<LatLng?> getPlaceDetailsLatLng(String placeId) async {
  throw UnsupportedError('JS interop is only available on web');
}
