import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/address.dart';
import '../models/route_data.dart';
import '../services/route_optimization_service.dart';

/// Map viewer for displaying geocoded addresses as markers
class GeocodedAddressesMapViewer extends StatefulWidget {
  final List<Address> addresses;
  final String title;
  final OptimizedRoute? optimizedRoute;
  final SuburbRouteData? routeData;

  const GeocodedAddressesMapViewer({
    super.key,
    required this.addresses,
    this.title = 'Geocoded Addresses',
    this.optimizedRoute,
    this.routeData,
  });

  @override
  State<GeocodedAddressesMapViewer> createState() =>
      _GeocodedAddressesMapViewerState();
}

class _GeocodedAddressesMapViewerState
    extends State<GeocodedAddressesMapViewer> {
  GoogleMapController? _mapController;
  Address? _selectedAddress;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  bool _showRouteStats = false;

  @override
  void initState() {
    super.initState();
    _createMarkers();
    if (widget.optimizedRoute != null) {
      _createRoutePolylines();
    }
  }

  void _createMarkers() {
    final markers = <Marker>{};
    final displayAddresses =
        widget.optimizedRoute?.addresses ?? widget.addresses;

    for (int i = 0; i < displayAddresses.length; i++) {
      final address = displayAddresses[i];
      if (address.latitude == null || address.longitude == null) continue;

      final marker = Marker(
        markerId: MarkerId(address.id),
        position: LatLng(address.latitude!, address.longitude!),
        infoWindow: InfoWindow(
          title: widget.optimizedRoute != null
              ? '${i + 1}. ${address.streetAddress.isNotEmpty ? address.streetAddress : address.suburb}'
              : address.streetAddress.isNotEmpty
                  ? address.streetAddress
                  : address.suburb,
          snippet: 'Tap for details',
        ),
        onTap: () {
          setState(() {
            _selectedAddress = address;
          });
        },
        icon: widget.optimizedRoute != null
            ? BitmapDescriptor.defaultMarkerWithHue(
                _getRouteMarkerHue(i, displayAddresses.length))
            : BitmapDescriptor.defaultMarkerWithHue(_getMarkerHue(i)),
      );

      markers.add(marker);
    }

    setState(() {
      _markers = markers;
    });
  }

  void _createRoutePolylines() {
    if (widget.optimizedRoute == null) return;

    final polylines = <Polyline>{};

    // If we have routeData with actual Google Directions polylines, use those
    if (widget.routeData != null && widget.routeData!.segments.isNotEmpty) {
      for (int i = 0; i < widget.routeData!.segments.length; i++) {
        final segment = widget.routeData!.segments[i];
        final polyline = Polyline(
          polylineId: PolylineId('route_segment_$i'),
          points: segment.polylinePoints,
          color: Colors.blue,
          width: 4,
          patterns: [PatternItem.dash(20), PatternItem.gap(10)],
        );
        polylines.add(polyline);
      }
    } else {
      // Fallback to straight lines if no routeData available
      final points = <LatLng>[];
      for (final address in widget.optimizedRoute!.addresses) {
        if (address.latitude != null && address.longitude != null) {
          points.add(LatLng(address.latitude!, address.longitude!));
        }
      }

      final polyline = Polyline(
        polylineId: const PolylineId('optimized_route'),
        points: points,
        color: Colors.blue,
        width: 4,
        patterns: [PatternItem.dash(20), PatternItem.gap(10)],
      );
      polylines.add(polyline);
    }

    setState(() {
      _polylines = polylines;
    });
  }

  double _getRouteMarkerHue(int index, int total) {
    // Gradient from green (start) to red (end)
    if (index == 0) return BitmapDescriptor.hueGreen;
    if (index == total - 1) return BitmapDescriptor.hueRed;
    return BitmapDescriptor.hueOrange;
  }

  double _getMarkerHue(int index) {
    // Use different colors for different markers
    final hues = [
      BitmapDescriptor.hueRed,
      BitmapDescriptor.hueOrange,
      BitmapDescriptor.hueYellow,
      BitmapDescriptor.hueGreen,
      BitmapDescriptor.hueCyan,
      BitmapDescriptor.hueBlue,
      BitmapDescriptor.hueViolet,
      BitmapDescriptor.hueMagenta,
    ];
    return hues[index % hues.length];
  }

  void _fitBounds() {
    if (_mapController == null || widget.addresses.isEmpty) return;

    double minLat = widget.addresses.first.latitude!;
    double maxLat = widget.addresses.first.latitude!;
    double minLng = widget.addresses.first.longitude!;
    double maxLng = widget.addresses.first.longitude!;

    for (final address in widget.addresses) {
      if (address.latitude == null || address.longitude == null) continue;

      if (address.latitude! < minLat) minLat = address.latitude!;
      if (address.latitude! > maxLat) maxLat = address.latitude!;
      if (address.longitude! < minLng) minLng = address.longitude!;
      if (address.longitude! > maxLng) maxLng = address.longitude!;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 50),
    );
  }

  LatLng _getCenter() {
    if (widget.addresses.isEmpty) {
      return const LatLng(-33.9249, 18.4241); // Cape Town default
    }

    double totalLat = 0;
    double totalLng = 0;
    int count = 0;

    for (final address in widget.addresses) {
      if (address.latitude != null && address.longitude != null) {
        totalLat += address.latitude!;
        totalLng += address.longitude!;
        count++;
      }
    }

    if (count == 0) {
      return const LatLng(-33.9249, 18.4241);
    }

    return LatLng(totalLat / count, totalLng / count);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (widget.optimizedRoute != null)
            IconButton(
              icon: Icon(_showRouteStats ? Icons.map : Icons.bar_chart),
              tooltip: _showRouteStats ? 'Show Map' : 'Show Route Stats',
              onPressed: () {
                setState(() {
                  _showRouteStats = !_showRouteStats;
                });
              },
            ),
          IconButton(
            icon: const Icon(Icons.zoom_out_map),
            tooltip: 'Fit all markers',
            onPressed: _fitBounds,
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _getCenter(),
              zoom: 14,
            ),
            markers: _markers,
            polylines: _polylines,
            onMapCreated: (controller) {
              _mapController = controller;
              // Fit bounds after a short delay to ensure map is ready
              Future.delayed(const Duration(milliseconds: 500), () {
                _fitBounds();
              });
            },
            myLocationButtonEnabled: true,
            myLocationEnabled: true,
            zoomControlsEnabled: true,
            mapToolbarEnabled: false,
          ),
          if (_selectedAddress != null && !_showRouteStats)
            _buildAddressDetailsPanel(),
          if (_showRouteStats && widget.optimizedRoute != null)
            _buildRouteStatisticsPanel(),
        ],
      ),
    );
  }

  Widget _buildAddressDetailsPanel() {
    return Positioned(
      bottom: 16,
      left: 16,
      right: 16,
      child: Card(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _selectedAddress!.streetAddress.isNotEmpty
                          ? _selectedAddress!.streetAddress
                          : _selectedAddress!.suburb,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() {
                        _selectedAddress = null;
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _selectedAddress!.fullAddress,
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.location_on, size: 16, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    'Lat: ${_selectedAddress!.latitude!.toStringAsFixed(6)}, '
                    'Lng: ${_selectedAddress!.longitude!.toStringAsFixed(6)}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.navigation),
                    label: const Text('Navigate'),
                    onPressed: () {
                      // Center map on this address
                      _mapController?.animateCamera(
                        CameraUpdate.newLatLngZoom(
                          LatLng(
                            _selectedAddress!.latitude!,
                            _selectedAddress!.longitude!,
                          ),
                          17,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRouteStatisticsPanel() {
    // If we have actual routeData from Google, use that for accurate stats
    if (widget.routeData != null) {
      return _buildActualRouteStatistics();
    }

    // Fallback to estimated stats from Haversine distance
    final service = RouteOptimizationService();
    final stats = service.getRouteStatistics(widget.optimizedRoute!);
    final segments =
        service.calculateRouteSegments(widget.optimizedRoute!.addresses);

    return Positioned(
      top: 16,
      left: 16,
      right: 16,
      bottom: 16,
      child: Card(
        elevation: 8,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.route, color: Colors.blue),
                  const SizedBox(width: 8),
                  const Text(
                    'Route Statistics (Estimated)',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() {
                        _showRouteStats = false;
                      });
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Summary stats
                    _buildStatRow(Icons.straighten, 'Total Distance',
                        stats.formattedTotalDistance, Colors.blue),
                    _buildStatRow(Icons.location_on, 'Number of Stops',
                        '${stats.numberOfStops}', Colors.green),
                    _buildStatRow(Icons.timer, 'Est. Time',
                        stats.formattedEstimatedTime, Colors.orange),
                    _buildStatRow(Icons.speed, 'Avg. Distance/Stop',
                        stats.formattedAverageDistance, Colors.purple),
                    _buildStatRow(Icons.auto_graph, 'Strategy', stats.strategy,
                        Colors.teal),

                    const Divider(height: 32),

                    // Route details
                    const Text(
                      'Route Details',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),

                    ...segments.map((segment) => _buildSegmentTile(segment)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActualRouteStatistics() {
    final routeData = widget.routeData!;

    // Parse algorithm name
    final isEstimated = routeData.algorithm.contains('_estimated');
    final algorithmBase = routeData.algorithm
        .replaceAll('_estimated', '')
        .replaceAll('_actual', '');
    final algorithmName =
        algorithmBase == '2opt' ? '2-Opt' : 'Nearest Neighbor';
    final algorithmSuffix = isEstimated ? ' (Estimated)' : ' (Actual Roads)';

    return Positioned(
      top: 16,
      left: 16,
      right: 16,
      bottom: 16,
      child: Card(
        elevation: 8,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.route, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Route Statistics${isEstimated ? ' (Estimated)' : ' (Actual)'}',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          isEstimated
                              ? 'Straight-line distances'
                              : 'Google Directions API',
                          style: TextStyle(
                            fontSize: 10,
                            color: isEstimated ? Colors.orange : Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() {
                        _showRouteStats = false;
                      });
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Summary stats
                    _buildStatRow(
                      Icons.straighten,
                      'Total Distance',
                      '${routeData.totalDistanceKm.toStringAsFixed(1)} km',
                      Colors.blue,
                    ),
                    _buildStatRow(
                      Icons.location_on,
                      'Number of Stops',
                      '${routeData.segments.length + 1}',
                      Colors.green,
                    ),
                    _buildStatRow(
                      Icons.timer,
                      'Total Duration',
                      routeData.totalDurationFormatted,
                      Colors.orange,
                    ),
                    _buildStatRow(
                      Icons.speed,
                      'Avg. Distance/Segment',
                      '${(routeData.totalDistanceKm / routeData.segments.length).toStringAsFixed(2)} km',
                      Colors.purple,
                    ),
                    _buildStatRow(
                      Icons.auto_graph,
                      'Algorithm',
                      algorithmName + algorithmSuffix,
                      Colors.teal,
                    ),
                    _buildStatRow(
                      Icons.access_time,
                      'Optimized At',
                      '${routeData.optimizedAt.day}/${routeData.optimizedAt.month}/${routeData.optimizedAt.year} ${routeData.optimizedAt.hour}:${routeData.optimizedAt.minute.toString().padLeft(2, '0')}',
                      Colors.grey,
                    ),

                    const Divider(height: 32),

                    // Route segment details
                    const Text(
                      'Route Segments',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),

                    ...routeData.segments.asMap().entries.map((entry) {
                      final index = entry.key;
                      final segment = entry.value;
                      return _buildActualSegmentTile(index + 1, segment);
                    }),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActualSegmentTile(int segmentNumber, RouteSegmentData segment) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.blue.shade100,
          child: Text(
            '$segmentNumber',
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.blue),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '${segment.distanceKm.toStringAsFixed(2)} km',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
            Text(
              segment.durationFormatted,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        subtitle: Text(
          'Stop $segmentNumber → Stop ${segmentNumber + 1}',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Widget _buildStatRow(IconData icon, String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentTile(RouteSegment segment) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.blue.shade100,
          child: Text(
            '${segment.order}',
            style: TextStyle(
                color: Colors.blue.shade900, fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(
          segment.from.streetAddress.isNotEmpty
              ? segment.from.streetAddress
              : segment.from.suburb,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        subtitle: Row(
          children: [
            const Icon(Icons.arrow_downward, size: 12, color: Colors.grey),
            const SizedBox(width: 4),
            Text(
              segment.to.streetAddress.isNotEmpty
                  ? segment.to.streetAddress
                  : segment.to.suburb,
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
        trailing: Text(
          '${segment.distance.toStringAsFixed(2)} km',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }
}
