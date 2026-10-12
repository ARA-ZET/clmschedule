import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../providers/shareable_map_provider.dart';
import '../utils/polygon_topology.dart';

/// "Fix boundaries" — find and close the seams between adjacent polygons.
///
/// Hand-drawn areas never meet exactly, and the slivers that leaves corrupt
/// letterbox counts both ways: a gap drops boxes from every count, an overlap
/// counts them twice. This measures those seams and snaps shut whatever falls
/// inside the tolerance. Anything wider is listed, not silently clipped.
class MapBoundaryCleanupDialog extends riverpod.ConsumerStatefulWidget {
  const MapBoundaryCleanupDialog({super.key});

  @override
  riverpod.ConsumerState<MapBoundaryCleanupDialog> createState() =>
      _MapBoundaryCleanupDialogState();
}

class _MapBoundaryCleanupDialogState
    extends riverpod.ConsumerState<MapBoundaryCleanupDialog> {
  double _tolerance = PolygonTopology.defaultToleranceMetres;
  bool _thisLayerOnly = false;
  bool _recount = true;

  TopologyReport? _report;
  BoundaryCleanupOutcome? _outcome;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A map that keeps unrelated area sets in separate layers (suburbs
      // under work areas) is MEANT to have them cover the same ground, so
      // default to one layer whenever the selected layer can stand alone.
      final provider = ref.read(shareableMapRiverpod);
      final selected = provider.selectedLayer;
      final selectedPolygons = selected == null
          ? 0
          : provider.topologyRings(layerId: selected.id).length;
      final allPolygons = provider.topologyRings().length;
      if (mounted && selectedPolygons >= 2 && selectedPolygons < allPolygons) {
        setState(() => _thisLayerOnly = true);
      }
      _analyze();
    });
  }

  String? get _scopeLayerId {
    if (!_thisLayerOnly) return null;
    return ref.read(shareableMapRiverpod).selectedLayer?.id;
  }

  void _analyze() {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = ref.read(shareableMapRiverpod).analyzeBoundaries(
            toleranceMetres: _tolerance,
            layerId: _scopeLayerId,
          );
      if (!mounted) return;
      setState(() {
        _report = report;
        _outcome = null;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _fix() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await ref.read(shareableMapRiverpod).cleanBoundaries(
            toleranceMetres: _tolerance,
            layerId: _scopeLayerId,
            recountLetterboxes: _recount,
          );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _report = outcome.after;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(shareableMapRiverpod);
    final report = _report;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.rule_folder_outlined, color: Color(0xFF1967D2)),
          const SizedBox(width: 10),
          const Text('Fix boundaries'),
          const Spacer(),
          if (_busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildScope(provider),
              const SizedBox(height: 4),
              _buildTolerance(),
              const Divider(height: 20),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ),
              if (report != null) _buildReport(report),
              const SizedBox(height: 4),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _recount,
                onChanged:
                    _busy ? null : (v) => setState(() => _recount = v ?? true),
                title: const Text('Recount letter boxes after fixing',
                    style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (provider.canUndoBoundaryCleanup)
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    provider.undoBoundaryCleanup();
                    _analyze();
                  },
            child: const Text('Undo fix'),
          ),
        TextButton(
          onPressed: _busy ? null : _analyze,
          child: const Text('Re-check'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        ElevatedButton(
          onPressed:
              _busy || report == null || report.ringCount < 2 ? null : _fix,
          child: const Text('Fix'),
        ),
      ],
    );
  }

  Widget _buildScope(ShareableMapProvider provider) {
    final selected = provider.selectedLayer;
    return Row(
      children: [
        const SizedBox(width: 76, child: Text('Scope', style: _labelStyle)),
        Expanded(
          child: SegmentedButton<bool>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              const ButtonSegment(value: false, label: Text('All layers')),
              ButtonSegment(
                value: true,
                label: Text(
                    selected == null || selected.name.isEmpty
                        ? 'This layer'
                        : selected.name,
                    overflow: TextOverflow.ellipsis),
                enabled: selected != null,
              ),
            ],
            selected: {_thisLayerOnly},
            onSelectionChanged: _busy
                ? null
                : (values) {
                    setState(() => _thisLayerOnly = values.first);
                    _analyze();
                  },
          ),
        ),
      ],
    );
  }

  /// Past this the tolerance stops being "the wobble in a hand-drawn line"
  /// and starts being a deliberate decision to move a boundary.
  static const double _roundingCeiling = 25;

  Widget _buildTolerance() {
    return Row(
      children: [
        const SizedBox(
            width: 76, child: Text('Snap within', style: _labelStyle)),
        Expanded(
          child: Slider(
            value: _tolerance,
            min: 1,
            max: 200,
            divisions: 199,
            label: '${_tolerance.round()} m',
            onChanged: _busy ? null : (v) => setState(() => _tolerance = v),
            onChangeEnd: _busy ? null : (_) => _analyze(),
          ),
        ),
        SizedBox(
          width: 46,
          child: Text('${_tolerance.round()} m',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: _tolerance > _roundingCeiling
                    ? Colors.orange.shade900
                    : null,
              )),
        ),
        if (_tolerance > _roundingCeiling)
          Tooltip(
            message: 'Above ${_roundingCeiling.round()} m a snap moves a '
                'boundary further than a drawing wobble — check the pairs it '
                'lists before applying.',
            child: Icon(Icons.warning_amber_rounded,
                size: 18, color: Colors.orange.shade900),
          ),
      ],
    );
  }

  Widget _buildReport(TopologyReport report) {
    final outcome = _outcome;
    final rows = <Widget>[];

    if (outcome != null) {
      final fix = outcome.fix;
      rows.add(_line(
        Icons.check_circle,
        Colors.green.shade700,
        fix.isEmpty
            ? 'Nothing to snap'
            : '${fix.changed.length} polygons adjusted · '
                '${fix.verticesMoved + fix.verticesInserted} points moved or '
                'added'
                '${outcome.recounted > 0 ? " · ${outcome.recounted} recounted" : ""}',
      ));
      rows.add(const SizedBox(height: 10));
    }

    rows.add(Text(
      '${report.ringCount} polygons · ${report.toleranceMetres.round()} m',
      style: _labelStyle,
    ));
    rows.add(const SizedBox(height: 6));

    if (report.isClean) {
      rows.add(_line(Icons.verified_outlined, Colors.green.shade700,
          'No gaps, no overlaps'));
      return Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: rows);
    }

    if (report.gaps.isNotEmpty) {
      rows.add(_line(
        Icons.space_bar,
        Colors.orange.shade800,
        '${report.gaps.length} gaps to close · widest '
        '${report.worstGapMetres!.toStringAsFixed(1)} m',
      ));
      rows.add(_pairList(_gapLabels(report)));
    }

    if (report.wideGaps.isNotEmpty) {
      rows.add(_line(
        Icons.warning_amber_rounded,
        Colors.deepOrange.shade700,
        '${report.wideGaps.length} gaps too wide to snap · widest '
        '${report.wideGaps.first.metres.toStringAsFixed(1)} m',
      ));
      rows.add(_pairList(_wideGapLabels(report)));
      rows.add(_wideGapActions(report));
    }

    if (report.overlaps.isNotEmpty) {
      rows.add(_line(
        Icons.layers_clear,
        Colors.red.shade700,
        '${report.overlaps.length} overlaps · ~'
        '${_area(report.totalOverlapSqMetres)} counted twice',
      ));
      rows.add(_pairList(_overlapLabels(report)));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  /// The two ways out of a gap the tolerance cannot reach: widen it
  /// deliberately, or draw the missing strip.
  Widget _wideGapActions(TopologyReport report) {
    final needed = report.toleranceToCloseAllGaps!;
    return Padding(
      padding: const EdgeInsets.only(left: 26, bottom: 6),
      child: Wrap(
        spacing: 8,
        children: [
          if (needed <= 200)
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _tolerance = needed);
                      _analyze();
                    },
              style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact),
              child: Text('Try ${needed.round()} m'),
            ),
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    Navigator.pop(context);
                    ref.read(shareableMapRiverpod).startDrawingForUnfinished();
                  },
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Draw it instead'),
          ),
        ],
      ),
    );
  }

  Widget _line(IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 13, color: color, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _pairList(List<String> labels) {
    if (labels.isEmpty) return const SizedBox.shrink();
    final shown = labels.take(5).toList();
    return Padding(
      padding: const EdgeInsets.only(left: 24, top: 2, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final label in shown)
            Text(label,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
          if (labels.length > shown.length)
            Text('+${labels.length - shown.length} more',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  List<String> _gapLabels(TopologyReport report) {
    final rings = _ringsFor(report);
    return report.gaps
        .where((g) => g.a < rings.length && g.b < rings.length)
        .map((g) => '${rings[g.a].name} ↔ ${rings[g.b].name} · '
            '${g.metres.toStringAsFixed(1)} m')
        .toList();
  }

  List<String> _wideGapLabels(TopologyReport report) {
    final rings = _ringsFor(report);
    return report.wideGaps
        .where((g) => g.a < rings.length && g.b < rings.length)
        .map((g) => '${rings[g.a].name} ↔ ${rings[g.b].name} · '
            '${g.metres.toStringAsFixed(1)} m')
        .toList();
  }

  List<String> _overlapLabels(TopologyReport report) {
    final rings = _ringsFor(report);
    return report.overlaps
        .where((o) => o.a < rings.length && o.b < rings.length)
        .map((o) => '${rings[o.a].name} ↔ ${rings[o.b].name} · ~'
            '${_area(o.approxAreaSqMetres)}')
        .toList();
  }

  /// The ring list the indexes in [report] point into: the post-fix geometry
  /// when the report came back from a fix, otherwise the map as it stands.
  List<TopologyRing> _ringsFor(TopologyReport report) {
    final outcome = _outcome;
    if (outcome != null && identical(report, outcome.after)) {
      return outcome.rings;
    }
    return ref.read(shareableMapRiverpod).topologyRings(layerId: _scopeLayerId);
  }

  static const _labelStyle = TextStyle(fontSize: 13, color: Colors.black87);

  static String _area(double sqMetres) {
    if (sqMetres >= 10000) {
      return '${(sqMetres / 10000).toStringAsFixed(2)} ha';
    }
    return '${sqMetres.round()} m²';
  }
}
