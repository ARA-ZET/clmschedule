// widgets/fleet/fleet_vehicles_view.dart
//
// Fleet → Vehicles: each vehicle's plate, licence disc expiry and last
// renewal, and next service km against the latest odometer reading from
// the drivers' inspections.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:intl/intl.dart' show DateFormat, NumberFormat;

import '../../models/collection_job.dart' show VehicleType;
import '../../models/vehicle_inspection.dart';
import '../../services/vehicle_inspection_service.dart';
import '../../utils/friendly_error.dart';
import '../../utils/schedule_time.dart';
import '../app_toast.dart';
import 'fleet_dashboard.dart';

class FleetVehiclesView extends StatelessWidget {
  final Future<void> Function(FleetVehicle) onSave;
  final Map<String, FleetVehicle> fleet;

  /// Recent inspections — the latest odometer reading per vehicle comes
  /// from these.
  final List<VehicleInspection> inspections;

  const FleetVehiclesView({
    super.key,
    required this.onSave,
    required this.fleet,
    required this.inspections,
  });

  Future<void> _edit(BuildContext context, FleetVehicle vehicle,
      VehicleInspection? lastReading) async {
    final updated = await showDialog<FleetVehicle>(
      context: context,
      builder: (_) =>
          _VehicleEditDialog(vehicle: vehicle, lastReading: lastReading),
    );
    if (updated == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await onSave(updated);
    } catch (e) {
      messenger.showToast(SnackBar(
          content: Text(friendlyFirebaseError(e, action: 'save the vehicle'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final vehicles = [
      for (final t in VehicleType.values)
        fleet[t.name] ?? FleetVehicle(key: t.name, name: t.displayName),
    ];
    final today = scheduleToday();
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            FleetPanel(
              title: 'Vehicles',
              subtitle: 'Plates, licence discs and services. The plate is '
                  'stamped onto every inspection photo.',
              child: Column(children: [
                for (final v in vehicles) ...[
                  if (v != vehicles.first) const SizedBox(height: 12),
                  () {
                    final reading = VehicleInspectionService.latestOdometer(
                        inspections, v.key);
                    return _VehicleRow(
                      vehicle: v,
                      today: today,
                      lastReading: reading,
                      onEdit: () => _edit(context, v, reading),
                    );
                  }(),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _VehicleRow extends StatelessWidget {
  final FleetVehicle vehicle;
  final DateTime today;
  final VehicleInspection? lastReading;
  final VoidCallback onEdit;

  const _VehicleRow({
    required this.vehicle,
    required this.today,
    required this.lastReading,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final v = vehicle;
    final day = DateFormat('d MMM yyyy');
    final km = NumberFormat.decimalPattern();
    final odometer = lastReading?.odometerKm;

    final licenceDue = v.licenceDue(today);
    final serviceDue = v.serviceDue(odometer);

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.local_shipping_rounded,
                      color: scheme.onSurfaceVariant),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(v.name,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      Text(
                        [
                          v.plateNumber.isEmpty
                              ? 'No plate set'
                              : v.plateNumber,
                          if (odometer != null) '${km.format(odometer)} km',
                          if (!v.active) 'Out of service',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Edit ${v.name}',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: onEdit,
                ),
              ]),
              const SizedBox(height: 12),
              LayoutBuilder(builder: (context, box) {
                const gap = 10.0;
                final perRow = box.maxWidth >= 600 ? 3 : 1;
                final w = (box.maxWidth - gap * (perRow - 1)) / perRow;
                return Wrap(spacing: gap, runSpacing: gap, children: [
                  SizedBox(
                    width: w,
                    child: _Fact(
                      label: 'Licence disc expiry',
                      value: v.licenceExpiry == null
                          ? 'Not set'
                          : day.format(v.licenceExpiry!),
                      due: licenceDue,
                      status: licenceStatusText(v, today),
                    ),
                  ),
                  SizedBox(
                    width: w,
                    child: _Fact(
                      label: 'Licence last renewed',
                      value: v.licenceRenewedOn == null
                          ? 'Not set'
                          : day.format(v.licenceRenewedOn!),
                    ),
                  ),
                  SizedBox(
                    width: w,
                    child: _Fact(
                      label: 'Next service',
                      value: v.nextServiceKm == null
                          ? 'Not set'
                          : '${km.format(v.nextServiceKm)} km',
                      due: serviceDue,
                      status: serviceStatusText(v, odometer) ??
                          (v.nextServiceKm != null && odometer == null
                              ? 'No odometer reading yet'
                              : null),
                    ),
                  ),
                ]);
              }),
            ],
          ),
        ),
      ),
    );
  }
}

/// One labelled value with an optional status line (icon + words; the
/// colour is never the only signal).
class _Fact extends StatelessWidget {
  final String label;
  final String value;
  final FleetDue? due;
  final String? status;

  const _Fact({
    required this.label,
    required this.value,
    this.due,
    this.status,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = due == null ? null : dueColor(due!);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: color != null && due != FleetDue.ok
                ? color
                : scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(value,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        if (status != null) ...[
          const SizedBox(height: 4),
          Row(children: [
            Icon(dueIcon(due ?? FleetDue.unknown),
                size: 15, color: color ?? scheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Text(status!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
            ),
          ]),
        ],
      ]),
    );
  }
}

class _VehicleEditDialog extends StatefulWidget {
  final FleetVehicle vehicle;
  final VehicleInspection? lastReading;

  const _VehicleEditDialog({required this.vehicle, this.lastReading});

  @override
  State<_VehicleEditDialog> createState() => _VehicleEditDialogState();
}

class _VehicleEditDialogState extends State<_VehicleEditDialog> {
  late final _plate = TextEditingController(text: widget.vehicle.plateNumber);
  late final _serviceKm = TextEditingController(
      text: widget.vehicle.nextServiceKm?.toString() ?? '');
  late bool _active = widget.vehicle.active;
  late DateTime? _expiry = widget.vehicle.licenceExpiry;
  late DateTime? _renewed = widget.vehicle.licenceRenewedOn;

  @override
  void dispose() {
    _plate.dispose();
    _serviceKm.dispose();
    super.dispose();
  }

  Future<void> _pick({
    required DateTime? current,
    required ValueChanged<DateTime> onPicked,
    required String help,
  }) async {
    final today = scheduleToday();
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? today,
      firstDate: DateTime(today.year - 10),
      lastDate: DateTime(today.year + 5, 12, 31),
      helpText: help,
    );
    if (picked != null) setState(() => onPicked(picked));
  }

  void _save() {
    final km = int.tryParse(_serviceKm.text.trim());
    Navigator.pop(
      context,
      FleetVehicle(
        key: widget.vehicle.key,
        name: widget.vehicle.name,
        plateNumber: _plate.text.trim().toUpperCase(),
        active: _active,
        licenceExpiry: _expiry,
        licenceRenewedOn: _renewed,
        nextServiceKm: km,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final km = NumberFormat.decimalPattern();
    final reading = widget.lastReading;
    return AlertDialog(
      title: Text(widget.vehicle.name),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _plate,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Number plate',
                hintText: 'e.g. CA 123-456',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            _DateField(
              label: 'Licence disc expiry',
              value: _expiry,
              onTap: () => _pick(
                current: _expiry,
                help: 'Licence disc expiry',
                onPicked: (d) => _expiry = d,
              ),
              onClear: () => setState(() => _expiry = null),
            ),
            const SizedBox(height: 16),
            _DateField(
              label: 'Licence last renewed',
              value: _renewed,
              onTap: () => _pick(
                current: _renewed,
                help: 'Licence last renewed',
                onPicked: (d) => _renewed = d,
              ),
              onClear: () => setState(() => _renewed = null),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _serviceKm,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Next service (km)',
                hintText: 'e.g. 95000',
                suffixText: 'km',
                border: const OutlineInputBorder(),
                helperText: reading == null
                    ? 'No odometer reading from an inspection yet'
                    : 'Last reading ${km.format(reading.odometerKm)} km on '
                        '${DateFormat('d MMM').format(DateTime.parse(reading.date))}',
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('In service'),
              subtitle: const Text('Off = hidden from the dashboard'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _DateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.event_rounded),
          suffixIcon: value == null
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: onClear,
                ),
        ),
        isEmpty: value == null,
        child: Text(
            value == null ? '' : DateFormat('EEE d MMM yyyy').format(value!)),
      ),
    );
  }
}
