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
  // Shared plumbing
  // ---------------------------------------------------------------------

  /**
   * Wrap a callback-style Google Maps call in a Promise that is guaranteed
   * to settle exactly once and never hang.
   *
   * The Maps JS callbacks are fire-and-forget: if the library drops one
   * (quota exhaustion, a torn-down iframe, a transient network stall) the
   * surrounding Promise would never resolve, and any Dart `await` on it
   * would block forever — which is exactly how a progress overlay ends up
   * spinning with nothing left to complete it. The timeout below turns
   * that into a null result the caller can fall back from.
   */
  function guarded(timeoutMs, label, executor) {
    return new Promise(function (resolve) {
      var settled = false;
      var timer = setTimeout(function () {
        if (settled) return;
        settled = true;
        console.warn('places_helper: ' + label + ' timed out after ' + timeoutMs + 'ms');
        resolve(null);
      }, timeoutMs);

      function done(value) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(value);
      }

      try {
        executor(done);
      } catch (e) {
        console.error('places_helper: ' + label + ' threw', e);
        done(null);
      }
    });
  }

  /**
   * The Maps script is loaded async, so an early call can arrive before
   * google.maps exists. Poll briefly rather than reporting a false failure.
   */
  function whenMapsReady(callback) {
    var waitedMs = 0;
    var STEP_MS = 100;
    var TIMEOUT_MS = 10000;
    (function poll() {
      if (window.google && google.maps) {
        callback(true);
        return;
      }
      if (waitedMs >= TIMEOUT_MS) {
        console.warn('Google Maps API did not load within ' + TIMEOUT_MS + 'ms');
        callback(false);
        return;
      }
      waitedMs += STEP_MS;
      setTimeout(poll, STEP_MS);
    })();
  }

  /** Retry helper for the shared OVER_QUERY_LIMIT throttle response. */
  function backoffMs(attempt) {
    return Math.min(4000, 200 * Math.pow(2, attempt));
  }

  // ---------------------------------------------------------------------
  // Geocoding
  // ---------------------------------------------------------------------

  var geocoder = null;

  function getGeocoder() {
    if (!geocoder && window.google && google.maps) {
      geocoder = new google.maps.Geocoder();
    }
    return geocoder;
  }

  /**
   * Resolve an address string to coordinates using the JS Geocoder
   * (CORS-free on web; the REST Geocoding API is blocked in the browser).
   *
   * `bounds` biases results towards a region — pass a JSON string
   * `{"south":..,"west":..,"north":..,"east":..}` or '' for none.
   *
   * Returns: Promise<
   *     {ok: true, lat, lng, formattedAddress, locationType, partialMatch,
   *      placeId, types, status}
   *   | {ok: false, status}          // geocoder answered, no usable result
   *   | null                          // helper unavailable / timed out
   * >
   */
  window.geocodeAddressJs = function (address, regionCode, boundsJson) {
    return guarded(20000, 'geocode', function (done) {
      whenMapsReady(function (ready) {
        if (!ready) return done(null);
        var svc = getGeocoder();
        if (!svc) return done(null);

        var req = { address: address };
        if (regionCode) req.region = regionCode;
        if (boundsJson) {
          try {
            var b = JSON.parse(boundsJson);
            req.bounds = new google.maps.LatLngBounds(
              new google.maps.LatLng(b.south, b.west),
              new google.maps.LatLng(b.north, b.east)
            );
          } catch (e) {
            /* unparseable bias is not fatal — geocode unbiased */
          }
        }

        var attempt = 0;
        (function run() {
          svc.geocode(req, function (results, status) {
            if (status === 'OVER_QUERY_LIMIT' && attempt < 5) {
              attempt++;
              setTimeout(run, backoffMs(attempt));
              return;
            }
            if (status !== 'OK' || !results || !results.length) {
              done({ ok: false, status: String(status) });
              return;
            }
            var r = results[0];
            var loc = r.geometry.location;
            done({
              ok: true,
              status: 'OK',
              lat: loc.lat(),
              lng: loc.lng(),
              formattedAddress: r.formatted_address || '',
              locationType: (r.geometry && r.geometry.location_type) || '',
              partialMatch: !!r.partial_match,
              placeId: r.place_id || '',
              types: (r.types || []).join(',')
            });
          });
        })();
      });
    });
  };

  /**
   * Name the suburb at a coordinate (reverse geocode) — used by the Track
   * Editor's client report to label where a distributor worked.
   *
   * Prefers the most specific place name Google gives for the first result:
   * sublocality_level_2 ("Bellville Central", "Retreat"), then neighborhood,
   * then sublocality_level_1, then locality.
   *
   * Returns: Promise<{ok: true, suburb, status} | {ok: false, status} | null>
   */
  window.reverseGeocodeSuburbJs = function (lat, lng) {
    return guarded(20000, 'reverseGeocode', function (done) {
      whenMapsReady(function (ready) {
        if (!ready) return done(null);
        var svc = getGeocoder();
        if (!svc) return done(null);

        var attempt = 0;
        (function run() {
          svc.geocode({ location: { lat: lat, lng: lng } }, function (results, status) {
            if (status === 'OVER_QUERY_LIMIT' && attempt < 5) {
              attempt++;
              setTimeout(run, backoffMs(attempt));
              return;
            }
            if (status !== 'OK' || !results || !results.length) {
              done({ ok: false, status: String(status) });
              return;
            }
            var order = ['sublocality_level_2', 'neighborhood', 'sublocality_level_1', 'locality'];
            var comps = results[0].address_components || [];
            for (var i = 0; i < order.length; i++) {
              for (var j = 0; j < comps.length; j++) {
                if ((comps[j].types || []).indexOf(order[i]) !== -1) {
                  done({ ok: true, status: 'OK', suburb: comps[j].long_name });
                  return;
                }
              }
            }
            done({ ok: false, status: 'NO_SUBURB' });
          });
        })();
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

  /** Build the drivingOptions block for a departure time, or null. */
  function drivingOptionsFor(departureEpochSec) {
    if (!departureEpochSec || departureEpochSec <= 0) return null;
    var depDate = new Date(departureEpochSec * 1000);
    // Advance to the next future occurrence of this time-of-day so the
    // Directions API applies realistic historical traffic for the
    // scheduled hour even when the departure time has already passed.
    while (depDate.getTime() < Date.now()) {
      depDate = new Date(depDate.getTime() + 24 * 60 * 60 * 1000);
    }
    return { departureTime: depDate, trafficModel: 'bestguess' };
  }

  /** Flatten a leg's step paths into a plain {lat,lng} array. */
  function legPath(leg) {
    var path = [];
    if (leg.steps) {
      for (var s = 0; s < leg.steps.length; s++) {
        var st = leg.steps[s];
        if (!st.path) continue;
        for (var p = 0; p < st.path.length; p++) {
          path.push({ lat: st.path[p].lat(), lng: st.path[p].lng() });
        }
      }
    }
    return path;
  }

  function legSummary(leg) {
    var d = (leg.distance && leg.distance.value) || 0;
    var t = (leg.duration && leg.duration.value) || 0;
    var tt = (leg.duration_in_traffic && leg.duration_in_traffic.value) || t;
    return {
      distanceMeters: d,
      durationSeconds: t,
      durationInTrafficSeconds: tt,
      startAddress: leg.start_address || '',
      endAddress: leg.end_address || '',
      path: legPath(leg)
    };
  }

  /**
   * Compute a driving route between two coordinates using the JS
   * DirectionsService (CORS-free on web).
   *
   * Returns: Promise<{distanceMeters, durationSeconds,
   *                   durationInTrafficSeconds, path} | null>
   */
  window.directionsRoute = function (originLat, originLng, destLat, destLng, departureEpochSec) {
    return guarded(20000, 'directionsRoute', function (done) {
      whenMapsReady(function (ready) {
        if (!ready) return done(null);
        var svc = getDirectionsService();
        if (!svc) return done(null);

        var req = {
          origin: { lat: originLat, lng: originLng },
          destination: { lat: destLat, lng: destLng },
          travelMode: google.maps.TravelMode.DRIVING,
          provideRouteAlternatives: true
        };
        var opts = drivingOptionsFor(departureEpochSec);
        if (opts) req.drivingOptions = opts;

        var attempt = 0;
        (function run() {
          svc.route(req, function (result, status) {
            if (status === 'OVER_QUERY_LIMIT' && attempt < 5) {
              attempt++;
              setTimeout(run, backoffMs(attempt));
              return;
            }
            if (status !== 'OK' || !result || !result.routes || !result.routes[0]) {
              console.warn('DirectionsService status:', status);
              return done(null);
            }
            // Pick the alternative with the shortest distance.
            var routes = result.routes;
            var bestRoute = routes[0];
            var bestDist = (bestRoute.legs[0].distance && bestRoute.legs[0].distance.value) || Infinity;
            for (var ri = 1; ri < routes.length; ri++) {
              var d = (routes[ri].legs[0].distance && routes[ri].legs[0].distance.value) || Infinity;
              if (d < bestDist) { bestDist = d; bestRoute = routes[ri]; }
            }
            var leg = bestRoute.legs[0];
            var path = [];
            if (bestRoute.overview_path && bestRoute.overview_path.length) {
              for (var i = 0; i < bestRoute.overview_path.length; i++) {
                var p = bestRoute.overview_path[i];
                path.push({ lat: p.lat(), lng: p.lng() });
              }
            }
            done({
              distanceMeters: (leg.distance && leg.distance.value) || 0,
              durationSeconds: (leg.duration && leg.duration.value) || 0,
              durationInTrafficSeconds:
                (leg.duration_in_traffic && leg.duration_in_traffic.value) ||
                ((leg.duration && leg.duration.value) || 0),
              path: path
            });
          });
        })();
      });
    });
  };

  /**
   * Multi-stop routing in ONE Directions request, optionally letting
   * Google reorder the intermediate stops (`optimizeWaypoints`).
   *
   * This is what makes large runs viable: a 26-stop chunk costs a single
   * request instead of 25 sequential ones, the legs come back with real
   * road geometry, and the reordering uses road distances rather than the
   * straight-line guesses a client-side solver is limited to.
   *
   * Args:
   *   stopsJson  JSON array of {lat,lng}; index 0 is the origin and the
   *              last entry the destination (unless roundTrip).
   *   departureEpochSec  unix seconds for traffic prediction, 0 for none.
   *   optimize   reorder the intermediate waypoints.
   *   roundTrip  finish back at the origin; every other stop is treated
   *              as an intermediate waypoint.
   *
   * Returns: Promise<
   *     {ok: true, waypointOrder: number[], legs: [...],
   *      totalDistanceMeters, totalDurationSeconds,
   *      totalDurationInTrafficSeconds}
   *   | {ok: false, status}
   *   | null>
   *
   * `waypointOrder` indexes the intermediate waypoints only, exactly as
   * the Maps API reports it — the caller maps it back onto its own list.
   */
  window.directionsRouteOptimized = function (stopsJson, departureEpochSec, optimize, roundTrip) {
    return guarded(60000, 'directionsRouteOptimized', function (done) {
      whenMapsReady(function (ready) {
        if (!ready) return done(null);
        var svc = getDirectionsService();
        if (!svc) return done(null);

        var stops;
        try {
          stops = JSON.parse(stopsJson);
        } catch (e) {
          console.error('directionsRouteOptimized: bad stops payload', e);
          return done(null);
        }
        if (!stops || stops.length < 2) return done({ ok: false, status: 'TOO_FEW_STOPS' });

        var origin = stops[0];
        var destination = roundTrip ? stops[0] : stops[stops.length - 1];
        var middle = roundTrip ? stops.slice(1) : stops.slice(1, stops.length - 1);

        var req = {
          origin: origin,
          destination: destination,
          travelMode: google.maps.TravelMode.DRIVING,
          optimizeWaypoints: !!optimize,
          waypoints: middle.map(function (s) {
            return { location: s, stopover: true };
          })
        };
        var opts = drivingOptionsFor(departureEpochSec);
        if (opts) req.drivingOptions = opts;

        var attempt = 0;
        (function run() {
          svc.route(req, function (result, status) {
            if (status === 'OVER_QUERY_LIMIT' && attempt < 5) {
              attempt++;
              setTimeout(run, backoffMs(attempt));
              return;
            }
            if (status !== 'OK' || !result || !result.routes || !result.routes[0]) {
              console.warn('directionsRouteOptimized status:', status);
              return done({ ok: false, status: String(status) });
            }
            var route = result.routes[0];
            var legs = [];
            var totalDist = 0, totalDur = 0, totalTraffic = 0;
            for (var i = 0; i < route.legs.length; i++) {
              var summary = legSummary(route.legs[i]);
              totalDist += summary.distanceMeters;
              totalDur += summary.durationSeconds;
              totalTraffic += summary.durationInTrafficSeconds;
              legs.push(summary);
            }
            done({
              ok: true,
              status: 'OK',
              waypointOrder: route.waypoint_order || [],
              legs: legs,
              totalDistanceMeters: totalDist,
              totalDurationSeconds: totalDur,
              totalDurationInTrafficSeconds: totalTraffic
            });
          });
        })();
      });
    });
  };
})();
