// widgets/fleet/fleet_dashboard.dart
//
// The Fleet dashboard body: headline tiles for the chosen day, one card per
// vehicle (start + end of day), the review queue, a 14-day completion trend
// and the latest defects. Pure UI — FleetScreen supplies the data — so it
// can be rendered in tests.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;

import '../../models/collection_job.dart' show VehicleType;
import '../../models/dropsheet_task_type_config.dart';
import '../../models/vehicle_inspection.dart';
import '../../services/vehicle_inspection_service.dart';
import '../../utils/schedule_time.dart';

// ── Tokens ─────────────────────────────────────────────────────────────────
// Status colours are reserved for state and always paired with an icon and
// a label; text stays in the theme's ink, never the status colour.

abstract final class FleetColors {
  static const good = Color(0xFF0CA30C);
  static const warning = Color(0xFFFAB219);
  static const serious = Color(0xFFEC835A);
  static const critical = Color(0xFFD03B3B);

  static Color accent(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF3987E5)
          : const Color(0xFF2A78D6);
}

/// How one shift's inspection stands, for icon + label + colour.
enum ShiftState {
  approved('Approved', Icons.check_circle_rounded),
  needsReview('Needs review', Icons.hourglass_top_rounded),
  rejected('Rejected', Icons.cancel_rounded),
  missing('Not done', Icons.error_outline_rounded),
  dueLater('Due later', Icons.schedule_rounded),
  notOut('Not on the dropsheet', Icons.remove_circle_outline_rounded);

  const ShiftState(this.label, this.icon);
  final String label;
  final IconData icon;

  Color color(BuildContext context) => switch (this) {
        approved => FleetColors.good,
        needsReview => FleetColors.accent(context),
        rejected => FleetColors.critical,
        missing => FleetColors.serious,
        dueLater || notOut => Theme.of(context).colorScheme.outline,
      };
}

Color severityColor(DefectSeverity s) => switch (s) {
      DefectSeverity.minor => FleetColors.warning,
      DefectSeverity.major => FleetColors.serious,
      DefectSeverity.unsafe => FleetColors.critical,
    };

/// Status colour for a licence disc or service; null when not set.
Color? dueColor(FleetDue due) => switch (due) {
      FleetDue.overdue => FleetColors.critical,
      FleetDue.soon => FleetColors.warning,
      FleetDue.ok => FleetColors.good,
      FleetDue.unknown => null,
    };

IconData dueIcon(FleetDue due) => switch (due) {
      FleetDue.overdue => Icons.error_rounded,
      FleetDue.soon => Icons.schedule_rounded,
      FleetDue.ok => Icons.check_circle_rounded,
      FleetDue.unknown => Icons.help_outline_rounded,
    };

/// "Disc expires in 12 days", "Disc expired 3 days ago"…; null when unset.
String? licenceStatusText(FleetVehicle v, DateTime today) {
  final days = v.daysToLicenceExpiry(today);
  if (days == null) return null;
  String n(int d) => '$d day${d == 1 ? '' : 's'}';
  if (days < -1) return 'Disc expired ${n(-days)} ago';
  if (days == -1) return 'Disc expired yesterday';
  if (days == 0) return 'Disc expires today';
  if (days == 1) return 'Disc expires tomorrow';
  return v.licenceDue(today) == FleetDue.soon
      ? 'Disc expires in ${n(days)}'
      : 'Disc valid · ${n(days)} left';
}

/// "Service in 800 km", "Service overdue by 300 km"…; null when either the
/// due reading or the odometer is unknown.
String? serviceStatusText(FleetVehicle v, int? odometerKm) {
  final left = v.kmToService(odometerKm);
  if (left == null) return null;
  final km = NumberFormat.decimalPattern();
  if (left < 0) return 'Service overdue by ${km.format(-left)} km';
  if (left == 0) return 'Service due now';
  return 'Service in ${km.format(left)} km';
}

