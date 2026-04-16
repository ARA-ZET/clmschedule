// Web implementation using JS interop to call Google Maps Places JS library.
// This avoids CORS issues that block direct REST API calls from the browser.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'places_autocomplete_service.dart';

@JS('placesAutocomplete')
external JSPromise<JSArray<JSObject>> _placesAutocomplete(JSString input);

@JS('placesGetDetails')
external JSPromise<JSObject?> _placesGetDetails(JSString placeId);

/// Call the JS placesAutocomplete() function from places_helper.js
Future<List<PlaceSuggestion>> getAutocompleteSuggestions(String input) async {
  final jsResults = await _placesAutocomplete(input.toJS).toDart;
  final results = <PlaceSuggestion>[];

  for (final jsObj in jsResults.toDart) {
    results.add(PlaceSuggestion(
      placeId: (jsObj.getProperty('placeId'.toJS) as JSString).toDart,
      description: (jsObj.getProperty('description'.toJS) as JSString).toDart,
      mainText: (jsObj.getProperty('mainText'.toJS) as JSString).toDart,
      secondaryText:
          (jsObj.getProperty('secondaryText'.toJS) as JSString).toDart,
    ));
  }

  return results;
}

/// Call the JS placesGetDetails() function from places_helper.js
Future<LatLng?> getPlaceDetailsLatLng(String placeId) async {
  final jsResult = await _placesGetDetails(placeId.toJS).toDart;
  if (jsResult == null) return null;

  final lat = (jsResult.getProperty('lat'.toJS) as JSNumber).toDartDouble;
  final lng = (jsResult.getProperty('lng'.toJS) as JSNumber).toDartDouble;

  return LatLng(lat, lng);
}
