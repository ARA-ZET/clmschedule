// widgets/regular_clients_screen.dart
//
// The regular-clients library: one row per client, each with its own map
// (copied from a client map in the gallery, which is never changed) and a
// reusable distributor-slot plan. Opening a row shows that map coloured by
// the plan (RegularClientMapAdapter).
import 'package:clmschedule/utils/text_search.dart';
import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/regular_client.dart';
import '../providers/regular_clients_provider.dart';
import '../shareable_maps/adapters/regular_client_map_adapter.dart';
import '../shareable_maps/providers/shareable_map_provider.dart';
import '../shareable_maps/widgets/shareable_map_editor.dart';
import 'map_picker_dialog.dart';

class RegularClientsScreen extends riverpod.ConsumerStatefulWidget {
  const RegularClientsScreen({super.key});

  @override
  riverpod.ConsumerState<RegularClientsScreen> createState() =>
      _RegularClientsScreenState();
}

class _RegularClientsScreenState
    extends riverpod.ConsumerState<RegularClientsScreen> {
  String _query = '';
  bool _busy = false;

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showToast(SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red.shade800 : null,
    ));
  }

  Future<void> _add() async {
    final picked = await showDialog<MapPickerResult>(
      context: context,
      builder: (_) => const MapPickerDialog(),
    );
    if (picked == null || !mounted) return;
    final details = await _editDetails(
      title: 'New regular client',
      name: picked.mapName,
      aliases: const [],
    );
    if (details == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = ref.read(regularClientServiceRiverpod);
      // A copy: the picked map is a real client's, shared in their reports.
      final copy =
          await service.copyFromGallery(picked.monthKey, picked.mapId);
      final draft = RegularClient(
        id: '',
        name: details.$1,
        aliases: details.$2,
        mapId: picked.mapId,
        mapMonthKey: picked.monthKey,
        mapName: picked.mapName,
        map: copy,
      );
      final id = await service.add(draft);
      final created = await service.get(id);
      if (created != null) await _open(created);
    } catch (e) {
      _snack('Could not add the regular client: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(RegularClient client) async {
    final provider = ref.read(shareableMapRiverpod);
    try {
      // Fetch fresh so a plan edited elsewhere since the list loaded is used.
      final fresh =
          await ref.read(regularClientServiceRiverpod).get(client.id) ?? client;
      await provider.loadFromAdapter(RegularClientMapAdapter(
        fresh,
        onReload: provider.applyAdapterMap,
        isBusyEditing: () => provider.isDrawing || provider.isEditingVertices,
      ));
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ShareableMapEditor()),
      );
    } catch (e) {
      _snack('Failed to open ${client.name}: $e', error: true);
    }
  }

  Future<void> _edit(RegularClient client) async {
    final details = await _editDetails(
      title: 'Edit regular client',
      name: client.name,
      aliases: client.aliases,
    );
    if (details == null) return;
    try {
      await ref
          .read(regularClientServiceRiverpod)
          .save(client.copyWith(name: details.$1, aliases: details.$2));
    } catch (e) {
      _snack('Could not save: $e', error: true);
    }
  }

  /// Replace the client's map with a fresh copy of another gallery map. Areas
  /// the new copy shares with the old (same polygon ids — e.g. a later round
  /// of the same client map) keep their allocation.
  Future<void> _changeMap(RegularClient client) async {
    final picked = await showDialog<MapPickerResult>(
      context: context,
      builder: (_) => const MapPickerDialog(),
    );
    if (picked == null) return;
    try {
      final service = ref.read(regularClientServiceRiverpod);
      final copy =
          await service.copyFromGallery(picked.monthKey, picked.mapId);
      await service.save(client.copyWith(
        mapId: picked.mapId,
        mapMonthKey: picked.monthKey,
        mapName: picked.mapName,
      ));
      await service.saveMap(client.id, copy);
      _snack('Map replaced with a copy of ${picked.mapName}. Areas not on '
          'it show as missing.');
    } catch (e) {
      _snack('Could not change the map: $e', error: true);
    }
  }

  Future<void> _delete(RegularClient client) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${client.name}?'),
        content: const Text('The allocation plan and its own map are '
            'deleted. Client maps in the gallery are not touched.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(regularClientServiceRiverpod).delete(client.id);
    } catch (e) {
      _snack('Could not delete: $e', error: true);
    }
  }

  /// Name and aliases (comma separated). Null when cancelled.
  Future<(String, List<String>)?> _editDetails({
    required String title,
    required String name,
    required List<String> aliases,
  }) async {
    final nameCtrl = TextEditingController(text: name);
    final aliasCtrl = TextEditingController(text: aliases.join(', '));
    final result = await showDialog<(String, List<String>)>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Client name',
                  helperText: 'As it is typed on the Job List',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: aliasCtrl,
                decoration: const InputDecoration(
                  labelText: 'Other names (optional)',
                  helperText: 'Comma separated, e.g. "PnP Durbanville, '
                      'Pick n Pay Durbanville"',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final n = nameCtrl.text.trim();
              if (n.isEmpty) return;
              Navigator.of(dialogContext).pop((
                n,
                [
                  for (final a in aliasCtrl.text.split(','))
                    if (a.trim().isNotEmpty) a.trim(),
                ],
              ));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    aliasCtrl.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(regularClientsRiverpod);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Regular Clients'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _busy ? null : _add,
              icon: const Icon(Icons.add),
              label: const Text('Add regular client'),
            ),
          ),
        ],
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load: $e')),
        data: (all) {
          final list = TextSearch(_query)
              .rank(all, (c) => [c.name, c.mapName, ...c.aliases]);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search regular clients',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Text(
                          all.isEmpty
                              ? 'No regular clients yet. Add one from a '
                                  'map in the gallery.'
                              : 'No matches.',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      )
                    : ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) => _row(list[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(RegularClient c) {
    return ListTile(
      leading: SizedBox(
        width: 40,
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [
            for (final s in c.slots.take(6))
              CircleAvatar(radius: 5, backgroundColor: s.color),
            if (c.slots.isEmpty)
              const Icon(Icons.map_outlined, color: Colors.grey),
          ],
        ),
      ),
      title: Text(c.name),
      subtitle: Text(
        '${c.mapName.isEmpty ? 'Own map' : 'Copied from ${c.mapName}'} · '
        '${c.slots.length} distributor${c.slots.length == 1 ? '' : 's'} · '
        '${c.totalManDays} man days'
        '${c.aliases.isEmpty ? '' : ' · also "${c.aliases.join('", "')}"'}',
      ),
      onTap: () => _open(c),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'open':
              _open(c);
            case 'edit':
              _edit(c);
            case 'map':
              _changeMap(c);
            case 'delete':
              _delete(c);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'open', child: Text('Open map')),
          PopupMenuItem(value: 'edit', child: Text('Rename / other names')),
          PopupMenuItem(
              value: 'map', child: Text('Replace map with a copy of…')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