String vehicleName(String key) {
  for (final v in VehicleType.values) {
    if (v.name == key) return v.displayName;
  }
  return key;
}

// ── Data ───────────────────────────────────────────────────────────────────

class FleetDashboardData {
  /// The day the dashboard is about (schedule civil date).
  final DateTime date;

  /// Inspections from 29 days before [date] up to [date].
  final List<VehicleInspection> inspections;

  /// dateKey → vehicleKey → driver name, from each day's dropsheet: which
  /// vehicles were out and so owed inspections. A missing day = unknown.
  final Map<String, Map<String, String>> roster;

  final Map<String, FleetVehicle> fleet;
  final DepotConfig? depot;

  /// Schedule civil "now" — decides whether a shift is overdue or due later.
  final DateTime now;

  FleetDashboardData({
    required this.date,
    required this.inspections,
    required this.roster,
    required this.fleet,
    this.depot,
    required this.now,
  }) : flags = {
          for (final i in inspections)
            i.id: VehicleInspectionService.flagsFor(i,
                history: inspections, depot: depot),
        };

  final Map<String, Set<InspectionFlag>> flags;

  String get dateKey => VehicleInspectionService.dateKey(date);

  List<VehicleInspection> on(String key) =>
      inspections.where((i) => i.date == key).toList();

  VehicleInspection? find(String key, String vehicle, InspectionKind kind) {
    for (final i in inspections) {
      if (i.date == key && i.vehicleKey == vehicle && i.kind == kind) return i;
    }
    return null;
  }

  /// Vehicles shown for [date]: every known vehicle unless the fleet list
  /// marks it inactive, plus any seen on the dropsheet or in a record.
  List<String> get vehicleKeys {
    final keys = <String>{
      for (final v in VehicleType.values)
        if (fleet[v.name]?.active ?? true) v.name,
      ...?roster[dateKey]?.keys,
      for (final i in on(dateKey)) i.vehicleKey,
    };
    return keys.toList();
  }

  bool isOut(String vehicle) => roster[dateKey]?.containsKey(vehicle) ?? true;

  ShiftState stateFor(String vehicle, InspectionKind kind) {
    final i = find(dateKey, vehicle, kind);
    if (i != null) {
      return switch (i.review.status) {
        InspectionReviewStatus.approved => ShiftState.approved,
        InspectionReviewStatus.rejected => ShiftState.rejected,
        InspectionReviewStatus.pending => ShiftState.needsReview,
      };
    }
    if (!isOut(vehicle)) return ShiftState.notOut;
    final today = DateTime(now.year, now.month, now.day);
    if (date.isBefore(today)) return ShiftState.missing;
    if (date.isAfter(today)) return ShiftState.dueLater;
    if (kind == InspectionKind.start) {
      final parts = (depot?.startTime ?? '07:30').split(':');
      final leave = DateTime(
          now.year,
          now.month,
          now.day,
          int.tryParse(parts.first) ?? 7,
          parts.length > 1 ? int.tryParse(parts[1]) ?? 30 : 30);
      return now.isAfter(leave) ? ShiftState.missing : ShiftState.dueLater;
    }
    return now.hour >= 18 ? ShiftState.missing : ShiftState.dueLater;
  }

  /// Pending inspections, the ones needing attention first, then oldest.
  List<VehicleInspection> get reviewQueue {
    final pending = inspections
        .where((i) => i.review.status == InspectionReviewStatus.pending)
        .toList();
    int weight(VehicleInspection i) =>
        i.isUnsafe ? 0 : (flags[i.id]!.isNotEmpty || i.hasDefects ? 1 : 2);
    pending.sort((a, b) {
      final w = weight(a).compareTo(weight(b));
      if (w != 0) return w;
      return '${a.date}${a.kind.index}'.compareTo('${b.date}${b.kind.index}');
    });
    return pending;
  }
}

// ── Dashboard ──────────────────────────────────────────────────────────────

