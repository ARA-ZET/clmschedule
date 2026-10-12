// track_editor/widgets/te_letterbox_comparison_panel.dart
//
// Compares what a distributor actually dropped inside each work-area polygon
// against the curated letterbox index. Used from two places:
//
//   * Processing mode, as this standalone panel — the distributor workflow,
//     where the tab holds schedule work-maps and the round's GPX but has not
//     been trimmed. The numbers are counted in the background by
//     [TELetterboxCheckProvider] and kept on the tab, so this panel only
//     displays them.
//   * Trim mode, where [TELetterboxComparisonSummary] and
//     [TELetterboxComparisonLine] are reused inside the existing per-polygon
//     list rather than shown as a second panel.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:gpx/gpx.dart';

import '../models/styled_polygon.dart';
import '../providers/te_letterbox_check_provider.dart';
import '../providers/te_tabs_provider.dart';
import 'te_polygon_visibility_toggle.dart';

class TELetterboxComparisonPanel extends riverpod.ConsumerWidget {
  const TELetterboxComparisonPanel({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final tabs = ref.watch(teTabsRiverpod);
    final tab = tabs.tabs[tabs.currentTab];
    final checker = ref.watch(teLetterboxCheckRiverpod);
    final check = tab.letterboxCheck;
    final source = check.polygons;
    final busy = checker.isBusy(tab);

    // Nothing to compare against: no work areas, or no round to score.
    final canCompare = tab.polygons.isNotEmpty || tab.targetPolygons.isNotEmpty;
    final hasWaypoints = tab.waypoints.isNotEmpty ||
        tab.targetPolygons.any((p) => p.waypoints.isNotEmpty);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      width: 400,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.markunread_mailbox_outlined,
                  size: 17, color: Colors.indigo.shade400),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Delivery vs Letterboxes',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              if (canCompare)
                TEPolygonVisibilityToggle(tabIndex: tabs.currentTab),
            ],
          ),
          const SizedBox(height: 10),
          if (!canCompare)
            Text(
              'No work areas on this tab yet. Match the track to its schedule '
              'jobs to compare the round against the letterbox index.',
              style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade500),
            )
          else if (!hasWaypoints)
            Text(
              'No waypoints loaded for this round, so there is nothing to '
              'compare against the letterbox index yet.',
              style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade500),
            )
          else ...[
            if (check.hasResults)
              TELetterboxComparisonSummary(
                  check: check, polygons: source, busy: busy)
            else
              Text(
                busy
                    ? 'Counting the curated letterboxes inside each work area…'
                    : 'Count the curated letterboxes inside each work area and '
                        'compare them against what this round actually dropped.',
                style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade500),
              ),
            const SizedBox(height: 10),
            if (check.hasResults)
              ...source.map((polygon) => _PolygonRow(
                    polygon: polygon,
                    comparison: check.resultFor(polygon),
                  )),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: check.isChecking
                  ? null
                  : () => ref.read(teLetterboxCheckRiverpod).recheck(tab),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: busy ? Colors.indigo.shade200 : Colors.indigo.shade400,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(busy ? Icons.hourglass_top : Icons.fact_check_outlined,
                        color: Colors.white, size: 17),
                    const SizedBox(width: 8),
                    Text(
                      busy
                          ? 'Comparing…'
                          : check.hasResults
                              ? 'Recheck'
                              : 'Compare with letterbox index',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One work area's row: name, drops, and the comparison beneath it.
class _PolygonRow extends StatelessWidget {
  final TETargetPolygon polygon;
  final TELetterboxComparison? comparison;

  const _PolygonRow({required this.polygon, required this.comparison});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(polygon.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
              ),
              Text(polygon.waypoints.length.toString(),
                  style: const TextStyle(fontWeight: FontWeight.w500)),
            ],
          ),
          if (comparison != null) TELetterboxComparisonLine(comparison!),
        ],
      ),
    );
  }
}

/// Round-level comparison: expected across every work area counted as a union
/// (so overlapping areas are not counted twice), against the distinct
/// waypoints dropped inside any of them.
class TELetterboxComparisonSummary extends StatelessWidget {
  final TELetterboxTabCheck check;
  final List<TETargetPolygon> polygons;

  /// Show the spinner: a recount is running or queued for this tab.
  final bool busy;

  const TELetterboxComparisonSummary({
    super.key,
    required this.check,
    required this.polygons,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    // Distinct waypoints, not the sum per polygon — a drop inside two
    // overlapping areas is one delivery, and must not inflate coverage.
    final droppedTotal = <Wpt>{for (final p in polygons) ...p.waypoints}.length;
    final union = check.union;
    final expectedTotal = union?.count;
    final coverage = (expectedTotal == null || expectedTotal == 0)
        ? null
        : droppedTotal / expectedTotal;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.indigo.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.markunread_mailbox_outlined,
                  size: 15, color: Colors.indigo.shade400),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('Round total',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              if (busy)
                const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          if (check.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(check.error!,
                  style:
                      TextStyle(fontSize: 11, color: Colors.orange.shade800)),
            )
          else if (expectedTotal != null) ...[
            const SizedBox(height: 4),
            Text(
              '$droppedTotal dropped of $expectedTotal letterboxes'
              '${coverage == null ? '' : '  ·  ${(coverage * 100).toStringAsFixed(1)}%'}',
              style: const TextStyle(fontSize: 12),
            ),
            if (union!.hasOverlaps)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${union.overlaps.length} overlapping area pair(s) — '
                  'counted once in the total',
                  style:
                      TextStyle(fontSize: 10, color: Colors.blueGrey.shade600),
                ),
              ),
            if (!union.isTrusted)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'Includes uncurated suburbs — not evidence of under- or '
                  'over-delivery: ${union.unverifiedSuburbs.join(', ')}',
                  style: TextStyle(fontSize: 10, color: Colors.orange.shade800),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// One polygon's dropped-versus-expected line.
class TELetterboxComparisonLine extends StatelessWidget {
  final TELetterboxComparison comparison;
  const TELetterboxComparisonLine(this.comparison, {super.key});

  @override
  Widget build(BuildContext context) {
    final coverage = comparison.coverage;

    // No curated letterboxes here means there is nothing to judge the round
    // against — say so, rather than showing 0% as though it were a failure.
    if (comparison.expectedCount == 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text('no curated letterboxes in this area',
            style: TextStyle(fontSize: 10, color: Colors.blueGrey.shade400)),
      );
    }

    final Color tone;
    final String verdict;
    if (comparison.overDelivery > 0) {
      tone = Colors.purple.shade700;
      verdict = '${comparison.overDelivery} more drops than letterboxes';
    } else if (comparison.shortfall > 0) {
      tone = coverage != null && coverage < 0.8
          ? Colors.red.shade700
          : Colors.orange.shade800;
      verdict = '${comparison.shortfall} short';
    } else {
      tone = Colors.green.shade700;
      verdict = 'complete';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'of ${comparison.expectedCount}'
              '${coverage == null ? '' : '  ·  ${(coverage * 100).toStringAsFixed(0)}%'}'
              '  ·  $verdict',
              style: TextStyle(fontSize: 10, color: tone),
            ),
          ),
          if (!comparison.isTrusted)
            Tooltip(
              message: 'Expected count includes uncurated suburbs: '
                  '${comparison.expected.unverifiedSuburbs.join(', ')}',
              child: Icon(Icons.warning_amber_rounded,
                  size: 12, color: Colors.orange.shade700),
            ),
        ],
      ),
    );
  }
}
