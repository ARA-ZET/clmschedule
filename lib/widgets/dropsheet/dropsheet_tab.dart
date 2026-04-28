import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/collection_job.dart';
import '../../models/driver.dart';
import '../../models/dropsheet_day.dart';
import '../../models/dropsheet_task.dart';
import '../../providers/driver_provider.dart';
import '../../providers/dropsheet_provider.dart';
import 'driver_management_dialog.dart';
import 'driver_section_widget.dart';

/// Main Dropsheet screen.
///
/// Layout:
///   - Top bar: date picker + previous/next day buttons + manage drivers
///   - Body: vertically stacked driver sections (each is a reorderable
///     task list). Tasks can also be dragged between sections.
class DropsheetTab extends riverpod.ConsumerWidget {
  const DropsheetTab({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final dropsheet = ref.watch(dropsheetRiverpod);
    final drivers = ref.watch(driverRiverpod);
    final day = dropsheet.day;

    return Column(
      children: [
        _TopBar(
          date: dropsheet.date,
          onDateChanged: dropsheet.setDate,
          onAddDriver: () => _showAddDriverSection(context, ref),
          onManageDrivers: () => showDialog(
            context: context,
            builder: (_) => const DriverManagementDialog(),
          ),
          onSyncFromSchedule: () async {
            await dropsheet.syncFromSchedule();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Synced new stops from schedule.')),
              );
            }
          },
          driversAvailable:
              drivers.activeDrivers.length > day.sections.length,
        ),
        const Divider(height: 1),
        Expanded(
          child: dropsheet.isLoading && day.sections.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : day.sections.isEmpty
                  ? _EmptyState(
                      onAddDriver: () => _showAddDriverSection(context, ref),
                      hasDrivers: drivers.activeDrivers.isNotEmpty,
                      onManageDrivers: () => showDialog(
                        context: context,
                        builder: (_) => const DriverManagementDialog(),
                      ),
                    )
                  : _DropsheetBody(day: day),
        ),
      ],
    );
  }

  Future<void> _showAddDriverSection(
      BuildContext context, riverpod.WidgetRef ref) async {
    final drivers = ref.read(driverRiverpod);
    final dropsheet = ref.read(dropsheetRiverpod);
    final used = dropsheet.day.sections.map((s) => s.driverId).toSet();
    final available =
        drivers.activeDrivers.where((d) => !used.contains(d.id)).toList();

    if (available.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'All active drivers are already on this dropsheet. Add more drivers from "Manage drivers".'),
          ),
        );
      }
      return;
    }

    Driver? selectedDriver = available.first;
    VehicleType? vehicle = selectedDriver.defaultVehicle;
    TrailerType? trailer =
        selectedDriver.defaultTrailer ?? TrailerType.noTrailer;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Add driver to dropsheet'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<Driver>(
                value: selectedDriver,
                decoration: const InputDecoration(labelText: 'Driver'),
                items: available
                    .map((d) =>
                        DropdownMenuItem(value: d, child: Text(d.name)))
                    .toList(),
                onChanged: (d) => setState(() {
                  selectedDriver = d;
                  vehicle = d?.defaultVehicle;
                  trailer = d?.defaultTrailer ?? TrailerType.noTrailer;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<VehicleType>(
                value: vehicle,
                decoration: const InputDecoration(labelText: 'Vehicle'),
                items: VehicleType.values
                    .map((v) => DropdownMenuItem(
                          value: v,
                          child: Text(v.displayName),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => vehicle = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<TrailerType>(
                value: trailer,
                decoration: const InputDecoration(labelText: 'Trailer'),
                items: TrailerType.values
                    .map((t) => DropdownMenuItem(
                          value: t,
                          child: Text(t.displayName),
                        ))
                    .toList(),
                onChanged: (t) => setState(() => trailer = t),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('ADD'),
            ),
          ],
        ),
      ),
    );

    if (result != true || selectedDriver == null) return;
    await dropsheet.addDriverSection(
      selectedDriver!,
      vehicle: vehicle,
      trailer: trailer,
    );
  }
}

class _TopBar extends StatelessWidget {
  final DateTime date;
  final ValueChanged<DateTime> onDateChanged;
  final VoidCallback onAddDriver;
  final VoidCallback onManageDrivers;
  final VoidCallback onSyncFromSchedule;
  final bool driversAvailable;

  const _TopBar({
    required this.date,
    required this.onDateChanged,
    required this.onAddDriver,
    required this.onManageDrivers,
    required this.onSyncFromSchedule,
    required this.driversAvailable,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            color: Colors.white,
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous day',
            onPressed: () =>
                onDateChanged(date.subtract(const Duration(days: 1))),
          ),
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: date,
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );
              if (picked != null) onDateChanged(picked);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                DateFormat('d MMMM yyyy').format(date),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          IconButton(
            color: Colors.white,
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next day',
            onPressed: () =>
                onDateChanged(date.add(const Duration(days: 1))),
          ),
          const Spacer(),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white54),
            ),
            onPressed: onSyncFromSchedule,
            icon: const Icon(Icons.sync),
            label: const Text('Sync schedule'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white54),
            ),
            onPressed: onManageDrivers,
            icon: const Icon(Icons.people_outline),
            label: const Text('Drivers'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: driversAvailable ? onAddDriver : null,
            icon: const Icon(Icons.person_add),
            label: const Text('Add driver'),
          ),
        ],
      ),
    );
  }
}

class _DropsheetBody extends riverpod.ConsumerWidget {
  final DropsheetDay day;
  const _DropsheetBody({required this.day});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: day.sections.length,
      itemBuilder: (context, index) {
        final section = day.sections[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: DriverSectionWidget(
            section: section,
            allSections: day.sections,
            onAcceptCrossSectionDrop: (payload) async {
              await ref.read(dropsheetRiverpod).moveTask(
                    fromSectionId: payload.fromSectionId,
                    fromIndex: payload.fromIndex,
                    toSectionId: section.id,
                    toIndex: payload.toIndex,
                  );
            },
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAddDriver;
  final VoidCallback onManageDrivers;
  final bool hasDrivers;

  const _EmptyState({
    required this.onAddDriver,
    required this.onManageDrivers,
    required this.hasDrivers,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.assignment_outlined,
              size: 80, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            'No drivers on this dropsheet yet',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            hasDrivers
                ? 'Tap "Add driver" to start prepping the day.'
                : 'Add a driver in "Manage drivers" first, then come back.',
            style: TextStyle(color: Colors.grey.shade600),
          ),
          const SizedBox(height: 16),
          if (hasDrivers)
            FilledButton.icon(
              onPressed: onAddDriver,
              icon: const Icon(Icons.person_add),
              label: const Text('Add driver'),
            )
          else
            FilledButton.icon(
              onPressed: onManageDrivers,
              icon: const Icon(Icons.people_outline),
              label: const Text('Manage drivers'),
            ),
        ],
      ),
    );
  }
}

/// Internal payload used when a task is dragged from one section into another.
class TaskDragPayload {
  final String fromSectionId;
  final int fromIndex;
  final int toIndex;
  final DropsheetTask task;

  const TaskDragPayload({
    required this.fromSectionId,
    required this.fromIndex,
    required this.toIndex,
    required this.task,
  });
}