class FleetDashboard extends StatelessWidget {
  final FleetDashboardData data;
  final void Function(VehicleInspection) onOpen;
  final Future<void> Function(VehicleInspection) onQuickApprove;
  final Future<String?> Function(String path) photoUrl;

  const FleetDashboard({
    super.key,
    required this.data,
    required this.onOpen,
    required this.onQuickApprove,
    required this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 1100;
      final vehicles = _VehiclesToday(
          data: data, onOpen: onOpen, photoUrl: photoUrl, wide: wide);
      final queue = _ReviewQueue(
          data: data, onOpen: onOpen, onQuickApprove: onQuickApprove);
      final trend = _TrendCard(data: data);
      final defects = _RecentDefects(data: data, onOpen: onOpen);

      return ListView(
        padding: EdgeInsets.symmetric(
            horizontal: wide ? 24 : 12, vertical: wide ? 20 : 12),
        children: [
          _KpiRow(data: data),
          const SizedBox(height: 16),
          if (wide) ...[
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: vehicles),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: queue),
            ]),
            const SizedBox(height: 16),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: trend),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: defects),
            ]),
          ] else ...[
            queue,
            const SizedBox(height: 16),
            vehicles,
            const SizedBox(height: 16),
            trend,
            const SizedBox(height: 16),
            defects,
          ],
        ],
      );
    });
  }
}

/// Rounded, hairline-bordered surface every dashboard block sits on.
class FleetPanel extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  const FleetPanel({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 20),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ]),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

// ── KPI row ────────────────────────────────────────────────────────────────

class _KpiRow extends StatelessWidget {
  final FleetDashboardData data;
  const _KpiRow({required this.data});

  @override
  Widget build(BuildContext context) {
    final keys = data.vehicleKeys.where(data.isOut).toList();
    int done(InspectionKind k) =>
        keys.where((v) => data.find(data.dateKey, v, k) != null).length;
    final today = data.on(data.dateKey);
    final defects = today.expand((i) => i.defects).toList();
    final unsafe =
        defects.where((d) => d.severity == DefectSeverity.unsafe).length;
    final flagged = today.where((i) => data.flags[i.id]!.isNotEmpty).length;
    final queue = data.reviewQueue;
    final oldest = queue.isEmpty
        ? null
        : queue
            .map((i) => i.date)
            .reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
    final startDone = done(InspectionKind.start);

    final tiles = [
      _StatTile(
        label: 'Inspected',
        value: '$startDone of ${keys.length}',
        caption: keys.isEmpty
            ? 'No vehicles on the dropsheet'
            : '${keys.length} vehicle${keys.length == 1 ? '' : 's'} out',
        icon: Icons.wb_twilight_rounded,
        iconColor: FleetColors.accent(context),
        meter: keys.isEmpty ? null : startDone / keys.length,
      ),
      _StatTile(
        label: 'To review',
        value: NumberFormat.decimalPattern().format(queue.length),
        caption: oldest == null
            ? 'All caught up'
            : 'Oldest from ${_shortDate(oldest)}',
        icon: Icons.inbox_rounded,
        iconColor:
            queue.isEmpty ? FleetColors.good : FleetColors.accent(context),
      ),
      _StatTile(
        label: 'Defects',
        value: '${defects.length}',
        caption: unsafe > 0
            ? '$unsafe unsafe — vehicle must not drive'
            : defects.isEmpty
                ? 'None on this day'
                : 'None unsafe',
        icon: unsafe > 0 ? Icons.dangerous_rounded : Icons.build_rounded,
        iconColor: unsafe > 0
            ? FleetColors.critical
            : defects.isEmpty
                ? FleetColors.good
                : FleetColors.warning,
      ),
      _StatTile(
        label: 'Flagged',
        value: '$flagged',
        caption: flagged == 0
            ? 'Nothing suspicious'
            : 'Too fast, off site, reused photos…',
        icon: Icons.flag_rounded,
        iconColor: flagged == 0 ? FleetColors.good : FleetColors.serious,
      ),
    ];

    return LayoutBuilder(builder: (context, box) {
      final perRow = box.maxWidth >= 860 ? 4 : 2;
      const gap = 12.0;
      final w = (box.maxWidth - gap * (perRow - 1)) / perRow;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final t in tiles) SizedBox(width: w, child: t)],
      );
    });
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Color iconColor;

  /// 0..1 — a thin meter under the value.
  final double? meter;

  const _StatTile({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.iconColor,
    this.meter,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: 164,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          ]),
          const Spacer(),
          Text(value,
              maxLines: 1,
              style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600, color: scheme.onSurface)),
          const SizedBox(height: 4),
          // The meter's slot is kept on every tile so the values line up.
          SizedBox(
              height: 12,
              child: meter == null
                  ? null
                  : Align(
                      alignment: Alignment.topCenter,
                      child: _Meter(value: meter!))),
          // Two lines' room always, so a wrapping caption never lifts the
          // value out of line with its neighbours.
          SizedBox(
            height: 32,
            child: Text(caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

/// Thin 6px meter: accent fill on a lighter step of the same hue.
class _Meter extends StatelessWidget {
  final double value;
  const _Meter({required this.value});

  @override
  Widget build(BuildContext context) {
    final accent = FleetColors.accent(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Stack(fit: StackFit.expand, children: [
          ColoredBox(color: accent.withValues(alpha: 0.16)),
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: value.clamp(0, 1),
            child: ColoredBox(color: accent),
          ),
        ]),
      ),
    );
  }
}

