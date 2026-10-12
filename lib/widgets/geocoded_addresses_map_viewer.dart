import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/route_export_service.dart';
import '../services/route_planner_service.dart';
import 'geocode/geocode_ui.dart';
import 'geocode/route_export_sheet.dart';
import '../utils/route_marker_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../shareable_maps/providers/map_gesture_provider.dart';
import '../shareable_maps/widgets/map_overlay.dart';

/// Full-screen presentation of a planned run: the map on one side, the
/// driver's itinerary on the other.
///
/// This is the hand-to-the-driver view. Where the workspace is for
/// building a route, this is for reading one — every stop in order with
/// its leg distance, drive time and ETA, and a per-stop link that opens
/// navigation on a phone.
class GeocodedAddressesMapViewer extends riverpod.ConsumerStatefulWidget {
  final PlannedRoute route;
  final String title;

  const GeocodedAddressesMapViewer({
    super.key,
    required this.route,
    this.title = 'Route',
  });

  @override
  riverpod.ConsumerState<GeocodedAddressesMapViewer> createState() =>
      _GeocodedAddressesMapViewerState();
}

class _GeocodedAddressesMapViewerState
    extends riverpod.ConsumerState<GeocodedAddressesMapViewer> {
  static final DateFormat _timeFormat = DateFormat('HH:mm');

  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  MapType _mapType = MapType.normal;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _buildLayers();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _buildLayers() async {
    final stops = widget.route.stops;
    final markers = <Marker>{};

    for (var i = 0; i < stops.length; i++) {
      final stop = stops[i];
      final address = stop.address;
      if (address.latitude == null || address.longitude == null) continue;

      final icon = await RouteMarkerIcons.numbered(
        stop.isDepot ? 'S' : '${stop.sequence}',
        color: stop.isDepot
            ? GeocodeColors.depot
            : RouteMarkerIcons.colorForPosition(i, stops.length),
        highlighted: _selectedId == address.id,
      );

      markers.add(Marker(
        markerId: MarkerId(address.id),
        position: LatLng(address.latitude!, address.longitude!),
        icon: icon,
        anchor: const Offset(0.5, 1),
        infoWindow: InfoWindow(
          title: stop.isDepot
              ? 'Start · ${address.displayName}'
              : '${stop.sequence}. ${address.displayName}',
          snippet: address.fullAddress,
        ),
        onTap: () {
          // The click that landed on a panel over the map.
          if (ref.read(mapGestureRiverpod).isHeld) return;
          _select(stop);
        },
      ));
    }

    final polylines = <Polyline>{};
    for (var i = 1; i < stops.length; i++) {
      final stop = stops[i];
      if (stop.pathFromPrevious.length < 2) continue;
      polylines.add(Polyline(
        polylineId: PolylineId('leg_$i'),
        points: stop.pathFromPrevious,
        color: RouteMarkerIcons.colorForPosition(i, stops.length)
            .withValues(alpha: 0.9),
        width: 5,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
      ));
    }
    final back = widget.route.returnLeg;
    if (back != null && back.pathFromPrevious.length >= 2) {
      polylines.add(Polyline(
        polylineId: const PolylineId('leg_return'),
        points: back.pathFromPrevious,
        color: GeocodeColors.neutral,
        width: 4,
        patterns: [PatternItem.dash(24), PatternItem.gap(14)],
      ));
    }

    if (!mounted) return;
    setState(() {
      _markers = markers;
      _polylines = polylines;
    });
  }

  void _select(PlannedStop stop) {
    setState(() => _selectedId = stop.address.id);
    _buildLayers();
    final a = stop.address;
    if (a.latitude != null && a.longitude != null) {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(a.latitude!, a.longitude!), 17),
      );
    }
  }

  void _fitBounds() {
    final points = <LatLng>[
      for (final s in widget.route.stops)
        if (s.address.latitude != null && s.address.longitude != null)
          LatLng(s.address.latitude!, s.address.longitude!),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title),
            Text(
              '${widget.route.deliveryStops.length} stops · '
              '${widget.route.totalDistanceFormatted} · '
              '${widget.route.totalDrivingFormatted} driving',
              style:
                  const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Fit all stops',
            icon: const Icon(Icons.zoom_out_map_rounded),
            onPressed: _fitBounds,
          ),
          IconButton(
            tooltip: 'Copy the itinerary',
            icon: const Icon(Icons.copy_all_rounded),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(
                text: RouteExportService.buildTsv(widget.route),
              ));
              if (context.mounted) {
                showGeocodeSnack(context, 'Itinerary copied.');
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 12),
            child: FilledButton.icon(
              onPressed: () => RouteExportSheet.show(
                context,
                route: widget.route,
                baseName: widget.title,
              ),
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text('Export'),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 940) {
            return Row(
              children: [
                SizedBox(width: 400, child: _buildItinerary()),
                const VerticalDivider(width: 1),
                Expanded(child: _buildMap()),
              ],
            );
          }
          return Column(
            children: [
              Expanded(flex: 3, child: _buildMap()),
              const Divider(height: 1),
              Expanded(flex: 4, child: _buildItinerary()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMap() {
    final first = widget.route.stops.isEmpty
        ? const LatLng(-33.9249, 18.4241)
        : LatLng(
            widget.route.stops.first.address.latitude ?? -33.9249,
            widget.route.stops.first.address.longitude ?? 18.4241,
          );

    return Stack(
      children: [
        GoogleMap(
          webGestureHandling: ref.watch(mapGestureRiverpod).gestureHandling,
          initialCameraPosition: CameraPosition(target: first, zoom: 13),
          markers: _markers,
          polylines: _polylines,
          mapType: _mapType,
          zoomControlsEnabled: true,
          mapToolbarEnabled: false,
          myLocationButtonEnabled: false,
          onMapCreated: (controller) {
            _mapController = controller;
            Future.delayed(const Duration(milliseconds: 400), _fitBounds);
          },
        ),
        Positioned(
          top: 12,
          right: 12,
          child: MapOverlay(
            child: Material(
              elevation: 3,
              shape: const CircleBorder(),
              color: Theme.of(context).colorScheme.surface,
              child: IconButton(
                tooltip:
                    _mapType == MapType.normal ? 'Satellite view' : 'Map view',
                icon: Icon(
                  _mapType == MapType.normal
                      ? Icons.satellite_alt_rounded
                      : Icons.map_rounded,
                  size: 20,
                ),
                onPressed: () => setState(() {
                  _mapType = _mapType == MapType.normal
                      ? MapType.hybrid
                      : MapType.normal;
                }),
              ),
            ),
          ),
        ),
        if (!widget.route.usedRealRoads)
          Positioned(
            left: 12,
            top: 12,
            child: MapOverlay(
              child: GlassPanel(
                maxWidth: 300,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 18, color: GeocodeColors.warning),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Straight-line estimates — the Directions service '
                        'did not answer.',
                        style: TextStyle(fontSize: 11.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildItinerary() {
    final stops = [
      ...widget.route.stops,
      if (widget.route.returnLeg != null) widget.route.returnLeg!,
    ];

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 24),
      itemCount: stops.length,
      itemBuilder: (context, index) {
        final stop = stops[index];
        final isReturn = index == widget.route.stops.length;
        return _buildStopCard(stop, index, isReturn);
      },
    );
  }

  Widget _buildStopCard(PlannedStop stop, int index, bool isReturn) {
    final address = stop.address;
    final selected = !isReturn && _selectedId == address.id;
    final color = isReturn
        ? GeocodeColors.neutral
        : stop.isDepot
            ? GeocodeColors.depot
            : RouteMarkerIcons.colorForPosition(
                index, widget.route.stops.length);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected
            ? GeocodeColors.brand.withValues(alpha: 0.08)
            : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: isReturn ? null : () => _select(stop),
          child: Container(
            padding: const EdgeInsets.all(12),
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
                  label: isReturn
                      ? '⌂'
                      : stop.isDepot
                          ? 'S'
                          : '${stop.sequence}',
                  color: color,
                  selected: selected,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isReturn
                            ? 'Return to ${address.displayName}'
                            : address.displayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        address.fullAddress,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                      if (address.notes?.isNotEmpty ?? false) ...[
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.sticky_note_2_outlined, size: 13),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                address.notes!,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (!stop.isDepot || isReturn)
                            _fact(Icons.straighten_rounded,
                                '${stop.legDistanceKm.toStringAsFixed(1)} km'),
                          if (!stop.isDepot || isReturn)
                            _fact(Icons.timer_outlined,
                                stop.legDurationFormatted),
                          if (stop.arrival != null)
                            _fact(Icons.schedule_rounded,
                                'ETA ${_timeFormat.format(stop.arrival!)}'),
                          _fact(Icons.route_rounded,
                              '${stop.cumulativeDistanceKm.toStringAsFixed(1)} km total'),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Navigate to this stop',
                  icon: const Icon(Icons.near_me_rounded, size: 18),
                  onPressed: () => launchUrl(
                    Uri.parse(RouteExportService.mapsPinUrl(address)),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fact(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: Theme.of(context).hintColor),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).hintColor,
          ),
        ),
      ],
    );
  }
}
