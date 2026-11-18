// widgets/fleet/inspection_alerts.dart
//
// What an admin sees when drivers submit their morning vehicle inspection:
// a badged Fleet button in the app bar (pending reviews) and a notification
// card per inspection that leads with its defects and the points that need
// attention. Data comes from inspectionAlertsRiverpod.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart' show DateFormat;

import '../../models/vehicle_inspection.dart';
import '../../providers/auth_provider.dart';
import '../../providers/inspection_alerts_provider.dart';
import '../../shareable_maps/widgets/map_overlay.dart';
import '../../utils/schedule_time.dart';
import 'fleet_dashboard.dart' show FleetColors, severityColor;

/// Most cards on screen at once; the rest are summarised under them.
const int _maxCards = 3;

/// App-bar Fleet button with a count of inspections waiting for review. Red
/// when any of them has a defect or a flag, blue when they are all clean.
/// Admins only; renders nothing for other staff.
class FleetAlertButton extends riverpod.ConsumerWidget {
  final VoidCallback onPressed;

  const FleetAlertButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    if (!ref.watch(authRiverpod.select((a) => a.isAdmin))) {
      return const SizedBox.shrink();
    }
    final alerts = ref.watch(inspectionAlertsRiverpod);
    final count = alerts.pendingCount;
    final attention = alerts.pendingAttentionCount;
    final badge =
        attention > 0 ? FleetColors.critical : FleetColors.accent(context);
    final tooltip = count == 0
        ? 'Fleet — no inspections to review'
        : '$count inspection${count == 1 ? '' : 's'} to review'
            '${attention == 0 ? '' : ' · $attention need${attention == 1 ? 's' : ''} attention'}';

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.fact_check_outlined,
                      size: 20, color: Colors.black),
                  SizedBox(height: 1),
                  Text('Fleet',
                      style: TextStyle(
                          fontSize: 9,
                          color: Colors.black,
                          height: 1.1,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            if (count > 0)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  constraints:
                      const BoxConstraints(minWidth: 16, minHeight: 16),
                  decoration: BoxDecoration(
                    color: badge,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Notification cards for today's unreviewed inspections, stacked in the
/// top-right corner of the dashboard body until reviewed or closed.
class InspectionAlertCards extends riverpod.ConsumerWidget {
  final void Function(VehicleInspection) onReview;
  final VoidCallback onOpenFleet;

  const InspectionAlertCards({
    super.key,
    required this.onReview,
    required this.onOpenFleet,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    if (!ref.watch(authRiverpod.select((a) => a.isAdmin))) {
      return const SizedBox.shrink();
    }
    final alerts = ref.watch(inspectionAlertsRiverpod);
    final cards = alerts.notifications;
    if (cards.isEmpty) return const SizedBox.shrink();
    final hidden = cards.length - _maxCards;

    return MapOverlay(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final i in cards.take(_maxCards))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InspectionAlertCard(
                  key: ValueKey(i.id),
                  inspection: i,
                  attention: alerts.attentionOf(i),
                  onReview: () {
                    alerts.dismiss(i.id);
                    onReview(i);
                  },
                  onDismiss: () => alerts.dismiss(i.id),
                ),
              ),
            if (hidden > 0)
              Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(12),
                color: Theme.of(context).colorScheme.surfaceContainerLowest,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        '$hidden more inspection${hidden == 1 ? '' : 's'} today',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    TextButton(
                        onPressed: alerts.dismissAll,
                        child: const Text('Close all')),
                    TextButton(
                        onPressed: onOpenFleet,
                        child: const Text('Open Fleet')),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One submitted inspection: who, which vehicle, when — then its defects and
/// attention points, or a clear "nothing to worry about".
class InspectionAlertCard extends StatelessWidget {
  final VehicleInspection inspection;

  /// From [InspectionAlertsProvider.attentionOf].
  final List<String> attention;
  final VoidCallback onReview;
  final VoidCallback onDismiss;

  const InspectionAlertCard({
    super.key,
    required this.inspection,
    required this.attention,
    required this.onReview,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final i = inspection;
    final defects =
        i.defects.where((d) => d.severity != DefectSeverity.unsafe).toList();
    final unsafeDefects =
        i.defects.where((d) => d.severity == DefectSeverity.unsafe).toList();
    final clean = attention.isEmpty && i.defects.isEmpty;
    final urgent = attention.isNotEmpty || unsafeDefects.isNotEmpty;

    final (Color tone, IconData icon, String headline) = i.isUnsafe
        ? (
            FleetColors.critical,
            Icons.dangerous_rounded,
            'Unsafe — do not drive'
          )
        : attention.isNotEmpty
            ? (FleetColors.serious, Icons.flag_rounded, 'Needs attention')
            : i.defects.isNotEmpty
                ? (
                    FleetColors.warning,
                    Icons.build_rounded,
                    '${i.defects.length} defect${i.defects.length == 1 ? '' : 's'} reported'
                  )
                : (
                    FleetColors.good,
                    Icons.check_circle_rounded,
                    'All checks OK'
                  );

    final when = i.completedAt ?? i.submittedAt;
    final meta = [
      i.vehicleDisplay,
      if (i.driverName.isNotEmpty) i.driverName,
      if (when != null) DateFormat('HH:mm').format(toScheduleCivil(when)),
    ].join(' · ');

    return Material(
      elevation: 3,
      shadowColor: Colors.black26,
      color: scheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 5, color: tone),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: tone.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, size: 20, color: tone),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Inspection submitted',
                              style: theme.textTheme.labelMedium
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                          Text(headline,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          Text(meta,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: onDismiss,
                    ),
                  ]),
                  const SizedBox(height: 10),
                  if (urgent) ...[
                    _SectionLabel('Needs attention'),
                    for (final a in attention)
                      _Point(
                        icon: Icons.flag_rounded,
                        color: FleetColors.serious,
                        text: a,
                      ),
                    for (final d in unsafeDefects)
                      _Point(
                        icon: Icons.dangerous_rounded,
                        color: FleetColors.critical,
                        text: '${shortItemLabel(d.itemId)}'
                            '${d.note.isEmpty ? '' : ': ${d.note}'}',
                        trailing: 'Unsafe',
                      ),
                  ],
                  if (defects.isNotEmpty) ...[
                    if (urgent) const SizedBox(height: 6),
                    _SectionLabel(
                        '${defects.length} defect${defects.length == 1 ? '' : 's'}'),
                    for (final d in defects)
                      _Point(
                        icon: Icons.circle,
                        iconSize: 10,
                        color: severityColor(d.severity),
                        text: '${shortItemLabel(d.itemId)}'
                            '${d.note.isEmpty ? '' : ': ${d.note}'}',
                        trailing: d.severity.label,
                      ),
                  ],
                  if (clean)
                    const _Point(
                      icon: Icons.check_rounded,
                      color: FleetColors.good,
                      text: 'No defects, nothing flagged',
                    ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilledButton.tonalIcon(
                        onPressed: onReview,
                        icon: const Icon(Icons.fact_check_outlined, size: 18),
                        label: const Text('Review'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(text.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 0.6,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// One line with a status icon; the text stays in ink colours.
class _Point extends StatelessWidget {
  final IconData icon;
  final double iconSize;
  final Color color;
  final String text;
  final String? trailing;

  const _Point({
    required this.icon,
    required this.color,
    required this.text,
    this.iconSize = 16,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 18,
          height: 18,
          child: Center(child: Icon(icon, size: iconSize, color: color)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Text(trailing!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ]),
    );
  }
}