// ── Vehicles today ─────────────────────────────────────────────────────────

class _VehiclesToday extends StatelessWidget {
  final FleetDashboardData data;
  final void Function(VehicleInspection) onOpen;
  final Future<String?> Function(String path) photoUrl;
  final bool wide;

  const _VehiclesToday({
    required this.data,
    required this.onOpen,
    required this.photoUrl,
    required this.wide,
  });

  @override
  Widget build(BuildContext context) {
    final keys = data.vehicleKeys;
    return FleetPanel(
      title: 'Vehicles',
      subtitle: DateFormat('EEEE d MMMM').format(data.date),
      child: LayoutBuilder(builder: (context, box) {
        final perRow = box.maxWidth >= 640 ? 2 : 1;
        const gap = 12.0;
        final w = (box.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (final key in keys)
            SizedBox(
              width: w,
              child: _VehicleCard(
                vehicleKey: key,
                data: data,
                onOpen: onOpen,
                photoUrl: photoUrl,
              ),
            ),
        ]);
      }),
    );
  }
}

class _VehicleCard extends StatelessWidget {
  final String vehicleKey;
  final FleetDashboardData data;
  final void Function(VehicleInspection) onOpen;
  final Future<String?> Function(String path) photoUrl;

  const _VehicleCard({
    required this.vehicleKey,
    required this.data,
    required this.onOpen,
    required this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final start = data.find(data.dateKey, vehicleKey, InspectionKind.start);
    final end = data.find(data.dateKey, vehicleKey, InspectionKind.end);
    final plate = data.fleet[vehicleKey]?.plateNumber ??
        start?.plateNumber ??
        end?.plateNumber ??
        '';
    final driver = data.roster[data.dateKey]?[vehicleKey] ??
        start?.driverName ??
        end?.driverName ??
        '';
    final shown = start ?? end;
    final photo =
        shown == null || shown.photosCleared ? null : shown.photos['front'];
    final odometer = end?.odometerKm ?? start?.odometerKm;

    // Licence disc and service, only once they are due soon or overdue.
    final vehicle = data.fleet[vehicleKey];
    final today = DateTime(data.now.year, data.now.month, data.now.day);
    final latestKm =
        VehicleInspectionService.latestOdometer(data.inspections, vehicleKey)
            ?.odometerKm;
    final fleetTags = <Widget>[
      if (vehicle != null)
        for (final (due, text) in [
          (vehicle.licenceDue(today), licenceStatusText(vehicle, today)),
          (vehicle.serviceDue(latestKm), serviceStatusText(vehicle, latestKm)),
        ])
          if ((due == FleetDue.soon || due == FleetDue.overdue) && text != null)
            _Tag(label: text, icon: dueIcon(due), color: dueColor(due)!),
    ];

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
          child: Row(children: [
            _PhotoThumb(
                path: photo?.path, photoUrl: photoUrl, width: 64, height: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(vehicleName(vehicleKey),
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  Text(
                    [
                      if (plate.isNotEmpty) plate,
                      if (driver.isNotEmpty) driver,
                      if (odometer != null)
                        '${NumberFormat.decimalPattern().format(odometer)} km',
                    ].join(' · ').ifEmpty('No plate set'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ]),
        ),
        if (fleetTags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 12, 6),
            child: Wrap(spacing: 6, runSpacing: 4, children: fleetTags),
          ),
        // End-of-day rows only for records submitted before it was dropped.
        for (final kind in InspectionKind.values)
          if (kind.isRequired ||
              (kind == InspectionKind.start ? start : end) != null)
            _ShiftRow(
              kind: kind,
              state: data.stateFor(vehicleKey, kind),
              inspection: kind == InspectionKind.start ? start : end,
              flags: data.flags[
                      (kind == InspectionKind.start ? start : end)?.id] ??
                  const {},
              onOpen: onOpen,
            ),
        const SizedBox(height: 6),
      ]),
    );
  }
}

