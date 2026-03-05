import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/address_service_v2.dart';
import 'suburb_addresses_screen.dart';
import 'add_suburb_addresses_screen.dart';
import 'master_map_viewer.dart';

/// Main screen showing list of suburbs with address counts
class SuburbListScreen extends StatefulWidget {
  const SuburbListScreen({super.key});

  @override
  State<SuburbListScreen> createState() => _SuburbListScreenState();
}

class _SuburbListScreenState extends State<SuburbListScreen> {
  final AddressServiceV2 _addressService =
      AddressServiceV2(FirebaseFirestore.instance);
  Map<String, Map<String, int>> _suburbStats = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _isLoading = true);

    try {
      final suburbs = await _addressService.getSuburbs();
      final stats = <String, Map<String, int>>{};

      for (final suburb in suburbs) {
        stats[suburb] = await _addressService.getSuburbStats(suburb);
      }

      setState(() {
        _suburbStats = stats;
      });
    } catch (e) {
      debugPrint('Error loading stats: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Geocoding - Suburbs'),
        actions: [
          if (_suburbStats.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.map),
              tooltip: 'View All on Map',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const MasterMapViewer(),
                  ),
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Addresses',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const AddSuburbAddressesScreen(),
                ),
              );
              _loadStats(); // Refresh after adding
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadStats,
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
            Text('Loading suburbs...'),
          ],
        ),
      );
    }

    if (_suburbStats.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.location_city, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'No suburbs found',
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 8),
            const Text(
              'Add addresses to get started',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AddSuburbAddressesScreen(),
                  ),
                );
                _loadStats();
              },
              icon: const Icon(Icons.add),
              label: const Text('Add Addresses'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildStatsBar(),
        Expanded(
          child: ListView.builder(
            itemCount: _suburbStats.length,
            itemBuilder: (context, index) {
              final suburb = _suburbStats.keys.elementAt(index);
              final stats = _suburbStats[suburb]!;
              return _buildSuburbCard(suburb, stats);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStatsBar() {
    int totalAddresses = 0;
    int totalGeocoded = 0;

    for (final stats in _suburbStats.values) {
      totalAddresses += stats['total'] ?? 0;
      totalGeocoded += stats['geocoded'] ?? 0;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.blue.shade50,
      child: Row(
        children: [
          _buildStatChip(
              'Suburbs', _suburbStats.length.toString(), Colors.purple),
          const SizedBox(width: 12),
          _buildStatChip('Total', totalAddresses.toString(), Colors.blue),
          const SizedBox(width: 12),
          _buildStatChip('Geocoded', totalGeocoded.toString(), Colors.green),
          const SizedBox(width: 12),
          _buildStatChip('Pending', (totalAddresses - totalGeocoded).toString(),
              Colors.orange),
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
            style: TextStyle(fontSize: 11, color: color),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuburbCard(String suburb, Map<String, int> stats) {
    final total = stats['total'] ?? 0;
    final geocoded = stats['geocoded'] ?? 0;
    final progress = total > 0 ? geocoded / total : 0.0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: progress == 1.0 ? Colors.green : Colors.blue,
          child: Icon(
            progress == 1.0 ? Icons.check : Icons.location_city,
            color: Colors.white,
          ),
        ),
        title: Text(
          suburb.toUpperCase(),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text('$total addresses • $geocoded geocoded'),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(
                progress == 1.0 ? Colors.green : Colors.blue,
              ),
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        isThreeLine: true,
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SuburbAddressesScreen(suburb: suburb),
            ),
          );
        },
      ),
    );
  }
}
