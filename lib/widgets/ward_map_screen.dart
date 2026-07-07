import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../services/ward_data_service.dart';
import '../shareable_maps/adapters/firestore_adapter.dart';
import '../shareable_maps/models/map_layer.dart';
import '../shareable_maps/models/shareable_map.dart';
import '../shareable_maps/providers/shareable_map_provider.dart';
import '../shareable_maps/services/shareable_maps_firestore_service.dart';
import '../shareable_maps/widgets/shareable_map_editor.dart';

/// Screen for downloading SA ward data from the Municipal Demarcation Board
/// and creating a new shareable map with three layers:
///   1. Ward Boundaries
///   2. Voting Districts
///   3. Voting Stations
class WardMapScreen extends riverpod.ConsumerStatefulWidget {
  const WardMapScreen({super.key});

  @override
  riverpod.ConsumerState<WardMapScreen> createState() => _WardMapScreenState();
}

class _WardMapScreenState extends riverpod.ConsumerState<WardMapScreen> {
  final _controller = TextEditingController();
  final _wardNumbers = <int>[];
  bool _isLoading = false;
  String _statusMessage = '';
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _addWardNumbers() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final parsed = text
        .split(RegExp(r'[,\s]+'))
        .where((s) => s.isNotEmpty)
        .map(int.tryParse)
        .where((n) => n != null && n > 0)
        .cast<int>()
        .toList();

    if (parsed.isEmpty) {
      setState(() => _error = 'Enter valid ward numbers (e.g. 54, 57, 92).');
      return;
    }

    setState(() {
      for (final n in parsed) {
        if (!_wardNumbers.contains(n)) _wardNumbers.add(n);
      }
      _wardNumbers.sort();
      _error = null;
      _controller.clear();
    });
  }

  Future<void> _downloadAndCreate() async {
    if (_wardNumbers.isEmpty) {
      setState(() => _error = 'Add at least one ward number first.');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _statusMessage = 'Starting download...';
    });

    try {
      final service = WardDataService();
      final result = await service.fetchWardData(
        List.from(_wardNumbers),
        onStatus: (msg) {
          if (mounted) setState(() => _statusMessage = msg);
        },
      );

      if (!mounted) return;
      setState(() => _statusMessage =
          'Building map: ${result.wardBoundaries.length} ward polygons, '
          '${result.votingDistricts.length} VDs, '
          '${result.votingStations.length} voting stations...');

      // Build Ward Boundaries layer
      var wardLayer = MapLayer.create(
        name: 'Ward Boundaries',
        order: 0,
        defaultColor: Colors.blue,
      );
      for (final p in result.wardBoundaries) {
        wardLayer = wardLayer.addPolygon(p);
      }

      // Build Voting Districts layer
      var vdLayer = MapLayer.create(
        name: 'Voting Districts',
        order: 1,
        defaultColor: Colors.orange,
      );
      for (final p in result.votingDistricts) {
        vdLayer = vdLayer.addPolygon(p);
      }

      // Build Voting Stations layer
      var vsLayer = MapLayer.create(
        name: 'Voting Stations',
        order: 2,
        defaultColor: Colors.green,
      );
      for (final pt in result.votingStations) {
        vsLayer = vsLayer.addPoint(pt);
      }

      final now = DateTime.now();
      final seed = ShareableMap(
        id: 'map_${now.millisecondsSinceEpoch}',
        name: result.mapName,
        description:
            'MDB ward boundaries, voting districts & stations (Cape Town)',
        layers: [wardLayer, vdLayer, vsLayer],
        defaultCenter: result.center,
        defaultZoom: 13.0,
        createdAt: now,
        updatedAt: now,
      );

      setState(() => _statusMessage = 'Saving to gallery...');

      final monthKey = ShareableMapsFirestoreService.monthKeyFor(now);
      final adapter = FirestoreMapAdapter.create(
        seed: seed,
        monthKey: monthKey,
        service: ShareableMapsFirestoreService(),
      );

      final mapProvider = ref.read(shareableMapRiverpod);
      await mapProvider.loadFromAdapter(adapter);
      await mapProvider.saveToAdapter();

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ShareableMapEditor()),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SA Ward Mapper')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter Cape Town ward numbers to download ward boundaries, '
              'voting districts, and voting stations from the Municipal '
              'Demarcation Board. A new map will be created in your gallery.',
              style: TextStyle(color: Colors.black54, height: 1.5),
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      labelText: 'Ward numbers',
                      hintText: 'e.g. 54, 57, 92',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    enabled: !_isLoading,
                    onSubmitted: (_) => _addWardNumbers(),
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _addWardNumbers,
                    child: const Text('Add'),
                  ),
                ),
              ],
            ),
            if (_wardNumbers.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _wardNumbers
                    .map((w) => Chip(
                          label: Text('Ward $w'),
                          onDeleted: _isLoading ? null : () {
                            setState(() => _wardNumbers.remove(w));
                          },
                        ))
                    .toList(),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isLoading ? null : _downloadAndCreate,
                icon: const Icon(Icons.download_rounded),
                label: const Text('Download & Create Map'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            if (_isLoading) ...[
              const SizedBox(height: 28),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  _statusMessage,
                  style: const TextStyle(color: Colors.black54),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