class _ShiftRow extends StatelessWidget {
  final InspectionKind kind;
  final ShiftState state;
  final VehicleInspection? inspection;
  final Set<InspectionFlag> flags;
  final void Function(VehicleInspection) onOpen;

  const _ShiftRow({
    required this.kind,
    required this.state,
    required this.inspection,
    required this.flags,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final i = inspection;
    final time = i?.completedAt == null
        ? ''
        : DateFormat('HH:mm').format(toScheduleCivil(i!.completedAt!));
    return InkWell(
      onTap: i == null ? null : () => onOpen(i),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
        child: Row(children: [
          Icon(state.icon, size: 18, color: state.color(context)),
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: Text(kind.label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  [state.label, if (time.isNotEmpty) time].join(' · '),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (i != null && i.hasDefects)
                  _Tag(
                    label: i.isUnsafe
                        ? 'Unsafe'
                        : '${i.defects.length} defect${i.defects.length == 1 ? '' : 's'}',
                    icon: i.isUnsafe
                        ? Icons.dangerous_rounded
                        : Icons.build_rounded,
                    color:
                        i.isUnsafe ? FleetColors.critical : FleetColors.warning,
                  ),
                if (flags.isNotEmpty)
                  _Tag(
                    label: flags.length == 1
                        ? flags.first.label
                        : '${flags.length} flags',
                    icon: Icons.flag_rounded,
                    color: FleetColors.serious,
                  ),
              ],
            ),
          ),
          if (i != null)
            Icon(Icons.chevron_right_rounded,
                size: 20, color: scheme.onSurfaceVariant),
        ]),
      ),
    );
  }
}

/// Small tinted label: coloured icon, ink-coloured text.
class _Tag extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  const _Tag({required this.label, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  final String? path;
  final Future<String?> Function(String path) photoUrl;
  final double width;
  final double height;

  const _PhotoThumb({
    required this.path,
    required this.photoUrl,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Icon(Icons.local_shipping_rounded,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.6));
    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: path == null || path!.isEmpty
          ? placeholder
          : FutureBuilder<String?>(
              future: photoUrl(path!),
              builder: (context, snap) => snap.data == null
                  ? placeholder
                  : Image.network(snap.data!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => placeholder),
            ),
    );
  }
}

// ── Review queue ───────────────────────────────────────────────────────────

