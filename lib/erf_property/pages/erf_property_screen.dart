import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../shareable_maps/providers/shareable_map_provider.dart';
import '../../shareable_maps/widgets/shareable_map_editor.dart';
import '../adapters/erf_property_adapter.dart';
import '../models/erf_property.dart';
import '../providers/erf_property_provider.dart';

/// Main screen for the ERF Property Viewer.
///
/// Shows a list of loaded properties with controls to fetch suburb data.
/// The "View on Map" button opens the ShareableMapEditor with the
/// [ErfPropertyAdapter].
class ErfPropertyScreen extends StatefulWidget {
  const ErfPropertyScreen({super.key});

  @override
  State<ErfPropertyScreen> createState() => _ErfPropertyScreenState();
}

class _ErfPropertyScreenState extends State<ErfPropertyScreen> {
  final _addressController = TextEditingController();
  ErfProperty? _searchResult;
  bool _isSearching = false;
  String? _searchError;
  bool _initialized = false;

  // Predefined suburb bounding boxes for quick loading
  static const _suburbs = <String, Map<String, double>>{
    'Kensington': {
      'minLat': -33.9120,
      'minLng': 18.5050,
      'maxLat': -33.8980,
      'maxLng': 18.5220,
    },
    'Maitland': {
      'minLat': -33.9220,
      'minLng': 18.4950,
      'maxLat': -33.9050,
      'maxLng': 18.5120,
    },
    'Factreton': {
      'minLat': -33.9150,
      'minLng': 18.5000,
      'maxLat': -33.9050,
      'maxLng': 18.5100,
    },
    'Windermere': {
      'minLat': -33.9050,
      'minLng': 18.5000,
      'maxLat': -33.8950,
      'maxLng': 18.5150,
    },
    'Woodstock': {
      'minLat': -33.9350,
      'minLng': 18.4450,
      'maxLat': -33.9200,
      'maxLng': 18.4650,
    },
  };

  @override
  void initState() {
    super.initState();
    final provider = context.read<ErfPropertyProvider>();
    if (!_initialized) {
      provider.initialize();
      _initialized = true;
    }
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _searchAddress() async {
    final address = _addressController.text.trim();
    if (address.isEmpty) return;

    setState(() {
      _isSearching = true;
      _searchResult = null;
      _searchError = null;
    });

    final provider = context.read<ErfPropertyProvider>();
    final result = await provider.findPropertyByAddress(address);

    setState(() {
      _isSearching = false;
      _searchResult = result;
      if (result == null) {
        _searchError = 'No ERF found for "$address"';
      }
    });
  }

  Future<void> _loadSuburb(String name, Map<String, double> bounds) async {
    final provider = context.read<ErfPropertyProvider>();
    final count = await provider.fetchAndSaveArea(
      minLat: bounds['minLat']!,
      minLng: bounds['minLng']!,
      maxLat: bounds['maxLat']!,
      maxLng: bounds['maxLng']!,
      suburb: name,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loaded $count ERF properties for $name')),
      );
    }
  }

  Future<void> _openMap({
    List<ErfProperty>? properties,
    String? suburb,
  }) async {
    final mapProvider = context.read<ShareableMapProvider>();
    final erfProvider = context.read<ErfPropertyProvider>();

    final adapter = ErfPropertyAdapter(
      preloadedProperties: properties ?? erfProvider.properties,
      suburbFilter: suburb,
    );

    try {
      await mapProvider.loadFromAdapter(adapter);
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ShareableMapEditor()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening map: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ERF Property Viewer'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.download),
            tooltip: 'Load suburb ERFs',
            onSelected: (suburb) {
              final bounds = _suburbs[suburb]!;
              _loadSuburb(suburb, bounds);
            },
            itemBuilder: (_) => _suburbs.keys
                .map((s) => PopupMenuItem(value: s, child: Text(s)))
                .toList(),
          ),
        ],
      ),
      body: Consumer<ErfPropertyProvider>(
        builder: (context, provider, _) {
          return Column(
            children: [
              // Search bar
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _addressController,
                        decoration: const InputDecoration(
                          hintText:
                              'Search address (e.g. 10 Main Road, Kensington)',
                          border: OutlineInputBorder(),
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onSubmitted: (_) => _searchAddress(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _isSearching ? null : _searchAddress,
                      icon: _isSearching
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search),
                    ),
                  ],
                ),
              ),

              // Search result card
              if (_searchResult != null)
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  color: Colors.teal.shade50,
                  child: ListTile(
                    leading:
                        const Icon(Icons.location_on, color: Colors.teal),
                    title: Text(_searchResult!.displayLabel),
                    subtitle: Text(
                      'ERF ${_searchResult!.erfNumber} · ${_searchResult!.minRegion}\n'
                      '${_searchResult!.area.toStringAsFixed(1)} m² · LPI: ${_searchResult!.lpiCode}',
                    ),
                    isThreeLine: true,
                    trailing: IconButton(
                      icon: const Icon(Icons.map, color: Colors.teal),
                      tooltip: 'View on map',
                      onPressed: () =>
                          _openMap(properties: [_searchResult!]),
                    ),
                  ),
                ),

              if (_searchError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(_searchError!,
                      style: const TextStyle(color: Colors.red)),
                ),

              const Divider(height: 24),

              // Loading indicator
              if (provider.isLoading)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(
                          'Fetching ERF data... ${provider.totalFetched} properties'),
                    ],
                  ),
                ),

              if (provider.error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Error: ${provider.error}',
                      style: const TextStyle(color: Colors.red)),
                ),

              // View on Map button
              if (provider.properties.isNotEmpty && !provider.isLoading)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Text(
                        '${provider.properties.length} properties',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: () => _openMap(),
                        icon: const Icon(Icons.map),
                        label: const Text('View on Map'),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 4),

              // Properties list
              Expanded(
                child: provider.properties.isEmpty && !provider.isLoading
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.location_city,
                                size: 64, color: Colors.grey.shade400),
                            const SizedBox(height: 16),
                            const Text(
                              'No properties loaded yet',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Use the download button to load ERF data\nfor a suburb, or search an address above.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: provider.properties.length,
                        itemBuilder: (context, index) {
                          final property = provider.properties[index];
                          return ListTile(
                            dense: true,
                            title: Text(property.displayLabel),
                            subtitle: Text(
                              '${property.minRegion} · ${property.area.toStringAsFixed(1)} m²'
                              '${property.suburb != null ? ' · ${property.suburb}' : ''}',
                            ),
                            trailing: Text(
                              'ERF ${property.erfNumber}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                  color: Colors.teal),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
