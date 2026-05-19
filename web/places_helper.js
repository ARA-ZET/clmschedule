// Google Places Autocomplete helper for Flutter web.
// Called from Dart via JS interop to avoid CORS issues.

(function() {
  'use strict';

  var autocompleteService = null;
  var placesService = null;

  function getAutocompleteService() {
    if (!autocompleteService && window.google && google.maps && google.maps.places) {
      autocompleteService = new google.maps.places.AutocompleteService();
    }
    return autocompleteService;
  }

  function getPlacesService() {
    if (!placesService && window.google && google.maps && google.maps.places) {
      // PlacesService needs a DOM element or map; use a hidden div
      var div = document.getElementById('places-service-div');
      if (!div) {
        div = document.createElement('div');
        div.id = 'places-service-div';
        div.style.display = 'none';
        document.body.appendChild(div);
      }
      placesService = new google.maps.places.PlacesService(div);
    }
    return placesService;
  }

  /**
   * Fetch autocomplete suggestions.
   * Returns a Promise<Array<{placeId, description, mainText, secondaryText}>>
   */
  window.placesAutocomplete = function(input) {
    return new Promise(function(resolve, reject) {
      var service = getAutocompleteService();
      if (!service) {
        resolve([]);
        return;
      }

      service.getPlacePredictions({
        input: input,
        location: new google.maps.LatLng(-33.925, 18.425),
        radius: 50000,
        componentRestrictions: { country: 'za' },
        language: 'en'
      }, function(predictions, status) {
        if (status !== google.maps.places.PlacesServiceStatus.OK || !predictions) {
          resolve([]);
          return;
        }
        var results = predictions.slice(0, 5).map(function(p) {
          var sf = p.structured_formatting || {};
          return {
            placeId: p.place_id || '',
            description: p.description || '',
            mainText: sf.main_text || '',
            secondaryText: sf.secondary_text || ''
          };
        });
        resolve(results);
      });
    });
  };

  /**
   * Get place details (lat/lng) for a given placeId.
   * Returns a Promise<{lat, lng} | null>
   */
  window.placesGetDetails = function(placeId) {
    return new Promise(function(resolve, reject) {
      var service = getPlacesService();
      if (!service) {
        resolve(null);
        return;
      }

      service.getDetails({
        placeId: placeId,
        fields: ['geometry']
      }, function(place, status) {
        if (status !== google.maps.places.PlacesServiceStatus.OK || !place || !place.geometry) {
          resolve(null);
          return;
        }
        resolve({
          lat: place.geometry.location.lat(),
          lng: place.geometry.location.lng()
        });
      });
    });
  };

  // ---------------------------------------------------------------------
  // Directions
  // ---------------------------------------------------------------------

  var directionsService = null;

  function getDirectionsService() {
    if (!directionsService && window.google && google.maps) {
      directionsService = new google.maps.DirectionsService();
    }
    return directionsService;
  }

  /**
   * Compute a driving route between two coordinates using the JS
   * DirectionsService (CORS-free on web).
   *
   * Args: originLat, originLng, destLat, destLng, departureEpochSec
   *   - departureEpochSec: optional unix seconds, used for traffic
   *     prediction. Pass 0 / null for free-flow.
   *
   * Returns: Promise<{
   *   distanceMeters,
   *   durationSeconds,
   *   durationInTrafficSeconds,
   *   path: Array<{lat, lng}>
   * } | null>
   */
  window.directionsRoute = function(originLat, originLng, destLat, destLng, departureEpochSec) {
    return new Promise(function(resolve) {
      var svc = getDirectionsService();
      if (!svc) {
        resolve(null);
        return;
      }
      var req = {
        origin: { lat: originLat, lng: originLng },
        destination: { lat: destLat, lng: destLng },
        travelMode: google.maps.TravelMode.DRIVING,
        provideRouteAlternatives: true,
      };
      if (departureEpochSec && departureEpochSec > 0) {
        var depDate = new Date(departureEpochSec * 1000);
        // Advance to the next future occurrence of this time-of-day so the
        // Directions API applies realistic historical traffic for the
        // scheduled hour even when the departure time has already passed.
        while (depDate.getTime() < Date.now()) {
          depDate = new Date(depDate.getTime() + 24 * 60 * 60 * 1000);
        }
        req.drivingOptions = {
          departureTime: depDate,
          trafficModel: 'bestguess'
        };
      }
      svc.route(req, function(result, status) {
        if (status !== 'OK' || !result || !result.routes || !result.routes[0]) {
          console.warn('DirectionsService status:', status);
          resolve(null);
          return;
        }
        // Pick the alternative with the shortest distance.
        var routes = result.routes;
        var bestRoute = routes[0];
        var bestDist = (bestRoute.legs[0].distance && bestRoute.legs[0].distance.value) || Infinity;
        for (var ri = 1; ri < routes.length; ri++) {
          var d = (routes[ri].legs[0].distance && routes[ri].legs[0].distance.value) || Infinity;
          if (d < bestDist) { bestDist = d; bestRoute = routes[ri]; }
        }
        var route = bestRoute;
        var leg = route.legs[0];
        var path = [];
        if (route.overview_path && route.overview_path.length) {
          for (var i = 0; i < route.overview_path.length; i++) {
            var p = route.overview_path[i];
            path.push({ lat: p.lat(), lng: p.lng() });
          }
        }
        resolve({
          distanceMeters: (leg.distance && leg.distance.value) || 0,
          durationSeconds: (leg.duration && leg.duration.value) || 0,
          durationInTrafficSeconds:
            (leg.duration_in_traffic && leg.duration_in_traffic.value) ||
            ((leg.duration && leg.duration.value) || 0),
          path: path
        });
      });
    });
  };
})();