class _ReviewQueue extends StatefulWidget {
  final FleetDashboardData data;
  final void Function(VehicleInspection) onOpen;
  final Future<void> Function(VehicleInspection) onQuickApprove;

  const _ReviewQueue({
    required this.data,
    required this.onOpen,
    required this.onQuickApprove,
  });

  @override
  State<_ReviewQueue> createState() => _ReviewQueueState();
}

class _ReviewQueueState extends State<_ReviewQueue> {
  static const _collapsedCount = 8;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final data = widget.data;
    final queue = data.reviewQueue;
    final shown = _all ? queue : queue.take(_collapsedCount).toList();
    return FleetPanel(
      title: 'Review queue',
      subtitle: queue.isEmpty
          ? 'Nothing waiting'
          : '${queue.length} waiting · problems first',
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
      child: queue.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Column(children: [
                const Icon(Icons.task_alt_rounded,
                    size: 40, color: FleetColors.good),
                const SizedBox(height: 8),
                Text('All caught up', style: theme.textTheme.titleSmall),
                Text('New inspections from drivers appear here.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            )
          : Column(children: [
              for (var n = 0; n < shown.length; n++) ...[
                if (n > 0)
                  Divider(
                      height: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.5)),
                _QueueRow(
                  key: ValueKey(shown[n].id),
                  inspection: shown[n],
                  flags: data.flags[shown[n].id] ?? const {},
                  onOpen: widget.onOpen,
                  onQuickApprove: widget.onQuickApprove,
                ),
              ],
              if (queue.length > _collapsedCount)
                TextButton(
                  onPressed: () => setState(() => _all = !_all),
                  child: Text(_all ? 'Show fewer' : 'Show all ${queue.length}'),
                ),
            ]),
    );
  }
}

class _QueueRow extends StatefulWidget {
  final VehicleInspection inspection;
  final Set<InspectionFlag> flags;
  final void Function(VehicleInspection) onOpen;
  final Future<void> Function(VehicleInspection) onQuickApprove;

  const _QueueRow({
    super.key,
    required this.inspection,
    required this.flags,
    required this.onOpen,
    required this.onQuickApprove,
  });

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool _approving = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final i = widget.inspection;
    final clean = !i.hasDefects && widget.flags.isEmpty;
    final when = i.completedAt == null
        ? _shortDate(i.date)
        : '${_shortDate(i.date)} ${DateFormat('HH:mm').format(toScheduleCivil(i.completedAt!))}';
    final (IconData icon, Color color) = i.isUnsafe
        ? (Icons.dangerous_rounded, FleetColors.critical)
        : !clean
            ? (Icons.priority_high_rounded, FleetColors.serious)
            : (Icons.fact_check_rounded, FleetColors.accent(context));

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => widget.onOpen(i),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${vehicleName(i.vehicleKey)} · ${i.kind.label}',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(
                  [if (i.driverName.isNotEmpty) i.driverName, when].join(' · '),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (!clean) ...[
                  const SizedBox(height: 4),
                  Wrap(spacing: 4, runSpacing: 4, children: [
                    for (final d in i.defects)
                      _Tag(
                        label: '${d.severity.name[0].toUpperCase()}'
                            '${d.severity.name.substring(1)}: '
                            '${shortItemLabel(d.itemId)}',
                        icon: Icons.build_rounded,
                        color: severityColor(d.severity),
                      ),
                    for (final f in widget.flags)
                      _Tag(
                          label: f.label,
                          icon: Icons.flag_rounded,
                          color: FleetColors.serious),
                  ]),
                ],
              ],
            ),
          ),
          if (clean)
            _approving
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    tooltip: 'Approve — no defects, nothing flagged',
                    icon: const Icon(Icons.check_rounded),
                    color: FleetColors.good,
                    onPressed: () async {
                      setState(() => _approving = true);
                      try {
                        await widget.onQuickApprove(i);
                      } finally {
                        if (mounted) setState(() => _approving = false);
                      }
                    },
                  ),
          IconButton(
            tooltip: 'Open',
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: () => widget.onOpen(i),
          ),
        ]),
      ),
    );
  }
}

