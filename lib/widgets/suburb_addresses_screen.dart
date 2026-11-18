import 'package:clmschedule/utils/text_search.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../erf_property/adapters/erf_route_adapter.dart';
import '../erf_property/models/erf_property.dart';
import '../erf_property/providers/erf_property_provider.dart';
import '../erf_property/widgets/erf_paste_list_dialog.dart';
import '../models/address.dart';
import '../models/geocode_detail.dart';
import '../models/route_data.dart';
import '../services/address_service_v2.dart';
import '../services/geocoding_service.dart';
import '../services/route_export_service.dart';
import '../services/erf_import_service.dart';
import '../services/erf_parcel_store.dart';
import '../services/route_planner_service.dart';
import '../shareable_maps/adapters/firestore_adapter.dart';
import '../shareable_maps/providers/shareable_map_provider.dart';
import '../shareable_maps/services/map_link_service.dart';
import '../shareable_maps/services/shareable_maps_firestore_service.dart';
import '../shareable_maps/widgets/shareable_map_editor.dart';
import 'add_suburb_addresses_screen.dart';
import 'geocoded_addresses_map_viewer.dart';
import 'geocode/geocode_ui.dart';
import 'geocode/route_export_sheet.dart';
import '../utils/route_marker_icons.dart';
import 'geocode/route_options_sheet.dart';
import '../shareable_maps/providers/map_gesture_provider.dart';
import '../shareable_maps/widgets/map_overlay.dart';

/// Which slice of the address list is on screen.
enum _AddressFilter {
  all('All'),
  geocoded('Located'),
  pending('Pending'),
  review('Needs review'),
  failed('Failed');

  const _AddressFilter(this.label);
  final String label;
}

/// The geocoding + route planning workspace for one suburb.
///
/// Everything happens on this one surface: paste in addresses, geocode
/// them, watch them land on the map, optimise the drive order, nudge a
/// bad pin into place, then export the result.
///
/// Long operations report progress **inline** rather than behind a modal
/// barrier. That is deliberate: this screen is pushed onto a nested
/// Navigator, so a dialog opened with the default `useRootNavigator: true`
/// lands on a *different* navigator than the one `Navigator.pop(context)`
/// addresses — which is precisely how the old progress dialog ended up
/// spinning forever with nothing able to dismiss it.
class SuburbAddressesScreen extends riverpod.ConsumerStatefulWidget {
  final String suburb;

  const SuburbAddressesScreen({super.key, required this.suburb});

  @override
  riverpod.ConsumerState<SuburbAddressesScreen> createState() =>
      _SuburbAddressesScreenState();
}

