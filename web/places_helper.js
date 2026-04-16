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
})();
