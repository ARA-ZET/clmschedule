import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/address.dart';
import '../models/route_data.dart';
import '../services/geocoding_service.dart';
import '../services/address_service_v2.dart';
import '../services/route_optimization_service.dart';
import '../services/distance_matrix_service.dart';
import '../widgets/geocoded_addresses_map_viewer.dart';

/// Screen showing addresses for a specific suburb with geocoding functionality
class SuburbAddressesScreen extends StatefulWidget {
  final String suburb;

  const SuburbAddressesScreen({super.key, required this.suburb});

  @override
  State<SuburbAddressesScreen> createState() => _SuburbAddressesScreenState();
}

class _SuburbAddressesScreenState extends State<SuburbAddressesScreen> {
  final AddressServiceV2 _addressService =
      AddressServiceV2(FirebaseFirestore.instance);
  final GeocodingService _geocodingService = GeocodingService();
  final DistanceMatrixService _distanceMatrixService = DistanceMatrixService();

  List<Address> _addresses = [];
  bool _isLoading = false;
  bool _isGeocoding = false;
  int _geocodedCount = 0;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadAddresses();
  }

  Future<void> _loadAddresses() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final addresses = await _addressService.getAddresses(widget.suburb);
      setState(() {
        _addresses = addresses;
        _geocodedCount = addresses.where((a) => a.isGeocoded).length;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading addresses: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _geocodeAddress(Address address, int index) async {
    try {
      final result =
          await _geocodingService.geocodeAddress(address.fullAddress);

      if (result != null) {
        final updated = address.copyWith(
          latitude: result['lat'],
          longitude: result['lng'],
          isGeocoded: true,
        );

        await _addressService.updateAddress(widget.suburb, index, updated);

        setState(() {
          _addresses[index] = updated;
          _geocodedCount++;
        });
      } else {
        final updated = address.copyWith(
          isGeocoded: false,
          geocodingError: 'Geocoding failed',
        );

        await _addressService.updateAddress(widget.suburb, index, updated);

        setState(() {
          _addresses[index] = updated;
        });
      }
    } catch (e) {
      debugPrint('Error geocoding address: $e');
    }
  }

  Future<void> _geocodeAll() async {
    setState(() {
      _isGeocoding = true;
      _errorMessage = null;
    });

    try {
      for (int i = 0; i < _addresses.length; i++) {
        final address = _addresses[i];
        if (!address.isGeocoded) {
          await _geocodeAddress(address, i);
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Geocoding complete!')),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error geocoding addresses: $e';
      });
    } finally {
      setState(() {
        _isGeocoding = false;
      });
    }
  }

  void _showOnMap({bool optimize = false}) {
    final geocodedAddresses = _addresses.where((a) => a.isGeocoded).toList();

    if (geocodedAddresses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No geocoded addresses to show')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GeocodedAddressesMapViewer(
          addresses: geocodedAddresses,
          title: '${widget.suburb} (${geocodedAddresses.length})',
        ),
      ),
    );
  }

  void _showOptimizedRoute() async {
    final geocodedAddresses = _addresses.where((a) => a.isGeocoded).toList();

    if (geocodedAddresses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No geocoded addresses to show')),
      );
      return;
    }

    if (geocodedAddresses.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Need at least 2 addresses for route optimization')),
      );
      return;
    }

    // Check for cached route data
    final cachedRouteData =
        await _addressService.getSuburbRouteData(widget.suburb);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Route Optimization'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Optimize route for ${geocodedAddresses.length} addresses'),

            // Show cached data info if available
            if (cachedRouteData != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  border: Border.all(color: Colors.green),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.check_circle, size: 16, color: Colors.green),
                        SizedBox(width: 8),
                        Text(
                          'Cached Route Available',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, color: Colors.green),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Last optimized: ${_formatDateTime(cachedRouteData.optimizedAt)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      'Distance: ${cachedRouteData.totalDistanceKm.toStringAsFixed(1)} km',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      'Duration: ${cachedRouteData.totalDurationFormatted}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      'Algorithm: ${cachedRouteData.algorithm}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),
            const Text('Choose optimization strategy:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('• Nearest Neighbor: Fast, good for quick routes',
                style: TextStyle(fontSize: 12)),
            const Text('• 2-Opt Algorithm: Better optimization',
                style: TextStyle(fontSize: 12)),
            if (kIsWeb) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  border: Border.all(color: Colors.orange),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.orange),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Web: Using straight-line distance estimates',
                        style: TextStyle(fontSize: 11, color: Colors.orange),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),

          // Show \"Use Cached\" button if cached data exists
          if (cachedRouteData != null)
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _loadAndShowCachedRoute(cachedRouteData);
              },
              icon: const Icon(Icons.cached),
              label: const Text('Use Cached'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),

          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _optimizeAndShowRoute(geocodedAddresses,
                  use2Opt: false, forceRecalculate: true);
            },
            child: const Text('Nearest Neighbor'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _optimizeAndShowRoute(geocodedAddresses,
                  use2Opt: true, forceRecalculate: true);
            },
            child: const Text('2-Opt (Better)'),
          ),
        ],
      ),
    );
  }

  /// Format datetime for display
  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes} minutes ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours} hours ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }

  /// Load and show cached route without recalculating
  void _loadAndShowCachedRoute(SuburbRouteData cachedRouteData) async {
    try {
      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading cached route...'),
                ],
              ),
            ),
          ),
        ),
      );

      // Get addresses in the optimized order
      final orderedAddresses =
          await _addressService.getAddresses(widget.suburb);

      // Close loading dialog
      if (mounted) Navigator.pop(context);

      // Create optimized route object (distances are estimations, actual route is in segments)
      final optimizedRoute = OptimizedRoute(
        addresses: orderedAddresses,
        totalDistance: cachedRouteData.totalDistanceKm,
        strategy: cachedRouteData.algorithm,
      );

      // Navigate to map viewer with cached data
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => GeocodedAddressesMapViewer(
              addresses: orderedAddresses,
              title:
                  '${widget.suburb} - Cached Route (${orderedAddresses.length} stops)',
              optimizedRoute: optimizedRoute,
              routeData: cachedRouteData,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error loading cached route: $e');

      // Close loading dialog if still open
      if (mounted) Navigator.pop(context);

      // Show error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading cached route: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  void _optimizeAndShowRoute(List<Address> addresses,
      {required bool use2Opt, bool forceRecalculate = false}) async {
    // Using a ValueNotifier to update dialog state
    final statusMessage = ValueNotifier<String>('Optimizing route...');
    final segmentsProgress = ValueNotifier<int>(0);
    final totalSegments = ValueNotifier<int>(0);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                ValueListenableBuilder<String>(
                  valueListenable: statusMessage,
                  builder: (context, message, _) => Text(message),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: totalSegments,
                  builder: (context, total, _) {
                    if (total > 0) {
                      return ValueListenableBuilder<int>(
                        valueListenable: segmentsProgress,
                        builder: (context, progress, _) => Column(
                          children: [
                            const SizedBox(height: 8),
                            Text(
                              'Querying route segments: $progress/$total',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      // Step 1: Optimize route using selected algorithm
      debugPrint(
          'Starting route optimization with ${addresses.length} addresses');
      final service = RouteOptimizationService();
      final optimizedRoute = use2Opt
          ? service.optimizeRoute2Opt(addresses)
          : service.optimizeRouteNearestNeighbor(addresses);

      debugPrint(
          'Route optimized: ${optimizedRoute.addresses.length} addresses');

      // Step 2: Query Google Distance Matrix API for route segments
      statusMessage.value = 'Querying route segments...';
      totalSegments.value = optimizedRoute.addresses.length - 1;

      debugPrint('Starting to query ${totalSegments.value} route segments...');

      final segments = await _distanceMatrixService.getRouteSegments(
        optimizedRoute.addresses,
        onProgress: (current, total) {
          debugPrint('Progress: $current/$total segments');
          segmentsProgress.value = current;
        },
      );

      debugPrint('Retrieved ${segments.length} route segments');

      // Calculate totals
      double totalDistanceMeters = 0;
      int totalDurationSeconds = 0;
      for (final segment in segments) {
        debugPrint(
            'Segment: ${segment.distanceMeters}m, ${segment.durationSeconds}s');
        totalDistanceMeters += segment.distanceMeters;
        totalDurationSeconds += segment.durationSeconds;
      }

      debugPrint(
          'Total distance: ${totalDistanceMeters}m, duration: ${totalDurationSeconds}s');

      // Step 3: Save optimized route with indices (one call)
      statusMessage.value = 'Saving route...';
      await _addressService.saveOptimizedRoute(
        widget.suburb,
        optimizedRoute.addresses,
      );

      // Step 4: Save route data with segments (one call)
      final algorithmName = use2Opt ? '2opt' : 'nearest_neighbor';
      final algorithmSuffix = kIsWeb ? '_estimated' : '_actual';

      final routeData = SuburbRouteData(
        suburb: widget.suburb,
        algorithm: algorithmName + algorithmSuffix,
        optimizedAt: DateTime.now(),
        segments: segments,
        totalDistanceMeters: totalDistanceMeters,
        totalDurationSeconds: totalDurationSeconds,
      );

      await _addressService.saveSuburbRouteData(routeData);

      // Close progress dialog
      if (mounted) Navigator.pop(context);

      // Reload addresses to show updated route indices
      await _loadAddresses();

      // Step 5: Navigate to map viewer
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => GeocodedAddressesMapViewer(
              addresses: optimizedRoute.addresses,
              title: '${widget.suburb} - Optimized (${addresses.length} stops)',
              optimizedRoute: optimizedRoute,
              routeData: routeData,
            ),
          ),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('Error optimizing route: $e');
      debugPrint('Stack trace: $stackTrace');

      // Close progress dialog
      if (mounted) Navigator.pop(context);

      // Show error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error optimizing route: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.suburb.toUpperCase()),
        actions: [
          if (_addresses.isNotEmpty && _geocodedCount < _addresses.length)
            IconButton(
              icon: const Icon(Icons.play_arrow),
              tooltip: 'Geocode All',
              onPressed: _isGeocoding ? null : _geocodeAll,
            ),
          if (_geocodedCount > 0)
            PopupMenuButton<String>(
              icon: const Icon(Icons.map),
              tooltip: 'View Options',
              onSelected: (value) {
                if (value == 'view_map') {
                  _showOnMap(optimize: false);
                } else if (value == 'optimize_route') {
                  _showOptimizedRoute();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'view_map',
                  child: Row(
                    children: [
                      Icon(Icons.map_outlined),
                      SizedBox(width: 8),
                      Text('View on Map'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'optimize_route',
                  child: Row(
                    children: [
                      Icon(Icons.route),
                      SizedBox(width: 8),
                      Text('Optimize Route'),
                    ],
                  ),
                ),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _isLoading ? null : _loadAddresses,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading addresses...'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_errorMessage!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
                onPressed: _loadAddresses, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_addresses.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_off, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('No addresses found', style: TextStyle(fontSize: 18)),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildStatsBar(),
        Expanded(child: _buildAddressList()),
      ],
    );
  }

  Widget _buildStatsBar() {
    final notGeocoded = _addresses.length - _geocodedCount;

    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.blue.shade50,
      child: Row(
        children: [
          _buildStatChip('Total', _addresses.length.toString(), Colors.blue),
          const SizedBox(width: 16),
          _buildStatChip('Geocoded', _geocodedCount.toString(), Colors.green),
          const SizedBox(width: 16),
          _buildStatChip('Pending', notGeocoded.toString(), Colors.orange),
          const Spacer(),
          if (_isGeocoding)
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: color)),
          const SizedBox(width: 8),
          Text(value,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  Widget _buildAddressList() {
    return ListView.builder(
      itemCount: _addresses.length,
      itemBuilder: (context, index) {
        final address = _addresses[index];
        return _buildAddressCard(address, index);
      },
    );
  }

  Widget _buildAddressCard(Address address, int index) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: address.isGeocoded ? Colors.green : Colors.grey,
          child: Icon(
            address.isGeocoded ? Icons.check : Icons.location_on_outlined,
            color: Colors.white,
          ),
        ),
        title: Text(
          address.streetAddress.isNotEmpty
              ? address.streetAddress
              : address.suburb,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(address.fullAddress, style: const TextStyle(fontSize: 12)),
            if (address.isGeocoded && address.latitude != null)
              Text(
                'Lat: ${address.latitude!.toStringAsFixed(6)}, Lng: ${address.longitude!.toStringAsFixed(6)}',
                style: TextStyle(fontSize: 11, color: Colors.green.shade700),
              ),
            if (address.geocodingError != null)
              Text(
                'Error: ${address.geocodingError}',
                style: const TextStyle(fontSize: 11, color: Colors.red),
              ),
          ],
        ),
        trailing: !address.isGeocoded && !_isGeocoding
            ? IconButton(
                icon: const Icon(Icons.location_searching),
                onPressed: () => _geocodeAddress(address, index),
                tooltip: 'Geocode this address',
              )
            : null,
        isThreeLine: true,
      ),
    );
  }
}
