import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/address.dart';
import '../services/address_service_v2.dart';

/// Master map viewer showing all addresses from all suburbs
class MasterMapViewer extends StatefulWidget {
  const MasterMapViewer({super.key});

  @override
  State<MasterMapViewer> createState() => _MasterMapViewerState();
}

class _MasterMapViewerState extends State<MasterMapViewer> {
  final AddressServiceV2 _addressService =
      AddressServiceV2(FirebaseFirestore.instance);

  GoogleMapController? _mapController;
  List<Address> _allAddresses = [];
  Map<String, List<Address>> _addressesBySuburb = {};
  bool _isLoading = true;
  Set<Marker> _markers = {};
  Address? _selectedAddress;
  String? _filterSuburb;
  bool _showStats = false;

  // Color map for suburbs
  final Map<String, BitmapDescriptor> _suburbColors = {};
  final List<double> _hues = [
    BitmapDescriptor.hueRed,
    BitmapDescriptor.hueOrange,
    BitmapDescriptor.hueYellow,
    BitmapDescriptor.hueGreen,
    BitmapDescriptor.hueCyan,
    BitmapDescriptor.hueBlue,
    BitmapDescriptor.hueViolet,
    BitmapDescriptor.hueMagenta,
  ];

  @override
  void initState() {
    super.initState();
    _loadAllAddresses();
  }

  Future<void> _loadAllAddresses() async {
    setState(() => _isLoading = true);

    try {
      final addresses = await _addressService.getAllAddresses();
      final geocodedAddresses = addresses.where((a) => a.isGeocoded).toList();

      // Group by suburb
      final Map<String, List<Address>> bySuburb = {};
      for (final address in geocodedAddresses) {
        bySuburb
            .putIfAbsent(address.suburb.toLowerCase(), () => [])
            .add(address);
      }

      // Assign colors to suburbs
      int colorIndex = 0;
      for (final suburb in bySuburb.keys) {
        _suburbColors[suburb] = BitmapDescriptor.defaultMarkerWithHue(
          _hues[colorIndex % _hues.length],
        );
        colorIndex++;
      }

      setState(() {
        _allAddresses = geocodedAddresses;
        _addressesBySuburb = bySuburb;
      });

      _createMarkers();
    } catch (e) {
      debugPrint('Error loading addresses: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _createMarkers() {
    final markers = <Marker>{};
    final displayAddresses = _filterSuburb != null
        ? _addressesBySuburb[_filterSuburb] ?? []
        : _allAddresses;

    for (final address in displayAddresses) {
      if (address.latitude == null || address.longitude == null) continue;

      final marker = Marker(
        markerId: MarkerId(address.id),
        position: LatLng(address.latitude!, address.longitude!),
        infoWindow: InfoWindow(
          title: address.streetAddress.isNotEmpty
              ? address.streetAddress
              : address.suburb,
          snippet: address.suburb.toUpperCase(),
        ),
        onTap: () {
          setState(() => _selectedAddress = address);
        },
        icon: _suburbColors[address.suburb.toLowerCase()] ??
            BitmapDescriptor.defaultMarker,
      );

      markers.add(marker);
    }

    setState(() => _markers = markers);
  }

  void _fitBounds() {
    if (_mapController == null || _allAddresses.isEmpty) return;

    final displayAddresses = _filterSuburb != null
        ? _addressesBySuburb[_filterSuburb] ?? []
        : _allAddresses;

    if (displayAddresses.isEmpty) return;

    double minLat = displayAddresses.first.latitude!;
    double maxLat = displayAddresses.first.latitude!;
    double minLng = displayAddresses.first.longitude!;
    double maxLng = displayAddresses.first.longitude!;

    for (final address in displayAddresses) {
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
    if (_allAddresses.isEmpty) {
      return const LatLng(-33.9249, 18.4241); // Cape Town default
    }

    final displayAddresses = _filterSuburb != null
        ? _addressesBySuburb[_filterSuburb] ?? []
        : _allAddresses;

    if (displayAddresses.isEmpty) {
      return const LatLng(-33.9249, 18.4241);
    }

    double totalLat = 0;
    double totalLng = 0;

    for (final address in displayAddresses) {
      totalLat += address.latitude!;
      totalLng += address.longitude!;
    }

    return LatLng(
      totalLat / displayAddresses.length,
      totalLng / displayAddresses.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Master Map')),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading all addresses...'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_filterSuburb != null
            ? '${_filterSuburb!.toUpperCase()} (${_addressesBySuburb[_filterSuburb]?.length ?? 0})'
            : 'Master Map (${_allAddresses.length})'),
        actions: [
          if (_addressesBySuburb.length > 1)
            PopupMenuButton<String?>(
              icon: const Icon(Icons.filter_alt),
              tooltip: 'Filter by Suburb',
              initialValue: _filterSuburb,
              onSelected: (value) {
                setState(() => _filterSuburb = value);
                _createMarkers();
                Future.delayed(const Duration(milliseconds: 100), _fitBounds);
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: null,
                  child: Text('All Suburbs'),
                ),
                const PopupMenuDivider(),
                ..._addressesBySuburb.keys.map((suburb) => PopupMenuItem(
                      value: suburb,
                      child: Text(
                          '${suburb.toUpperCase()} (${_addressesBySuburb[suburb]?.length})'),
                    )),
              ],
            ),
          IconButton(
            icon: Icon(_showStats ? Icons.map : Icons.bar_chart),
            tooltip: _showStats ? 'Show Map' : 'Show Stats',
            onPressed: () {
              setState(() => _showStats = !_showStats);
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
              zoom: 12,
            ),
            markers: _markers,
            onMapCreated: (controller) {
              _mapController = controller;
              Future.delayed(const Duration(milliseconds: 500), _fitBounds);
            },
            myLocationButtonEnabled: true,
            myLocationEnabled: true,
            zoomControlsEnabled: true,
            mapToolbarEnabled: false,
          ),
          if (_selectedAddress != null && !_showStats)
            _buildAddressDetailsPanel(),
          if (_showStats) _buildStatsPanel(),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedAddress!.streetAddress.isNotEmpty
                              ? _selectedAddress!.streetAddress
                              : _selectedAddress!.suburb,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          _selectedAddress!.suburb.toUpperCase(),
                          style: TextStyle(
                              fontSize: 14, color: Colors.blue.shade700),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() => _selectedAddress = null);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(_selectedAddress!.fullAddress,
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatsPanel() {
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
                  const Icon(Icons.analytics, color: Colors.blue),
                  const SizedBox(width: 8),
                  const Text('Statistics',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() => _showStats = false);
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildStatRow('Total Addresses',
                      _allAddresses.length.toString(), Colors.blue),
                  _buildStatRow('Suburbs', _addressesBySuburb.length.toString(),
                      Colors.purple),
                  const Divider(height: 32),
                  const Text('By Suburb:',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 12),
                  ..._addressesBySuburb.entries.map((entry) {
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(Icons.location_city,
                            color: _suburbColors[entry.key] != null
                                ? Colors.blue
                                : Colors.grey),
                        title: Text(entry.key.toUpperCase(),
                            style:
                                const TextStyle(fontWeight: FontWeight.w500)),
                        trailing: Text('${entry.value.length}',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        onTap: () {
                          setState(() {
                            _filterSuburb = entry.key;
                            _showStats = false;
                          });
                          _createMarkers();
                          Future.delayed(
                              const Duration(milliseconds: 100), _fitBounds);
                        },
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 14, color: Colors.grey)),
          ),
          Text(value,
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }
}