// ── 14-day trend ───────────────────────────────────────────────────────────

class _TrendDay {
  final DateTime date;
  final int done;

  /// Inspections owed (one morning check per vehicle out); null when the
  /// dropsheet for the day could not be read.
  final int? expected;
  final int defects;

  const _TrendDay(this.date, this.done, this.expected, this.defects);
}

class _TrendCard extends StatefulWidget {
  final FleetDashboardData data;
  const _TrendCard({required this.data});

  @override
  State<_TrendCard> createState() => _TrendCardState();
}

class _TrendCardState extends State<_TrendCard> {
  bool _table = false;

  List<_TrendDay> get _days {
    final data = widget.data;
    return [
      for (var n = 13; n >= 0; n--)
        () {
          final day = data.date.subtract(Duration(days: n));
          final key = VehicleInspectionService.dateKey(day);
          final list = data.on(key);
          final out = data.roster[key];
          return _TrendDay(
            day,
            list.where((i) => i.kind.isRequired).length,
            out?.length,
            list.fold(0, (sum, i) => sum + i.defects.length),
          );
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final days = _days;
    final owed = days.fold<int>(0, (s, d) => s + (d.expected ?? 0));
    final done = days.fold<int>(0,
        (s, d) => s + (d.expected == null ? 0 : d.done.clamp(0, d.expected!)));
    final rate = owed == 0 ? null : (done / owed * 100).round();
    return FleetPanel(
      title: 'Inspections done, last 14 days',
      subtitle: rate == null
          ? 'The morning check for each vehicle out'
          : '$rate% of the $owed owed by vehicles on the dropsheet',
      trailing: IconButton(
        tooltip: _table ? 'Show chart' : 'Show as table',
        icon: Icon(_table ? Icons.bar_chart_rounded : Icons.table_rows_rounded),
        onPressed: () => setState(() => _table = !_table),
      ),
      child: _table ? _TrendTable(days: days) : _TrendColumns(days: days),
    );
  }
}

/// One column per day: the inspections done (accent) inside a track the
/// height of those owed (a lighter step of the same hue). Single series,
/// so the title names it and there is no legend box.
class _TrendColumns extends StatelessWidget {
  final List<_TrendDay> days;
  const _TrendColumns({required this.days});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = FleetColors.accent(context);
    final maxValue = days.fold<int>(1,
        (m, d) => [m, d.done, d.expected ?? 0].reduce((a, b) => a > b ? a : b));
    const plotHeight = 140.0;
    final muted =
        theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);

    return LayoutBuilder(builder: (context, box) {
      // Bars never fill their slot: at most 22px, about 60% of the slot.
      final barWidth = (box.maxWidth / days.length * 0.6).clamp(6.0, 22.0);
      return SizedBox(
        // Cap label + plot + baseline + two lines of day labels.
        height: plotHeight + 64,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var idx = 0; idx < days.length; idx++)
              Expanded(
                child: Tooltip(
                  message: _tooltip(days[idx]),
                  waitDuration: const Duration(milliseconds: 150),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // Value on the cap of the latest day only.
                      SizedBox(
                        height: 18,
                        child: idx == days.length - 1
                            ? Text(
                                days[idx].expected == null
                                    ? '${days[idx].done}'
                                    : '${days[idx].done}/${days[idx].expected}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: scheme.onSurface),
                              )
                            : null,
                      ),
                      SizedBox(
                        height: plotHeight,
                        width: barWidth,
                        child: Stack(
                          alignment: Alignment.bottomCenter,
                          children: [
                            if ((days[idx].expected ?? 0) > 0)
                              _column(
                                plotHeight * days[idx].expected! / maxValue,
                                accent.withValues(alpha: 0.16),
                                barWidth,
                              ),
                            if (days[idx].done > 0)
                              _column(
                                plotHeight * days[idx].done / maxValue,
                                accent,
                                barWidth,
                              ),
                          ],
                        ),
                      ),
                      Container(height: 1, color: scheme.outlineVariant),
                      const SizedBox(height: 6),
                      Text(
                          DateFormat('E')
                              .format(days[idx].date)
                              .substring(0, 2),
                          style: muted),
                      Text('${days[idx].date.day}', style: muted),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }

  /// 4px rounded data end, square at the baseline.
  static Widget _column(double height, Color color, double width) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
        ),
      );

  static String _tooltip(_TrendDay d) {
    final day = DateFormat('EEE d MMM').format(d.date);
    final owed = d.expected == null
        ? '${d.done} done'
        : d.expected == 0
            ? 'No vehicles out${d.done > 0 ? ' · ${d.done} done' : ''}'
            : '${d.done} of ${d.expected} done';
    final defects = d.defects == 0
        ? ''
        : ' · ${d.defects} defect${d.defects == 1 ? '' : 's'}';
    return '$day: $owed$defects';
  }
}

class _TrendTable extends StatelessWidget {
  final List<_TrendDay> days;
  const _TrendTable({required this.days});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = theme.textTheme.labelMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    const figures = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
    TableRow row(List<Widget> cells) => TableRow(children: [
          for (final c in cells)
            Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: c)
        ]);
    return Table(
      columnWidths: const {0: FlexColumnWidth(2)},
      children: [
        row([
          Text('Day', style: head),
          Text('Done', style: head, textAlign: TextAlign.right),
          Text('Owed', style: head, textAlign: TextAlign.right),
          Text('Defects', style: head, textAlign: TextAlign.right),
        ]),
        for (final d in days.reversed)
          row([
            Text(DateFormat('EEE d MMM').format(d.date)),
            Text('${d.done}', style: figures, textAlign: TextAlign.right),
            Text(d.expected == null ? '—' : '${d.expected}',
                style: figures, textAlign: TextAlign.right),
            Text('${d.defects}', style: figures, textAlign: TextAlign.right),
          ]),
      ],
    );
  }
}