class _SuburbAddressesScreenState extends riverpod
    .ConsumerState<SuburbAddressesScreen> with SingleTickerProviderStateMixin {
  final AddressServiceV2 _addressService =
      AddressServiceV2(FirebaseFirestore.instance);
  final GeocodingService _geocodingService = GeocodingService();
  final RoutePlannerService _planner = RoutePlannerService();
  final ErfParcelStore _parcelStore =
      ErfParcelStore(FirebaseFirestore.instance);
  final ScrollController _listScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  static final DateFormat _timeFormat = DateFormat('HH:mm');

  List<Address> _addresses = [];
  List<Address> _depots = [];
  PlannedRoute? _plan;

  /// Cadastral parcels behind the stops, keyed by [ErfProperty.id]. Empty
  /// for a list that came from plain geocoding.
  Map<String, ErfProperty> _parcels = {};

  /// True when the parcels were too large to store and live only for this
  /// session.
  bool _parcelsUnsaved = false;

  /// Set when stops are dragged into a new order: the geometry on screen
  /// no longer matches the list, so the roads need re-measuring.
  bool _planDirty = false;

  bool _isLoading = true;
  String? _errorMessage;

  // Inline progress state
  String? _progressMessage;
  String? _progressDetail;
  double? _progressFraction;
  VoidCallback? _onCancelProgress;

  GeocodeCancelToken? _geocodeCancel;
  RoutePlanCancelToken? _planCancel;

  String? _selectedId;
  String _search = '';
  _AddressFilter _filter = _AddressFilter.all;

  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  Set<Polygon> _parcelPolygons = {};
  MapType _mapType = MapType.normal;
  bool _showSummaryPanel = true;

  late final TabController _tabController =
      TabController(length: 2, vsync: this);

  RoutePlanOptions _planOptions = const RoutePlanOptions();

  @override
  void initState() {
    super.initState();
    _loadAddresses();
    _loadDepots();
  }

  @override
  void dispose() {
    _geocodeCancel?.cancel();
    _planCancel?.cancel();
    _tabController.dispose();
    _listScrollController.dispose();
    _searchController.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  // ── Data ───────────────────────────────────────────────────────────────

  Future<void> _loadAddresses() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final addresses = await _addressService.getAddresses(widget.suburb);
      final cached = await _addressService.getSuburbRouteData(widget.suburb);
      final parcels = addresses.any((a) => a.hasParcel)
          ? await _parcelStore.getParcels(widget.suburb)
          : <String, ErfProperty>{};
      if (!mounted) return;

      final restored = _restorePlan(addresses, cached);
      setState(() {
        _addresses = addresses;
        _parcels = parcels;
        _parcelsUnsaved = false;
        _plan = restored;
        _planDirty = false;
      });
      await _rebuildMapLayers();

      if (mounted && restored != null && restored.needsRemeasure) {
        showGeocodeSnack(
          context,
          'Saved delivery order restored — distances need re-measuring.',
          action: SnackBarAction(
            label: 'Re-measure',
            onPressed: _remeasureCurrentOrder,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Could not load addresses: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Rebuild the last planned run from the Firestore cache so reopening a
  /// suburb shows the route straight away, without another API call.
  /// Rebuild the last planned run so reopening a suburb shows the route
  /// straight away, without another API call — and, more importantly,
  /// without an optimise pass that would renumber the stops.
  ///
  /// The saved order lives on the addresses themselves as `routeIndex`, so
  /// it is restored even when the measured segments are missing or stale.
  /// Only the distances are lost in that case, and they can be refilled
  /// without touching the order.
  PlannedRoute? _restorePlan(List<Address> addresses, SuburbRouteData? cached) {
    final routed = addresses.where((a) => a.routeIndex != null).toList()
      ..sort((a, b) => a.routeIndex!.compareTo(b.routeIndex!));
    if (routed.length < 2) return null;

    return PlannedRoute.fromCache(
      routed,
      cached,
      depot: _planOptions.depot,
      serviceTimePerStop: _planOptions.serviceTimePerStop,
    );
  }

  Future<void> _loadDepots() async {
    final depots = await _addressService.getDepots();
    if (mounted) setState(() => _depots = depots);
  }

  int get _geocodedCount => _addresses.where((a) => a.isGeocoded).length;
  int get _pendingCount => _addresses.length - _geocodedCount;
  int get _failedCount =>
      _addresses.where((a) => !a.isGeocoded && a.geocodingError != null).length;
  int get _reviewCount =>
      _addresses.where((a) => a.isGeocoded && a.precision.needsReview).length;

  List<Address> get _visibleAddresses {
    final ordered = _plan?.orderedAddresses ?? _addresses;
    final search = TextSearch(_search);

    return ordered.where((a) {
      final matchesFilter = switch (_filter) {
        _AddressFilter.all => true,
        _AddressFilter.geocoded => a.isGeocoded,
        _AddressFilter.pending => !a.isGeocoded,
        _AddressFilter.review => a.isGeocoded && a.precision.needsReview,
        _AddressFilter.failed => !a.isGeocoded && a.geocodingError != null,
      };
      if (!matchesFilter) return false;
      return search.matches([a.fullAddress, a.notes]);
    }).toList();
  }

  // ── Progress plumbing ──────────────────────────────────────────────────

  void _setProgress({
    required String message,
    String? detail,
    double? fraction,
    VoidCallback? onCancel,
  }) {
    if (!mounted) return;
    setState(() {
      _progressMessage = message;
      _progressDetail = detail;
      _progressFraction = fraction;
      _onCancelProgress = onCancel;
    });
  }

  void _clearProgress() {
    if (!mounted) return;
    setState(() {
      _progressMessage = null;
      _progressDetail = null;
      _progressFraction = null;
      _onCancelProgress = null;
    });
  }

  bool get _isBusy => _progressMessage != null;

  // ── Geocoding ──────────────────────────────────────────────────────────

  /// Geocode every address that has no coordinates yet — or all of them
  /// when [redoAll] is set, which is how a corrected address list gets
  /// re-resolved.
  Future<void> _geocode({bool redoAll = false}) async {
    if (_isBusy) return;

    final targets = <int>[
      for (var i = 0; i < _addresses.length; i++)
        if (redoAll || !_addresses[i].isGeocoded) i,
    ];

    if (targets.isEmpty) {
      showGeocodeSnack(context, 'Everything here is already located.');
      return;
    }

    final cancel = GeocodeCancelToken();
    _geocodeCancel = cancel;
    _setProgress(
      message: 'Locating ${targets.length} address'
          '${targets.length == 1 ? '' : 'es'}…',
      fraction: 0,
      onCancel: () {
        cancel.cancel();
        _setProgress(message: 'Finishing the addresses already in flight…');
      },
    );

    try {
      if (redoAll) GeocodingService.clearCache();

      final entries = await _geocodingService.batchGeocodeDetailed(
        [for (final i in targets) _addresses[i].fullAddress],
        cancelToken: cancel,
        onProgress: (p) => _setProgress(
          message: 'Locating ${targets.length} address'
              '${targets.length == 1 ? '' : 'es'}…',
          detail: '${p.completed} of ${p.total} · '
              '${p.succeeded} found · ${p.failed} not found',
          fraction: p.fraction,
          onCancel: _onCancelProgress,
        ),
      );

      final updated = List<Address>.from(_addresses);
      var found = 0;
      var missed = 0;
      for (final entry in entries) {
        final target = targets[entry.index];
        if (entry.error == 'Cancelled') continue;
        if (entry.detail != null) {
          updated[target] = updated[target].withGeocode(entry.detail!);
          found++;
        } else {
          updated[target] =
              updated[target].withGeocodeFailure(entry.error ?? 'No match');
          missed++;
        }
      }

      _setProgress(message: 'Saving results…');
      await _addressService.batchUpdateAddresses(widget.suburb, updated);

      if (!mounted) return;
      setState(() {
        _addresses = updated;
        _plan = null;
        _planDirty = false;
      });
      await _rebuildMapLayers();
      _fitBounds();

      if (!mounted) return;
      final review =
          updated.where((a) => a.isGeocoded && a.precision.needsReview).length;
      showGeocodeSnack(
        context,
        cancel.isCancelled
            ? 'Stopped — $found located before cancelling.'
            : '$found located'
                '${missed > 0 ? ', $missed not found' : ''}'
                '${review > 0 ? ' · $review need a look' : ''}.',
        action: review > 0
            ? SnackBarAction(
                label: 'Review',
                onPressed: () =>
                    setState(() => _filter = _AddressFilter.review),
              )
            : null,
      );
    } catch (e) {
      if (mounted) {
        showGeocodeSnack(context, 'Geocoding failed: $e', isError: true);
      }
    } finally {
      _geocodeCancel = null;
      _clearProgress();
    }
  }

  /// Re-run a single address, e.g. after fixing its spelling.
  Future<void> _geocodeOne(Address address) async {
    final index = _addresses.indexWhere((a) => a.id == address.id);
    if (index < 0) return;

    setState(() => _selectedId = address.id);
    final detail = await _geocodingService.geocodeDetailed(address.fullAddress);

    final updated = detail == null
        ? address.withGeocodeFailure('No match found')
        : address.withGeocode(detail);

    await _addressService.updateAddress(widget.suburb, index, updated);
    if (!mounted) return;

    setState(() => _addresses[index] = updated);
    await _rebuildMapLayers();

    if (!mounted) return;
    if (detail == null) {
      showGeocodeSnack(context, 'No match for ${address.displayName}',
          isError: true);
    } else {
      _focusOn(updated);
      showGeocodeSnack(context,
          '${address.displayName} → ${detail.precision.label.toLowerCase()}');
    }
  }

  // ── Route planning ─────────────────────────────────────────────────────

  Future<void> _optimiseRoute() async {
    if (_isBusy) return;

    final routable = _addresses.where((a) => a.isGeocoded).toList();
    if (routable.length < 2) {
      showGeocodeSnack(
        context,
        'Locate at least two addresses before planning a route.',
        isError: true,
      );
      return;
    }

    // Re-optimising renumbers every stop. Once a run has been planned and
    // saved, that order may already be on a driver's sheet, so it is not
    // something to change by accident.
    if (_plan != null && !await _confirmReorder()) return;
    if (!mounted) return;

    final options = await RouteOptionsSheet.show(
      context,
      initial: _planOptions,
      stopCount: routable.length,
      depots: _depots,
      onCreateDepot: _createDepot,
    );
    if (options == null || !mounted) return;

    setState(() => _planOptions = options);
    await _runPlan(routable, options);
  }

  /// Ask before an optimise pass renumbers a saved run.
  ///
  /// Offers re-measuring instead, which refreshes distances and ETAs
  /// against the roads while leaving the delivery order exactly as it is.
  Future<bool> _confirmReorder() async {
    final plan = _plan!;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Change the delivery order?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This suburb already has a saved run of '
              '${plan.deliveryStops.length} stops, planned '
              '${_formatWhen(plan.plannedAt)}.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Optimising again will renumber every stop. If that order is '
              'already out with a driver, re-measure instead — it refreshes '
              'the distances and ETAs without moving anything.',
              style: TextStyle(fontSize: 12.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('cancel'),
            child: const Text('Keep it as is'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('remeasure'),
            child: const Text('Re-measure only'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: GeocodeColors.warning),
            onPressed: () => Navigator.of(dialogContext).pop('reorder'),
            child: const Text('Reorder anyway'),
          ),
        ],
      ),
    );

    if (choice == 'remeasure') {
      await _remeasureCurrentOrder();
      return false;
    }
    return choice == 'reorder';
  }

  String _formatWhen(DateTime when) {
    final days = DateTime.now().difference(when).inDays;
    if (days == 0) return 'today';
    if (days == 1) return 'yesterday';
    if (days < 7) return '$days days ago';
    return 'on ${when.day}/${when.month}/${when.year}';
  }

  /// Re-measure the roads for the current list order, keeping it exactly
  /// as arranged — used after a manual drag.
  Future<void> _remeasureCurrentOrder() async {
    final ordered = _plan?.orderedAddresses.where((a) => a.isGeocoded).toList();
    if (ordered == null || ordered.length < 2) return;

    await _runPlan(
      // The depot already leads the planned list; feeding it back in as a
      // depot too would duplicate the stop.
      ordered.where((a) => a.id != _planOptions.depot?.id).toList(),
      _planOptions.copyWith(algorithm: RouteAlgorithm.keepOrder),
      keepAlgorithmPreference: true,
    );
  }

  Future<void> _runPlan(
    List<Address> stops,
    RoutePlanOptions options, {
    bool keepAlgorithmPreference = false,
  }) async {
    final cancel = RoutePlanCancelToken();
    _planCancel = cancel;
    _setProgress(
      message: 'Planning ${stops.length} stops…',
      onCancel: () {
        cancel.cancel();
        _setProgress(message: 'Cancelling…');
      },
    );

    try {
      final plan = await _planner.plan(
        stops,
        options: options,
        cancelToken: cancel,
        onProgress: (p) => _setProgress(
          message: p.stage,
          detail: p.total > 0 ? 'Batch ${p.completed} of ${p.total}' : null,
          fraction: p.fraction,
          onCancel: _onCancelProgress,
        ),
      );

      if (!mounted) return;
      setState(() {
        _plan = plan;
        _planDirty = false;
        if (!keepAlgorithmPreference) _planOptions = options;
      });

      _setProgress(message: 'Saving the route…');
      await _persistPlan(plan);

      await _rebuildMapLayers();
      _fitBounds();

      if (!mounted) return;
      if (plan.warning != null) {
        showGeocodeSnack(context, plan.warning!, isError: true);
      } else {
        showGeocodeSnack(
          context,
          'Route ready · ${plan.totalDistanceFormatted} · '
          '${plan.totalDrivingFormatted} driving',
          action: SnackBarAction(
            label: 'Export',
            onPressed: _openExportSheet,
          ),
        );
      }
    } on RoutePlanCancelled {
      if (mounted) showGeocodeSnack(context, 'Route planning cancelled.');
    } catch (e) {
      if (mounted) {
        showGeocodeSnack(context, 'Could not plan the route: $e',
            isError: true);
      }
    } finally {
      _planCancel = null;
      _clearProgress();
    }
  }

  /// Write the stop order back onto the addresses and cache the segments,
  /// so the run survives a reload.
  ///
  /// The depot is filtered out first: it lives in its own document and is
  /// not one of this suburb's addresses.
  Future<void> _persistPlan(PlannedRoute plan) async {
    try {
      final ordered = plan.orderedAddresses
          .where((a) => _addresses.any((x) => x.id == a.id))
          .toList();

      await _addressService.saveOptimizedRoute(widget.suburb, ordered);
      await _addressService
          .saveSuburbRouteData(plan.toSuburbRouteData(widget.suburb));
    } catch (e) {
      debugPrint('Could not cache the route: $e');
    }
  }

  void _openExportSheet() {
    final plan = _plan;
    if (plan == null) {
      showGeocodeSnack(context, 'Optimise a route first.', isError: true);
      return;
    }
    RouteExportSheet.show(
      context,
      route: plan,
      baseName: widget.suburb,
      parcels: {
        for (final entry in _parcels.entries)
          entry.key: RouteParcel(
            id: entry.value.id,
            label: entry.value.displayLabel,
            boundary: entry.value.polygon,
            areaSquareMetres: entry.value.area,
          ),
      },
      onOpenClientMap: _openAsClientMap,
    );
  }

  /// Open the read-only view meant for the driver: every stop in order
  /// with its leg, ETA and a navigation link.
  void _openItinerary() {
    final plan = _plan;
    if (plan == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GeocodedAddressesMapViewer(
          route: plan,
          title: widget.suburb.toUpperCase(),
        ),
      ),
    );
  }

  // ── Editing ────────────────────────────────────────────────────────────

  Future<Address?> _createDepot() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => _DepotDialog(defaultCity: _guessCity()),
    );
    if (result == null || !mounted) return null;

    _setProgress(message: 'Locating the depot…');
    try {
      final query = result['address']!;
      final detail = await _geocodingService.geocodeDetailed(query);
      if (detail == null) {
        if (mounted) {
          showGeocodeSnack(context, 'Could not locate that depot address.',
              isError: true);
        }
        return null;
      }

      final depot = Address(
        id: 'depot-${DateTime.now().millisecondsSinceEpoch}',
        streetAddress: result['name']!.isEmpty ? query : result['name']!,
        suburb: '',
        city: '',
        postalCode: '',
        province: '',
        country: '',
      ).withGeocode(detail);

      await _addressService.saveDepot(depot);
      if (mounted) setState(() => _depots = [..._depots, depot]);
      return depot;
    } finally {
      _clearProgress();
    }
  }

  String _guessCity() {
    for (final a in _addresses) {
      if (a.city.isNotEmpty) return a.city;
    }
    return 'Cape Town';
  }

  Future<void> _editAddress(Address address) async {
    final index = _addresses.indexWhere((a) => a.id == address.id);
    if (index < 0) return;

    final updated = await showDialog<Address>(
      context: context,
      builder: (dialogContext) => _EditAddressDialog(address: address),
    );
    if (updated == null || !mounted) return;

    // Any text change invalidates the coordinates that came from the old
    // text, so the pin is dropped rather than left pointing at the wrong
    // place.
    final textChanged = updated.fullAddress != address.fullAddress;
    final toSave = textChanged
        ? updated.copyWith(
            isGeocoded: false,
            latitude: null,
            longitude: null,
            geocodingError: null,
            formattedAddress: null,
            locationType: null,
            partialMatch: false,
            placeId: null,
          )
        : updated;

    await _addressService.updateAddress(widget.suburb, index, toSave);
    if (!mounted) return;
    setState(() {
      _addresses[index] = toSave;
      if (textChanged) {
        _plan = null;
        _planDirty = false;
      }
    });
    await _rebuildMapLayers();

    if (textChanged && mounted) {
      showGeocodeSnack(
        context,
        'Address changed — it needs locating again.',
        action: SnackBarAction(
          label: 'Locate now',
          onPressed: () => _geocodeOne(toSave),
        ),
      );
    }
  }

  /// Persist a pin the user dragged into place.
  Future<void> _moveAddress(Address address, LatLng position) async {
    final index = _addresses.indexWhere((a) => a.id == address.id);
    if (index < 0) return;

    final updated = address.copyWith(
      latitude: position.latitude,
      longitude: position.longitude,
      isGeocoded: true,
      geocodingError: null,
      locationType: GeocodePrecision.manualLocationType,
      partialMatch: false,
    );

    await _addressService.updateAddress(widget.suburb, index, updated);
    if (!mounted) return;
    setState(() {
      _addresses[index] = updated;
      // The road geometry was measured against the old position.
      if (_plan != null) _planDirty = true;
    });
    await _rebuildMapLayers();
    if (mounted) {
      showGeocodeSnack(context, 'Pin moved for ${address.displayName}.');
    }
  }

  Future<void> _deleteAddress(Address address) async {
    final index = _addresses.indexWhere((a) => a.id == address.id);
    if (index < 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this address?'),
        content: Text(address.fullAddress),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: GeocodeColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _addressService.deleteAddress(widget.suburb, index);
    await _loadAddresses();
  }

  Future<void> _cleanUp(String action) async {
    if (_isBusy) return;
    _setProgress(message: 'Tidying the list…');
    try {
      final removed = action == 'dedupe'
          ? await _addressService.deduplicate(widget.suburb)
          : await _addressService.deleteUngeocoded(widget.suburb);
      await _loadAddresses();
      if (!mounted) return;
      showGeocodeSnack(
        context,
        removed == 0
            ? 'Nothing to remove.'
            : 'Removed $removed address${removed == 1 ? '' : 'es'}.',
      );
    } catch (e) {
      if (mounted) showGeocodeSnack(context, 'Failed: $e', isError: true);
    } finally {
      _clearProgress();
    }
  }

  // ── Map ────────────────────────────────────────────────────────────────

  Future<void> _rebuildMapLayers() async {
    final plan = _plan;
    final markers = <Marker>{};

    if (plan != null) {
      final stops = plan.stops;
      for (var i = 0; i < stops.length; i++) {
        final stop = stops[i];
        final address = stop.address;
        if (address.latitude == null || address.longitude == null) continue;

        final selected = _selectedId == address.id;
        final icon = await RouteMarkerIcons.numbered(
          stop.isDepot ? 'S' : '${stop.sequence}',
          color: stop.isDepot
              ? GeocodeColors.depot
              : RouteMarkerIcons.colorForPosition(i, stops.length),
          highlighted: selected,
        );

        markers.add(_buildMarker(
          address: address,
          icon: icon,
          title: stop.isDepot
              ? 'Start · ${address.displayName}'
              : '${stop.sequence}. ${address.displayName}',
          snippet: [
            if (!stop.isDepot)
              '${stop.legDistanceKm.toStringAsFixed(1)} km · '
                  '${stop.legDurationFormatted}',
            if (stop.arrival != null)
              'ETA ${_timeFormat.format(stop.arrival!)}',
          ].join(' · '),
        ));
      }
    } else {
      for (final address in _addresses) {
        if (!address.isGeocoded ||
            address.latitude == null ||
            address.longitude == null) {
          continue;
        }
        final icon = await RouteMarkerIcons.dot(
          color: GeocodeColors.forPrecision(address.precision),
          highlighted: _selectedId == address.id,
        );
        markers.add(_buildMarker(
          address: address,
          icon: icon,
          title: address.displayName,
          snippet: '${address.precision.label} · drag to correct',
        ));
      }
    }

    final polylines = <Polyline>{};
    if (plan != null) {
      for (var i = 1; i < plan.stops.length; i++) {
        final stop = plan.stops[i];
        if (stop.pathFromPrevious.length < 2) continue;
        polylines.add(Polyline(
          polylineId: PolylineId('leg_$i'),
          points: stop.pathFromPrevious,
          color: RouteMarkerIcons.colorForPosition(i, plan.stops.length)
              .withValues(alpha: 0.9),
          width: 5,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ));
      }
      final back = plan.returnLeg;
      if (back != null && back.pathFromPrevious.length >= 2) {
        polylines.add(Polyline(
          polylineId: const PolylineId('leg_return'),
          points: back.pathFromPrevious,
          color: GeocodeColors.neutral,
          width: 4,
          patterns: [PatternItem.dash(24), PatternItem.gap(14)],
        ));
      }
    }

    // Parcel boundaries, tinted along the run so the map reads in drive
    // order even before the numbers are legible at low zoom.
    final polygons = <Polygon>{};
    if (_parcels.isNotEmpty) {
      final orderOf = <String, int>{};
      final stops = plan?.stops ?? const <PlannedStop>[];
      for (var i = 0; i < stops.length; i++) {
        final erfId = stops[i].address.erfId;
        if (erfId != null) orderOf[erfId] = i;
      }

      for (final address in _addresses) {
        final parcel = _parcels[address.erfId];
        if (parcel == null || parcel.polygon.length < 3) continue;

        final index = orderOf[parcel.id];
        final color = index == null
            ? GeocodeColors.neutral
            : RouteMarkerIcons.colorForPosition(index, stops.length);

        polygons.add(Polygon(
          polygonId: PolygonId('parcel_${parcel.id}'),
          points: parcel.polygon,
          strokeColor: color,
          strokeWidth: 2,
          fillColor: color.withValues(alpha: 0.22),
          consumeTapEvents: true,
          onTap: () => _selectFromMap(address),
        ));
      }
    }

    if (!mounted) return;
    // Markers, polylines and polygons are set together, so a mismatch in
    // these counts on screen (route drawn, pins missing) points at the
    // renderer rather than at this build.
    debugPrint('[Geocode map] ${markers.length} markers, '
        '${polylines.length} legs, ${polygons.length} parcels'
        '${RouteMarkerIcons.encodeFailures > 0 ? ' — '
            '${RouteMarkerIcons.encodeFailures} pin bitmaps failed to '
            'encode and fell back to plain pins' : ''}');
    setState(() {
      _markers = markers;
      _polylines = polylines;
      _parcelPolygons = polygons;
    });
  }

  Marker _buildMarker({
    required Address address,
    required BitmapDescriptor icon,
    required String title,
    required String snippet,
  }) {
    return Marker(
      markerId: MarkerId(address.id),
      position: LatLng(address.latitude!, address.longitude!),
      icon: icon,
      anchor: const Offset(0.5, 1),
      draggable: true,
      onDragEnd: (position) => _moveAddress(address, position),
      infoWindow: InfoWindow(title: title, snippet: snippet),
      onTap: () => _selectFromMap(address),
    );
  }

  /// A pin or parcel was clicked. Google reports clicks that landed on a
  /// panel or dialog over the map too; a held map means it was one of those.
  void _selectFromMap(Address address) {
    if (ref.read(mapGestureRiverpod).isHeld) return;
    _select(address, focusList: true);
  }

  void _select(Address address, {bool focusList = false}) {
    setState(() => _selectedId = address.id);
    _rebuildMapLayers();
    if (focusList) _scrollListTo(address);
  }

  void _scrollListTo(Address address) {
    final index = _visibleAddresses.indexWhere((a) => a.id == address.id);
    if (index < 0 || !_listScrollController.hasClients) return;
    const estimatedTileHeight = 84.0;
    _listScrollController.animateTo(
      (index * estimatedTileHeight)
          .clamp(0, _listScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _focusOn(Address address) {
    if (address.latitude == null || address.longitude == null) return;
    _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(address.latitude!, address.longitude!),
        17,
      ),
    );
  }

  void _fitBounds() {
    final points = <LatLng>[
      for (final a in (_plan?.orderedAddresses ?? _addresses))
        if (a.latitude != null && a.longitude != null)
          LatLng(a.latitude!, a.longitude!),
    ];
    if (points.isEmpty || _mapController == null) return;

    if (points.length == 1) {
      _mapController!
          .animateCamera(CameraUpdate.newLatLngZoom(points.first, 16));
      return;
    }

    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;
    for (final p in points) {
      minLat = p.latitude < minLat ? p.latitude : minLat;
      maxLat = p.latitude > maxLat ? p.latitude : maxLat;
      minLng = p.longitude < minLng ? p.longitude : minLng;
      maxLng = p.longitude > maxLng ? p.longitude : maxLng;
    }

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        60,
      ),
    );
  }

  LatLng _initialCenter() {
    for (final a in _addresses) {
      if (a.latitude != null && a.longitude != null) {
        return LatLng(a.latitude!, a.longitude!);
      }
    }
    return const LatLng(-33.9249, 18.4241); // Cape Town
  }

  // ── Reordering ─────────────────────────────────────────────────────────

  void _reorderStops(int oldIndex, int newIndex) {
    final plan = _plan;
    if (plan == null) return;
    if (_filter != _AddressFilter.all || _search.isNotEmpty) return;

    // `onReorderItem` already accounts for the removed item, so newIndex
    // is used as given.
    final ordered = List<Address>.from(plan.orderedAddresses);
    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex, moved);

    // Rebuild a provisional plan so the list renumbers immediately; the
    // distances stay stale until the roads are re-measured.
    setState(() {
      _plan = PlannedRoute(
        stops: [
          for (var i = 0; i < ordered.length; i++)
            PlannedStop(
              address: ordered[i],
              sequence:
                  plan.stops.isNotEmpty && plan.stops.first.isDepot ? i : i + 1,
              isDepot: i == 0 &&
                  plan.stops.isNotEmpty &&
                  plan.stops.first.isDepot &&
                  ordered[i].id == plan.stops.first.address.id,
              legDistanceMeters: 0,
              legDurationSeconds: 0,
              legDurationInTrafficSeconds: 0,
              pathFromPrevious: const [],
              cumulativeDistanceMeters: 0,
              cumulativeDrivingSeconds: 0,
            ),
        ],
        totalDistanceMeters: plan.totalDistanceMeters,
        totalDrivingSeconds: plan.totalDrivingSeconds,
        totalServiceSeconds: plan.totalServiceSeconds,
        usedRealRoads: plan.usedRealRoads,
        algorithm: RouteAlgorithm.keepOrder,
        options: plan.options,
        plannedAt: plan.plannedAt,
      );
      _planDirty = true;
    });
    _rebuildMapLayers();
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.suburb.toUpperCase()),
            Text(
              '${_addresses.length} addresses'
              '${_plan != null ? ' · route planned' : ''}',
              style:
                  const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search the ERF register and import parcels',
            icon: const Icon(Icons.travel_explore_rounded),
            onPressed: _isBusy ? null : _importErfList,
          ),
          IconButton(
            tooltip: 'Add more addresses',
            icon: const Icon(Icons.playlist_add_rounded),
            onPressed: _isBusy ? null : _openImport,
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _isBusy ? null : _loadAddresses,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) {
              switch (value) {
                case 'regeocode':
                  _geocode(redoAll: true);
                case 'dedupe':
                  _cleanUp('dedupe');
                case 'clear_pending':
                  _cleanUp('clear_pending');
                case 'copy_list':
                  _copyAddressList();
                case 'fit':
                  _fitBounds();
                case 'itinerary':
                  _openItinerary();
                case 'client_map':
                  _openAsClientMap();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'regeocode',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.refresh),
                  title: Text('Re-locate everything'),
                  subtitle: Text('Ignores cached results'),
                ),
              ),
              PopupMenuItem(
                value: 'dedupe',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.filter_alt_off_outlined),
                  title: Text('Remove duplicates'),
                ),
              ),
              PopupMenuItem(
                value: 'clear_pending',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.delete_sweep_outlined),
                  title: Text('Remove un-located addresses'),
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'copy_list',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.copy_all_outlined),
                  title: Text('Copy address list'),
                ),
              ),
              PopupMenuItem(
                value: 'fit',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.zoom_out_map),
                  title: Text('Fit map to stops'),
                ),
              ),
              PopupMenuItem(
                value: 'itinerary',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.assignment_rounded),
                  title: Text('Driver itinerary'),
                ),
              ),
              PopupMenuItem(
                value: 'client_map',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.share_location_rounded),
                  title: Text('Open as client map'),
                  subtitle: Text('Parcels, numbered stops and the route'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: _buildActionBar(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return GeocodeEmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Could not load this suburb',
        message: _errorMessage,
        action: FilledButton.icon(
          onPressed: _loadAddresses,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      );
    }

    if (_addresses.isEmpty) {
      return GeocodeEmptyState(
        icon: Icons.playlist_add_rounded,
        title: 'No addresses here yet',
        message: 'Paste a list of delivery addresses and they will be located, '
            'ordered into a route and exported for the driver.',
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: _importErfList,
              icon: const Icon(Icons.travel_explore_rounded),
              label: const Text('Paste ERFs / addresses'),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _openImport,
              icon: const Icon(Icons.add),
              label: const Text('Addresses only'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildStatStrip(),
        if (_progressMessage != null)
          InlineProgressBar(
            message: _progressMessage!,
            detail: _progressDetail,
            fraction: _progressFraction,
            onCancel: _onCancelProgress,
          ),
        if (_planDirty || (_plan?.needsRemeasure ?? false)) _buildStaleBanner(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 940) {
                return Row(
                  children: [
                    SizedBox(width: 430, child: _buildListPane()),
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildMapPane()),
                  ],
                );
              }
              return Column(
                children: [
                  TabBar(
                    controller: _tabController,
                    tabs: const [
                      Tab(icon: Icon(Icons.list_alt_rounded), text: 'Stops'),
                      Tab(icon: Icon(Icons.map_rounded), text: 'Map'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [_buildListPane(), _buildMapPane()],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStatStrip() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.35),
        border:
            Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            StatPill(
              label: 'total',
              value: '${_addresses.length}',
              color: GeocodeColors.neutral,
              icon: Icons.format_list_numbered_rounded,
              selected: _filter == _AddressFilter.all,
              onTap: () => setState(() => _filter = _AddressFilter.all),
            ),
            const SizedBox(width: 8),
            StatPill(
              label: 'located',
              value: '$_geocodedCount',
              color: GeocodeColors.success,
              icon: Icons.place_rounded,
              selected: _filter == _AddressFilter.geocoded,
              onTap: () => setState(() => _filter = _AddressFilter.geocoded),
            ),
            if (_pendingCount > 0) ...[
              const SizedBox(width: 8),
              StatPill(
                label: 'pending',
                value: '$_pendingCount',
                color: GeocodeColors.warning,
                icon: Icons.hourglass_empty_rounded,
                selected: _filter == _AddressFilter.pending,
                onTap: () => setState(() => _filter = _AddressFilter.pending),
              ),
            ],
            if (_reviewCount > 0) ...[
              const SizedBox(width: 8),
              StatPill(
                label: 'to check',
                value: '$_reviewCount',
                color: GeocodeColors.danger,
                icon: Icons.help_outline_rounded,
                selected: _filter == _AddressFilter.review,
                onTap: () => setState(() => _filter = _AddressFilter.review),
              ),
            ],
            if (_failedCount > 0) ...[
              const SizedBox(width: 8),
              StatPill(
                label: 'failed',
                value: '$_failedCount',
                color: GeocodeColors.danger,
                icon: Icons.error_outline_rounded,
                selected: _filter == _AddressFilter.failed,
                onTap: () => setState(() => _filter = _AddressFilter.failed),
              ),
            ],
            if (_parcels.isNotEmpty) ...[
              const SizedBox(width: 8),
              StatPill(
                label: _parcelsUnsaved ? 'parcels (unsaved)' : 'parcels',
                value: '${_parcels.length}',
                color: _parcelsUnsaved
                    ? GeocodeColors.warning
                    : GeocodeColors.depot,
                icon: Icons.crop_square_rounded,
              ),
            ],
            if (_plan != null) ...[
              const SizedBox(width: 16),
              Container(
                  width: 1, height: 26, color: Theme.of(context).dividerColor),
              const SizedBox(width: 16),
              // A restored order has no measurements yet; showing "0.0 km"
              // would read as a fact rather than as missing data.
              if (_plan!.needsRemeasure)
                StatPill(
                  label: 'not measured',
                  value: '—',
                  color: GeocodeColors.warning,
                  icon: Icons.straighten_rounded,
                )
              else ...[
                StatPill(
                  label: 'route',
                  value: _plan!.totalDistanceFormatted,
                  color: GeocodeColors.brand,
                  icon: Icons.straighten_rounded,
                ),
                const SizedBox(width: 8),
                StatPill(
                  label: 'driving',
                  value: _plan!.totalDrivingFormatted,
                  color: GeocodeColors.brand,
                  icon: Icons.directions_car_rounded,
                ),
                const SizedBox(width: 8),
                StatPill(
                  label: 'on the road',
                  value: _plan!.totalElapsedFormatted,
                  color: GeocodeColors.depot,
                  icon: Icons.schedule_rounded,
                ),
                if (_plan!.finishTime != null) ...[
                  const SizedBox(width: 8),
                  StatPill(
                    label: 'back by',
                    value: _timeFormat.format(_plan!.finishTime!),
                    color: GeocodeColors.depot,
                    icon: Icons.flag_rounded,
                  ),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStaleBanner() {
    final restoredWithoutLegs = !_planDirty && (_plan?.needsRemeasure ?? false);

    return Material(
      color: GeocodeColors.warning.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              restoredWithoutLegs
                  ? Icons.bookmark_added_rounded
                  : Icons.edit_road_rounded,
              size: 18,
              color: GeocodeColors.warning,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                restoredWithoutLegs
                    ? 'Saved delivery order restored. Distances and ETAs need '
                        're-measuring — the order will not change.'
                    : 'Stops moved — distances and ETAs are from the previous '
                        'order.',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            TextButton.icon(
              onPressed: _isBusy ? null : _remeasureCurrentOrder,
              icon: const Icon(Icons.straighten_rounded, size: 16),
              label: const Text('Re-measure'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildListPane() {
    final visible = _visibleAddresses;
    final canReorder =
        _plan != null && _filter == _AddressFilter.all && _search.isEmpty;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _search = value),
            decoration: InputDecoration(
              hintText: 'Search this suburb…',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              suffixIcon: _search.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _search = '');
                      },
                    ),
            ),
          ),
        ),
        if (canReorder)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(Icons.drag_indicator_rounded,
                    size: 14, color: Theme.of(context).hintColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Drag a stop to change the drive order.',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: visible.isEmpty
              ? GeocodeEmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'Nothing matches',
                  message: 'Try a different filter or search term.',
                  action: TextButton(
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _search = '';
                        _filter = _AddressFilter.all;
                      });
                    },
                    child: const Text('Clear filters'),
                  ),
                )
              : canReorder
                  ? ReorderableListView.builder(
                      scrollController: _listScrollController,
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
                      itemCount: visible.length,
                      onReorderItem: _reorderStops,
                      buildDefaultDragHandles: false,
                      itemBuilder: (context, index) =>
                          ReorderableDragStartListener(
                        key: ValueKey(visible[index].id),
                        index: index,
                        child: _buildAddressTile(visible[index], index),
                      ),
                    )
                  : ListView.builder(
                      controller: _listScrollController,
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
                      itemCount: visible.length,
                      itemBuilder: (context, index) =>
                          _buildAddressTile(visible[index], index),
                    ),
        ),
      ],
    );
  }

  Widget _buildAddressTile(Address address, int index) {
    final selected = _selectedId == address.id;
    final stop =
        _plan?.stops.where((s) => s.address.id == address.id).firstOrNull;
    final hasStop = stop != null;

    // Colour by the stop's real position in the run, not its position in
    // the (possibly filtered) list on screen, so the badge always matches
    // the pin on the map.
    final planIndex = hasStop
        ? _plan!.stops.indexWhere((s) => s.address.id == address.id)
        : -1;
    final badgeColor = hasStop
        ? (stop.isDepot
            ? GeocodeColors.depot
            : RouteMarkerIcons.colorForPosition(planIndex, _plan!.stops.length))
        : GeocodeColors.forPrecision(address.precision);

    return Padding(
      key: ValueKey('tile-${address.id}'),
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: Material(
        color: selected
            ? GeocodeColors.brand.withValues(alpha: 0.08)
            : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            _select(address);
            if (address.isGeocoded) {
              _focusOn(address);
              if (_tabController.length == 2 &&
                  MediaQuery.sizeOf(context).width < 940) {
                _tabController.animateTo(1);
              }
            }
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? GeocodeColors.brand
                    : Theme.of(context).dividerColor,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SequenceBadge(
                  label: hasStop
                      ? (stop.isDepot ? 'S' : '${stop.sequence}')
                      : (address.isGeocoded ? '•' : '?'),
                  color: badgeColor,
                  selected: selected,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        address.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [address.suburb, address.city, address.postalCode]
                            .where((p) => p.isNotEmpty)
                            .join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (address.isGeocoded)
                            PrecisionChip(precision: address.precision),
                          if (!address.isGeocoded)
                            _miniChip(
                              address.geocodingError ?? 'Not located',
                              GeocodeColors.warning,
                              Icons.location_off_rounded,
                            ),
                          if (hasStop && !stop.isDepot && !_planDirty) ...[
                            _miniChip(
                              '${stop.legDistanceKm.toStringAsFixed(1)} km',
                              GeocodeColors.brand,
                              Icons.straighten_rounded,
                            ),
                            if (stop.arrival != null)
                              _miniChip(
                                _timeFormat.format(stop.arrival!),
                                GeocodeColors.depot,
                                Icons.schedule_rounded,
                              ),
                          ],
                          if (address.notes?.isNotEmpty ?? false)
                            _miniChip(
                              address.notes!,
                              GeocodeColors.neutral,
                              Icons.sticky_note_2_outlined,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                _buildTileMenu(address),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _miniChip(String label, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTileMenu(Address address) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      tooltip: 'Actions',
      onSelected: (value) {
        switch (value) {
          case 'locate':
            _geocodeOne(address);
          case 'edit':
            _editAddress(address);
          case 'maps':
            launchUrl(
              Uri.parse(RouteExportService.mapsPinUrl(address)),
              mode: LaunchMode.externalApplication,
            );
          case 'copy':
            Clipboard.setData(ClipboardData(
              text: address.latitude == null
                  ? address.fullAddress
                  : '${address.latitude},${address.longitude}',
            ));
            showGeocodeSnack(context, 'Copied to the clipboard.');
          case 'delete':
            _deleteAddress(address);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'locate',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.my_location_rounded, size: 20),
            title: Text(address.isGeocoded ? 'Locate again' : 'Locate'),
          ),
        ),
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined, size: 20),
            title: Text('Edit address'),
          ),
        ),
        const PopupMenuItem(
          value: 'maps',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.open_in_new_rounded, size: 20),
            title: Text('Open in Google Maps'),
          ),
        ),
        const PopupMenuItem(
          value: 'copy',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.copy_rounded, size: 20),
            title: Text('Copy coordinates'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline_rounded,
                size: 20, color: GeocodeColors.danger),
            title:
                Text('Remove', style: TextStyle(color: GeocodeColors.danger)),
          ),
        ),
      ],
    );
  }

  Widget _buildMapPane() {
    return Stack(
      children: [
        GoogleMap(
          webGestureHandling: ref.watch(mapGestureRiverpod).gestureHandling,
          initialCameraPosition:
              CameraPosition(target: _initialCenter(), zoom: 13),
          markers: _markers,
          polylines: _polylines,
          polygons: _parcelPolygons,
          mapType: _mapType,
          zoomControlsEnabled: true,
          mapToolbarEnabled: false,
          myLocationButtonEnabled: false,
          onMapCreated: (controller) {
            _mapController = controller;
            // Give the map a beat to lay out before framing the stops.
            Future.delayed(const Duration(milliseconds: 400), _fitBounds);
          },
        ),
        Positioned(
          top: 12,
          right: 12,
          child: MapOverlay(
            child: Column(
              children: [
                _mapButton(
                  icon: _mapType == MapType.normal
                      ? Icons.satellite_alt_rounded
                      : Icons.map_rounded,
                  tooltip: _mapType == MapType.normal
                      ? 'Satellite view'
                      : 'Map view',
                  onPressed: () => setState(() {
                    _mapType = _mapType == MapType.normal
                        ? MapType.hybrid
                        : MapType.normal;
                  }),
                ),
                const SizedBox(height: 8),
                _mapButton(
                  icon: Icons.zoom_out_map_rounded,
                  tooltip: 'Fit all stops',
                  onPressed: _fitBounds,
                ),
                if (_plan != null) ...[
                  const SizedBox(height: 8),
                  _mapButton(
                    icon: _showSummaryPanel
                        ? Icons.visibility_off_rounded
                        : Icons.summarize_rounded,
                    tooltip: _showSummaryPanel
                        ? 'Hide route summary'
                        : 'Show route summary',
                    onPressed: () =>
                        setState(() => _showSummaryPanel = !_showSummaryPanel),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_plan != null && _showSummaryPanel)
          Positioned(
              left: 12,
              top: 12,
              child: MapOverlay(
                child: _buildRouteSummaryPanel(),
              )),
        if (_addresses.every((a) => !a.isGeocoded))
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: MapOverlay(
              child: Center(
                child: GlassPanel(
                  maxWidth: 340,
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          size: 18, color: GeocodeColors.brand),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Nothing is on the map yet — locate the addresses '
                          'to see them here.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _mapButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Material(
      elevation: 3,
      shape: const CircleBorder(),
      color: Theme.of(context).colorScheme.surface,
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 20),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildRouteSummaryPanel() {
    final plan = _plan!;
    return GlassPanel(
      maxWidth: 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.route_rounded,
                  size: 18, color: GeocodeColors.brand),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Planned route',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
              if (!plan.usedRealRoads)
                const Tooltip(
                  message: 'Straight-line estimates',
                  child: Icon(Icons.warning_amber_rounded,
                      size: 16, color: GeocodeColors.warning),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _summaryRow(
              Icons.pin_drop_rounded, 'Stops', '${plan.deliveryStops.length}'),
          _summaryRow(Icons.straighten_rounded, 'Distance',
              plan.totalDistanceFormatted),
          _summaryRow(Icons.directions_car_rounded, 'Driving',
              plan.totalDrivingFormatted),
          _summaryRow(
              Icons.schedule_rounded, 'With stops', plan.totalElapsedFormatted),
          if (plan.finishTime != null)
            _summaryRow(Icons.flag_rounded, 'Finishes',
                _timeFormat.format(plan.finishTime!)),
          _summaryRow(
              Icons.auto_awesome_rounded, 'Ordered by', plan.algorithm.label),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openAsClientMap,
                  icon: const Icon(Icons.share_location_rounded, size: 15),
                  label: const Text('Client map'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _openExportSheet,
                  icon: const Icon(Icons.ios_share_rounded, size: 15),
                  label: const Text('Export'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Theme.of(context).hintColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 11.5, color: Theme.of(context).hintColor)),
          ),
          Text(value,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget? _buildActionBar() {
    if (_isLoading || _addresses.isEmpty) return null;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border:
              Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed:
                    _isBusy || _pendingCount == 0 ? null : () => _geocode(),
                icon: const Icon(Icons.my_location_rounded, size: 18),
                label: Text(
                  _pendingCount == 0
                      ? 'All located'
                      : 'Locate $_pendingCount address'
                          '${_pendingCount == 1 ? '' : 'es'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    _isBusy || _geocodedCount < 2 ? null : _optimiseRoute,
                icon: const Icon(Icons.route_rounded, size: 18),
                label: Text(
                  _plan == null ? 'Optimise route' : 'Re-optimise',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.tonalIcon(
              onPressed: _plan == null ? null : _openExportSheet,
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text('Export'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Misc actions ───────────────────────────────────────────────────────

  /// Resolve a pasted list against the cadastral register, then import the
  /// parcels it finds as located stops.
  ///
  /// This is the ERF-first path: an ERF number resolves to a surveyed
  /// parcel, which is a far better delivery target than a geocoded street
  /// address — the pin lands on the actual erf rather than on a street-level
  /// interpolation, and the boundary comes with it for the client map.
  /// Lines the register cannot match still come through as ordinary
  /// addresses for the geocoder, so nothing is dropped.
  Future<void> _importErfList() async {
    if (_isBusy) return;

    final request = await showDialog<ErfPasteRequest>(
      context: context,
      builder: (_) => const ErfPasteListDialog(),
    );
    if (request == null || !mounted) return;

    final erfProvider = ref.read(erfPropertyRiverpod);
    _setProgress(message: 'Searching the cadastral register…');

    // A CSG query runs for the better part of a minute. Mirroring the
    // provider's own stage reporting into the progress bar is the
    // difference between "working" and "hung" for anyone watching it.
    void mirrorTask() {
      if (!mounted) return;
      final task = erfProvider.task;
      if (task == null) return;
      final stage = task.activeStageIndex >= 0
          ? task.stages[task.activeStageIndex]
          : null;
      _setProgress(
        message: task.title,
        detail: [
          if (task.stepNumber != null)
            'Step ${task.stepNumber} of ${task.stages.length}',
          if (stage != null) stage.label,
          if (stage?.detail != null) stage!.detail!,
        ].join(' · '),
        fraction: task.fraction,
      );
    }

    erfProvider.addListener(mirrorTask);

    try {
      final outcome = await ErfImportService(
        addressService: _addressService,
        parcelStore: _parcelStore,
      ).importList(
        erfProvider: erfProvider,
        text: request.text,
        suburb: widget.suburb,
        region: request.region,
        label: request.label,
        defaultCity: _guessCity(),
        existingParcels: _parcels,
      );
      if (!mounted) return;

      if (outcome.isEmpty) {
        showGeocodeSnack(context, 'Nothing usable in that list.',
            isError: true);
        return;
      }

      setState(() {
        _parcels = outcome.parcels;
        _parcelsUnsaved = !outcome.parcelsStored;
      });
      await _loadAddresses();

      if (!mounted) return;
      showGeocodeSnack(
        context,
        outcome.summary,
        action: outcome.unmatched > 0
            ? SnackBarAction(label: 'Locate', onPressed: () => _geocode())
            : null,
      );

      if (!outcome.parcelsStored && outcome.parcels.isNotEmpty) {
        showGeocodeSnack(
          context,
          'Parcel boundaries are too large to store — they will be lost when '
          'this screen closes. Export the map before leaving.',
          isError: true,
        );
      }
    } catch (e) {
      if (mounted) {
        showGeocodeSnack(context, 'ERF lookup failed: $e', isError: true);
      }
    } finally {
      erfProvider.removeListener(mirrorTask);
      _clearProgress();
    }
  }

  /// Publish the planned run as a real shareable map and open it.
  ///
  /// The run is written into the maps gallery, not just handed to the
  /// editor in memory: a client map that exists only for the lifetime of a
  /// screen is not something you can send anyone. Publishing again updates
  /// the same map rather than adding another copy to the gallery, so a
  /// suburb has one current client map and its share link keeps working.
  Future<void> _openAsClientMap() async {
    final plan = _plan;
    if (plan == null) {
      showGeocodeSnack(context, 'Optimise a route first.', isError: true);
      return;
    }
    if (_isBusy) return;

    _setProgress(message: 'Building the client map…');
    try {
      final built = await ErfRouteAdapter(
        route: plan,
        parcels: _parcels,
        title: '${widget.suburb.toUpperCase()} delivery run',
      ).load();

      final service = ShareableMapsFirestoreService();

      // Reuse the suburb's existing map when it is still there; a map the
      // user deleted from the gallery must not be silently resurrected.
      final existing = await _addressService.getClientMapRef(widget.suburb);
      final reusable = existing != null &&
          await service.mapExists(existing.monthKey, existing.docId);

      final String docId;
      final String monthKey;
      if (reusable) {
        docId = existing.docId;
        monthKey = existing.monthKey;
        _setProgress(message: 'Updating the client map…');
        await service.saveMap(monthKey, docId, built);
      } else {
        _setProgress(message: 'Publishing the client map…');
        monthKey = ShareableMapsFirestoreService.monthKeyFor(DateTime.now());
        docId = await service.createMap(built, monthKey: monthKey);
        await _addressService.saveClientMapRef(
          widget.suburb,
          docId: docId,
          monthKey: monthKey,
        );
      }

      if (!mounted) return;

      // Open the saved document, not the in-memory snapshot, so edits in
      // the editor land on the map the client is looking at.
      await ref.read(shareableMapRiverpod).loadFromAdapter(
            FirestoreMapAdapter.existing(
              docId: docId,
              monthKey: monthKey,
              service: service,
            ),
          );
      if (!mounted) return;

      _clearProgress();
      final shareCode = await service.getShareCode(monthKey, docId);
      if (!mounted) return;

      showGeocodeSnack(
        context,
        reusable
            ? 'Client map updated — ${built.layers.length} layers'
            : 'Client map published to the gallery',
        action: shareCode == null
            ? null
            : SnackBarAction(
                label: 'Copy link',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(
                    text: MapLinkService.buildShareUrl(shareCode),
                  ));
                  if (mounted) {
                    showGeocodeSnack(context, 'Share link copied.');
                  }
                },
              ),
      );

      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ShareableMapEditor()),
      );
    } catch (e) {
      if (mounted) {
        showGeocodeSnack(context, 'Could not publish the map: $e',
            isError: true);
      }
    } finally {
      _clearProgress();
    }
  }

  Future<void> _openImport() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddSuburbAddressesScreen(initialSuburb: widget.suburb),
      ),
    );
    if (mounted) await _loadAddresses();
  }

  Future<void> _copyAddressList() async {
    final source = _plan?.orderedAddresses ?? _addresses;
    final text = source
        .asMap()
        .entries
        .map((e) => '${e.key + 1}\t${e.value.fullAddress}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showGeocodeSnack(context, 'Address list copied.');
  }
}

// ── Dialogs ──────────────────────────────────────────────────────────────

class _EditAddressDialog extends StatefulWidget {
  final Address address;

  const _EditAddressDialog({required this.address});

  @override
  State<_EditAddressDialog> createState() => _EditAddressDialogState();
}

class _EditAddressDialogState extends State<_EditAddressDialog> {
  late final _street =
      TextEditingController(text: widget.address.streetAddress);
  late final _suburb = TextEditingController(text: widget.address.suburb);
  late final _city = TextEditingController(text: widget.address.city);
  late final _postal = TextEditingController(text: widget.address.postalCode);
  late final _province = TextEditingController(text: widget.address.province);
  late final _notes = TextEditingController(text: widget.address.notes ?? '');

  @override
  void dispose() {
    _street.dispose();
    _suburb.dispose();
    _city.dispose();
    _postal.dispose();
    _province.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit address'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(_street, 'Street address', autofocus: true),
              _field(_suburb, 'Suburb'),
              _field(_city, 'City'),
              _field(_postal, 'Postal code'),
              _field(_province, 'Province'),
              _field(_notes, 'Notes for the driver', maxLines: 2),
              if (widget.address.formattedAddress?.isNotEmpty ?? false)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.travel_explore_rounded, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Google matched: ${widget.address.formattedAddress}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            widget.address.copyWith(
              streetAddress: _street.text.trim(),
              suburb: _suburb.text.trim(),
              city: _city.text.trim(),
              postalCode: _postal.text.trim(),
              province: _province.text.trim(),
              notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool autofocus = false,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

class _DepotDialog extends StatefulWidget {
  final String defaultCity;

  const _DepotDialog({required this.defaultCity});

  @override
  State<_DepotDialog> createState() => _DepotDialogState();
}

class _DepotDialogState extends State<_DepotDialog> {
  final _name = TextEditingController();
  final _address = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a depot'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Runs start here, and finish here when "return to start" is on.',
              style: TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Epping warehouse',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _address,
              decoration: InputDecoration(
                labelText: 'Address',
                hintText: '12 Sacks Circle, Bellville, ${widget.defaultCity}',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_address.text.trim().isEmpty) return;
            Navigator.of(context).pop({
              'name': _name.text.trim(),
              'address': _address.text.trim(),
            });
          },
          child: const Text('Save depot'),
        ),
      ],
    );
  }
}
