import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/address.dart';
import '../services/geocoding_service.dart';
import '../services/address_service.dart';
import '../services/route_optimization_service.dart';
import '../widgets/geocoded_addresses_map_viewer.dart';

/// Screen for geocoding addresses and displaying them on a map
class GeocodingScreen extends StatefulWidget {
  const GeocodingScreen({super.key});

  @override
  State<GeocodingScreen> createState() => _GeocodingScreenState();
}

class _GeocodingScreenState extends State<GeocodingScreen> {
  final AddressService _addressService =
      AddressService(FirebaseFirestore.instance);
  final GeocodingService _geocodingService = GeocodingService();

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
      final addresses =
          await _addressService.getAddresses('pinelands', 'addresses');
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

  Future<void> _initializeAddresses() async {
    final pinelandsAddresses = _getPinelandsAddresses();

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _addressService.initializeAddresses(
          'pinelands', 'addresses', pinelandsAddresses);
      await _loadAddresses();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('Initialized ${pinelandsAddresses.length} addresses')),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error initializing addresses: $e';
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

        await _addressService.updateAddress(
            'pinelands', 'addresses', index, updated);

        setState(() {
          _addresses[index] = updated;
          _geocodedCount++;
        });
      } else {
        final updated = address.copyWith(
          isGeocoded: false,
          geocodingError: 'Geocoding failed',
        );

        await _addressService.updateAddress(
            'pinelands', 'addresses', index, updated);

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
          // Delay to respect API rate limits
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

    // Navigate to custom map viewer
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GeocodedAddressesMapViewer(
          addresses: geocodedAddresses,
          title: 'Pinelands Addresses (${geocodedAddresses.length})',
        ),
      ),
    );
  }

  void _showOptimizedRoute() {
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

    // Show optimization strategy dialog
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Route Optimization'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Optimize route for ${geocodedAddresses.length} addresses'),
            const SizedBox(height: 16),
            const Text(
              'Choose optimization strategy:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '• Nearest Neighbor: Fast, good for quick routes',
              style: TextStyle(fontSize: 12),
            ),
            const Text(
              '• 2-Opt Algorithm: Better optimization, slightly slower',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _optimizeAndShowRoute(geocodedAddresses, use2Opt: false);
            },
            child: const Text('Nearest Neighbor'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _optimizeAndShowRoute(geocodedAddresses, use2Opt: true);
            },
            child: const Text('2-Opt (Better)'),
          ),
        ],
      ),
    );
  }

  void _optimizeAndShowRoute(List<Address> addresses, {required bool use2Opt}) {
    // Show loading
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
                Text('Optimizing route...'),
              ],
            ),
          ),
        ),
      ),
    );

    // Perform optimization in next frame
    Future.delayed(const Duration(milliseconds: 100), () {
      final service = RouteOptimizationService();
      final optimizedRoute = use2Opt
          ? service.optimizeRoute2Opt(addresses)
          : service.optimizeRouteNearestNeighbor(addresses);

      // Close loading dialog
      Navigator.pop(context);

      // Show optimized route on map
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => GeocodedAddressesMapViewer(
            addresses: addresses,
            title: 'Optimized Route (${addresses.length} stops)',
            optimizedRoute: optimizedRoute,
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Geocoding - Pinelands Addresses'),
        actions: [
          if (_addresses.isEmpty)
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Initialize Addresses',
              onPressed: _isLoading ? null : _initializeAddresses,
            ),
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
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'view_map',
                  child: Row(
                    children: [
                      Icon(Icons.map_outlined),
                      SizedBox(width: 8),
                      Text('View on Map'),
                    ],
                  ),
                ),
                const PopupMenuItem(
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
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadAddresses,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_addresses.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.location_off, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'No addresses found',
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 8),
            const Text(
              'Click the + button to initialize Pinelands addresses',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _initializeAddresses,
              icon: const Icon(Icons.add),
              label: const Text('Initialize Addresses'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildStatsBar(),
        Expanded(
          child: _buildAddressList(),
        ),
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
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
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
          Text(
            label,
            style: TextStyle(fontSize: 12, color: color),
          ),
          const SizedBox(width: 8),
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

  List<Map<String, String>> _getPinelandsAddresses() {
    return [
      {
        'streetAddress': '30 RIVERSIDE ROAD',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '19 CULEMBORG 3 MORNINGSIDE STREET',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'No 4 The Bend Pinelands',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '8 Moringa Way Unit 340, Paarl Rock Building',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '32 RIVERSIDE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '22B SPINE BOULVARD',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '43B Jan Smuts Drive Old mutual',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '18 Jan Smuts Drive College of Cape Town',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '14 MAREOLA WAY',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '11 Morningside Road',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '18 Forest Drive Pinelands',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '13 RIVERSIDE STREET',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '1 Jan Smuts Drive Mutual park',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '44 EIKENDAL CLOSE PINELANDS',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'FOREST DRIVE PINELANDS',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '4 THE DELL',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '1 RINGWOOD DRIVE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '7 Broad walk',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress':
            'Block B Millside Park Morningside stre Law Enforcement office',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'CONRADIE PARK PAINLANDS',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'FLAT NO 203 NIGHTNGALE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '16 NIGHTANGLE WAY PINELANDS',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '29 Margaret Avenue',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '14 Pleasant Place',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'A102 Nightingale Close 16 Nightingale Way',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'CONRADIE PARK FOREST DRIVE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '3 HOWARD DRIVE FOUNDERS HOUSE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '8 moringa way',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'Howard Drive',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '36 Links Drive pinelands',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '15 Mareola Way',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'Pick n Pay Pinelands Howard Drive Howard Centre',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'Unit 3 Howard Studios Sheldon Way',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '71 forest drive',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '22 woodside drive pinelands',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '3 GLEN AVON',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '24 LINK DRIVE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '11 Dagbreek road Pinelands',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '15 FIELD CLOSE PINELANDS',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '12 LINNET WAY STREET',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'OLD MUTUAL 4TH FLOOR',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '91 JAN SMUTS DRIVE PINELANDS',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '47 EASTWAY ROAD',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '13 KINGFISHER WALK',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '38 Camp Road',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '12 KING FISHER WALK',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'NO ..7A PEAK DRIVE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '5 BURNSIDE 7 HOWARD DRIVE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '1 Rapenberg road Golf park (RCS)',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'TELKOM 10 JANS SMUTS DRIVE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '104 PINELANDS PLACE LOUNDALE WAY',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '20 Maynard close Pinelands Cape Town',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '4 WATTLE GROOVE STREET',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '2 BROOKDALE AVENUE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '38 WATTLE GROVE EXT',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'MUTUAL PARK JAN SMUT DRIVE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '18 ANFIELD FOREST DRIVE PINELANDS',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '290 Anfield Village Forest Dr',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'D306 WATTLE GROVE PINELAND BARAKS',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '3RD FLOOR PARK ROAD THEPARK BUILDING',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '343 ANFIELD VILLAGE FOREST DRIVE',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '48 Anfield Village Forest Drive Extn',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'Jan Smuts mutual park',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'SAPS WATTLE GROVE CRESCENT',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': 'UNIT 95 ANFIELD VILLAGE FOREST DR EXT',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
      {
        'streetAddress': '59EAST WAY',
        'suburb': 'PINELANDS',
        'city': 'CAPE TOWN',
        'postalCode': '7405',
        'province': 'Western Cape',
        'country': 'South Africa'
      },
    ];
  }
}