// ── Recent defects ─────────────────────────────────────────────────────────

class _RecentDefects extends StatelessWidget {
  final FleetDashboardData data;
  final void Function(VehicleInspection) onOpen;
  const _RecentDefects({required this.data, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = [
      for (final i in data.inspections)
        for (final d in i.defects) (i, d),
    ]..sort((a, b) {
        // Newest first; on the same shift the worst defect first.
        final when = '${b.$1.date}${b.$1.kind.index}'
            .compareTo('${a.$1.date}${a.$1.kind.index}');
        return when != 0
            ? when
            : b.$2.severity.index.compareTo(a.$2.severity.index);
      });
    final shown = rows.take(8).toList();

    return FleetPanel(
      title: 'Recent defects',
      subtitle: rows.isEmpty
          ? 'None reported in the last 30 days'
          : '${rows.length} in the last 30 days',
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
      child: shown.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.verified_rounded, color: FleetColors.good),
                const SizedBox(width: 8),
                Text('No defects reported', style: theme.textTheme.bodyMedium),
              ]),
            )
          : Column(children: [
              for (final (i, d) in shown)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onOpen(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(
                                d.severity == DefectSeverity.unsafe
                                    ? Icons.dangerous_rounded
                                    : Icons.build_circle_rounded,
                                size: 20,
                                color: severityColor(d.severity)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${shortItemLabel(d.itemId)} · ${d.severity.label}',
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                if (d.note.isNotEmpty)
                                  Text(d.note,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall),
                                Text(
                                  '${vehicleName(i.vehicleKey)} · ${_shortDate(i.date)} · ${i.driverName}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ]),
                  ),
                ),
            ]),
    );
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────

String _shortDate(String dateKey) {
  final d = DateTime.tryParse(dateKey);
  return d == null ? dateKey : DateFormat('EEE d MMM').format(d);
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
