import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/address.dart';
import '../../services/route_planner_service.dart';
import 'geocode_ui.dart';

/// Bottom sheet for choosing how a run should be planned.
///
/// Returns the chosen [RoutePlanOptions], or null if dismissed. Nothing
/// here starts work — the caller owns the run so it can show inline
/// progress and stay cancellable.
class RouteOptionsSheet extends StatefulWidget {
  final RoutePlanOptions initial;
  final int stopCount;
  final List<Address> depots;

  /// Invoked when the user asks to save the current map centre (or a
  /// typed address) as a new depot. Returns the created depot.
  final Future<Address?> Function()? onCreateDepot;

  const RouteOptionsSheet({
    super.key,
    required this.initial,
    required this.stopCount,
    this.depots = const [],
    this.onCreateDepot,
  });

  static Future<RoutePlanOptions?> show(
    BuildContext context, {
    required RoutePlanOptions initial,
    required int stopCount,
    List<Address> depots = const [],
    Future<Address?> Function()? onCreateDepot,
  }) {
    return showModalBottomSheet<RoutePlanOptions>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (_) => RouteOptionsSheet(
        initial: initial,
        stopCount: stopCount,
        depots: depots,
        onCreateDepot: onCreateDepot,
      ),
    );
  }

  @override
  State<RouteOptionsSheet> createState() => _RouteOptionsSheetState();
}

class _RouteOptionsSheetState extends State<RouteOptionsSheet> {
  /// The dropdown throws if its value is absent from its items, so a
  /// depot that has since been deleted falls back to "first stop".
  late Address? _depot = widget.depots.any((d) => d.id == widget.initial.depot?.id)
      ? widget.initial.depot
      : null;

  late RouteAlgorithm _algorithm = widget.initial.algorithm;
  late bool _returnToStart = widget.initial.returnToStart;
  late bool _useTraffic = widget.initial.useTraffic;
  late TimeOfDay? _departTime = widget.initial.departAt == null
      ? const TimeOfDay(hour: 8, minute: 0)
      : TimeOfDay.fromDateTime(widget.initial.departAt!);
  late int _serviceMinutes = widget.initial.serviceTimePerStop.inMinutes;
  late List<Address> _depots = List.of(widget.depots);

  /// Requests the planner will send, so the API cost is visible up front.
  int get _estimatedRequests => RoutePlannerService.chunkCountFor(
        widget.stopCount +
            (_depot != null ? 1 : 0) +
            (_returnToStart ? 1 : 0),
      );

  DateTime? get _departAt {
    if (_departTime == null) return null;
    final now = DateTime.now();
    return DateTime(
      now.year,
      now.month,
      now.day,
      _departTime!.hour,
      _departTime!.minute,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          bottom: 20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.route_rounded, color: GeocodeColors.brand),
                const SizedBox(width: 10),
                Text(
                  'Plan the run',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${widget.stopCount} stops',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
            const SizedBox(height: 18),

            _label(context, 'Ordering'),
            const SizedBox(height: 8),
            ...RouteAlgorithm.values.map(_algorithmTile),

            const Divider(height: 32),

            _label(context, 'Start & finish'),
            const SizedBox(height: 8),
            _depotSelector(context),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _returnToStart,
              onChanged: (v) => setState(() => _returnToStart = v),
              title: const Text('Return to start'),
              subtitle: const Text(
                  'Adds the drive home so the day\'s total is honest.'),
            ),

            const Divider(height: 32),

            _label(context, 'Timing'),
            const SizedBox(height: 8),
            _departureRow(context),
            const SizedBox(height: 8),
            _serviceTimeRow(context),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _useTraffic,
              onChanged: _departTime == null
                  ? null
                  : (v) => setState(() => _useTraffic = v),
              title: const Text('Traffic-aware durations'),
              subtitle: Text(
                _departTime == null
                    ? 'Set a departure time to enable traffic estimates.'
                    : 'Uses Google\'s predicted traffic for the departure time.',
              ),
            ),

            const SizedBox(height: 12),
            _costNote(context),
            const SizedBox(height: 18),

            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: widget.stopCount < 2
                      ? null
                      : () => Navigator.of(context).pop(
                            RoutePlanOptions(
                              depot: _depot,
                              returnToStart: _returnToStart,
                              departAt: _departAt,
                              serviceTimePerStop:
                                  Duration(minutes: _serviceMinutes),
                              algorithm: _algorithm,
                              useTraffic: _useTraffic && _departTime != null,
                            ),
                          ),
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: const Text('Optimise route'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).hintColor,
            ),
      );

  Widget _algorithmTile(RouteAlgorithm algorithm) {
    final selected = _algorithm == algorithm;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _algorithm = algorithm),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected
              ? GeocodeColors.brand.withValues(alpha: 0.08)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? GeocodeColors.brand
                : Theme.of(context).dividerColor,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected
                  ? GeocodeColors.brand
                  : Theme.of(context).hintColor,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        algorithm.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (algorithm == RouteAlgorithm.googleOptimized) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: GeocodeColors.success.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'RECOMMENDED',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: GeocodeColors.success,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    algorithm.description,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _depotSelector(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _depot?.id,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Start from',
              border: OutlineInputBorder(),
              isDense: true,
              prefixIcon: Icon(Icons.warehouse_rounded, size: 20),
            ),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('First stop on the list'),
              ),
              for (final depot in _depots)
                DropdownMenuItem(
                  value: depot.id,
                  child: Text(depot.displayName, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) => setState(() {
              _depot = id == null
                  ? null
                  : _depots.firstWhere((d) => d.id == id);
            }),
          ),
        ),
        if (widget.onCreateDepot != null) ...[
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Add a depot',
            icon: const Icon(Icons.add_location_alt_outlined),
            onPressed: () async {
              final created = await widget.onCreateDepot!.call();
              if (created == null || !mounted) return;
              setState(() {
                _depots = [..._depots.where((d) => d.id != created.id), created]
                  ..sort((a, b) => a.displayName.compareTo(b.displayName));
                _depot = created;
              });
            },
          ),
        ],
      ],
    );
  }

  Widget _departureRow(BuildContext context) {
    final formatted = _departTime == null
        ? 'Not set'
        : DateFormat('HH:mm').format(DateTime(2000, 1, 1, _departTime!.hour,
            _departTime!.minute));
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: _departTime ?? const TimeOfDay(hour: 8, minute: 0),
              );
              if (picked != null) setState(() => _departTime = picked);
            },
            icon: const Icon(Icons.schedule_rounded, size: 18),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text('Depart at  $formatted'),
            ),
          ),
        ),
        if (_departTime != null)
          IconButton(
            tooltip: 'Clear departure time',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() {
              _departTime = null;
              _useTraffic = false;
            }),
          ),
      ],
    );
  }

  Widget _serviceTimeRow(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.timer_outlined, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Time at each stop: $_serviceMinutes min'),
              Slider(
                value: _serviceMinutes.toDouble(),
                min: 0,
                max: 30,
                divisions: 30,
                label: '$_serviceMinutes min',
                onChanged: (v) => setState(() => _serviceMinutes = v.round()),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _costNote(BuildContext context) {
    final requests = _estimatedRequests;
    final naive = (widget.stopCount + (_depot != null ? 1 : 0)) - 1;
    final saved = naive > requests && requests > 0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: GeocodeColors.brand.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: GeocodeColors.brand.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: GeocodeColors.brand),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Roads and durations come back in $requests Directions '
              'request${requests == 1 ? '' : 's'}'
              '${saved ? ' instead of $naive one-leg-at-a-time calls' : ''}.',
              style: const TextStyle(fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
