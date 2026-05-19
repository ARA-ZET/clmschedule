import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/collection_job.dart';
import '../../models/driver.dart';
import '../../providers/driver_provider.dart';

/// Full CRUD UI for the `/drivers` collection.
class DriverManagementDialog extends riverpod.ConsumerWidget {
  const DriverManagementDialog({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final provider = ref.watch(driverRiverpod);
    final drivers = provider.drivers;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.people_outline),
                  const SizedBox(width: 8),
                  const Text(
                    'Manage drivers',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: provider.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : drivers.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'No drivers yet. Add your first driver below.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: drivers.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final d = drivers[i];
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: d.active
                                    ? Colors.blue.shade100
                                    : Colors.grey.shade300,
                                child: Text(
                                  d.name.isEmpty
                                      ? '?'
                                      : d.name[0].toUpperCase(),
                                ),
                              ),
                              title: Text(d.name),
                              subtitle: Text([
                                if (d.phone.isNotEmpty) d.phone,
                                if (d.defaultVehicle != null)
                                  d.defaultVehicle!.displayName,
                                if (d.defaultTrailer != null &&
                                    d.defaultTrailer != TrailerType.noTrailer)
                                  d.defaultTrailer!.displayName,
                                if (!d.active) 'inactive',
                              ].join(' • ')),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 20),
                                    onPressed: () => _editDriver(
                                        context, provider,
                                        driver: d),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 20, color: Colors.red),
                                    onPressed: () =>
                                        _deleteDriver(context, provider, d),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: () => _editDriver(context, provider),
                  icon: const Icon(Icons.add),
                  label: const Text('Add driver'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editDriver(
    BuildContext context,
    DriverProvider provider, {
    Driver? driver,
  }) async {
    final result = await showDialog<Driver>(
      context: context,
      builder: (_) => _DriverFormDialog(initial: driver),
    );
    if (result == null) return;
    if (driver == null) {
      await provider.add(result);
    } else {
      await provider.update(result);
    }
  }

  Future<void> _deleteDriver(
    BuildContext context,
    DriverProvider provider,
    Driver d,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete driver?'),
        content: Text(
            'Delete ${d.name}? Past dropsheets keep their record. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('CANCEL')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('DELETE')),
        ],
      ),
    );
    if (confirm == true) await provider.delete(d.id);
  }
}

class _DriverFormDialog extends StatefulWidget {
  final Driver? initial;
  const _DriverFormDialog({this.initial});

  @override
  State<_DriverFormDialog> createState() => _DriverFormDialogState();
}

class _DriverFormDialogState extends State<_DriverFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  VehicleType? _vehicle;
  TrailerType? _trailer;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _phone = TextEditingController(text: widget.initial?.phone ?? '');
    _vehicle = widget.initial?.defaultVehicle;
    _trailer = widget.initial?.defaultTrailer;
    _active = widget.initial?.active ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.initial == null;
    return AlertDialog(
      title: Text(isNew ? 'Add driver' : 'Edit driver'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone (optional)'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<VehicleType?>(
              initialValue: _vehicle,
              decoration: const InputDecoration(labelText: 'Default vehicle'),
              items: [
                const DropdownMenuItem<VehicleType?>(
                    value: null, child: Text('—')),
                ...VehicleType.values.map(
                  (v) => DropdownMenuItem<VehicleType?>(
                      value: v, child: Text(v.displayName)),
                ),
              ],
              onChanged: (v) => setState(() => _vehicle = v),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<TrailerType?>(
              initialValue: _trailer,
              decoration: const InputDecoration(labelText: 'Default trailer'),
              items: [
                const DropdownMenuItem<TrailerType?>(
                    value: null, child: Text('—')),
                ...TrailerType.values.map(
                  (t) => DropdownMenuItem<TrailerType?>(
                      value: t, child: Text(t.displayName)),
                ),
              ],
              onChanged: (t) => setState(() => _trailer = t),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('Active'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            final id = widget.initial?.id ??
                'd_${DateTime.now().microsecondsSinceEpoch}';
            Navigator.pop(
              context,
              Driver(
                id: id,
                name: name,
                phone: _phone.text.trim(),
                defaultVehicle: _vehicle,
                defaultTrailer: _trailer,
                active: _active,
              ),
            );
          },
          child: const Text('SAVE'),
        ),
      ],
    );
  }
}
