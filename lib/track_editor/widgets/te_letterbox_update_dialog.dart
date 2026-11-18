// track_editor/widgets/te_letterbox_update_dialog.dart
//
// "Update letterbox index" — replacing the curated letterboxes inside one
// work-area polygon with the waypoints a round actually recorded there.
//
// This is the write side of the comparison in `te_letterbox_comparison_panel`:
// when the round's drops are the better record of what is on the ground, this
// makes them the index. It is deliberately a two-step confirm rather than a
// menu item that just does it — the letterbox index is what client work is
// quoted from and what distributors are reviewed against, so a replacement
// shows its exact effect per suburb before anything is written.
//
// A successful update also files the polygon in the Client Maps library with
// the count and the houses-versus-apartments split now under it. That is the
// point of surveying an area: the number becomes something you can quote from
// on a map, not just a correction buried in the index.
//
// Also opened from a client map in the shareable map editor, with that
// editor's own writer and cache refresh — see [writerProvider] and
// [onIndexChanged]. The track editor passes neither.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../letterbox/services/letterbox_area_write_service.dart';
import '../../models/custom_polygon.dart';
import '../../services/client_area_service.dart';
import '../providers/te_letterbox_check_provider.dart';
import '../providers/te_letterbox_write_provider.dart';
import '../services/point_in_polygon.dart';

/// Open the update flow for one polygon. Returns true when the index was
/// changed, so the caller can refresh anything showing expected counts.
///
/// [positions] are the drops to write — from GPX waypoints, convert with
/// [TELetterboxWriteProvider.positionsOf] first.
Future<bool> showTELetterboxUpdateDialog(
  BuildContext context, {
  required String areaName,
  required List<LatLng> area,
  required List<LatLng> positions,
  String client = '',
  String? sourcePolygonId,
  riverpod.ChangeNotifierProvider<TELetterboxWriteProvider>? writerProvider,
  void Function(Iterable<String> suburbIds)? onIndexChanged,
}) async {
  final changed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => TELetterboxUpdateDialog(
      areaName: areaName,
      area: area,
      positions: positions,
      client: client,
      sourcePolygonId: sourcePolygonId,
      writerProvider: writerProvider ?? teLetterboxWriteRiverpod,
      onIndexChanged: onIndexChanged,
    ),
  );
  return changed ?? false;
}

class TELetterboxUpdateDialog extends riverpod.ConsumerStatefulWidget {
  final String areaName;
  final List<LatLng> area;

  /// The drops that become the index inside [area]; anything outside it is
  /// ignored.
  final List<LatLng> positions;

  /// Who the polygon is for, from the work area's own client label. Written
  /// onto the Client Maps entry; blank is fine and leaves it unset.
  final String client;

  /// The track-editor polygon's id, so re-surveying the same area refreshes
  /// its Client Maps entry instead of leaving a second copy behind.
  final String? sourcePolygonId;

  /// Which writer runs the change. Each screen has its own so its undo record
  /// and its count cache stay its own.
  final riverpod.ChangeNotifierProvider<TELetterboxWriteProvider>
      writerProvider;

  /// Called with the suburbs a write or undo touched, so the caller recounts
  /// against the new index. Defaults to the track editor's comparison panel.
  final void Function(Iterable<String> suburbIds)? onIndexChanged;

  const TELetterboxUpdateDialog({
    super.key,
    required this.areaName,
    required this.area,
    required this.positions,
    this.client = '',
    this.sourcePolygonId,
    required this.writerProvider,
    this.onIndexChanged,
  });

  @override
  riverpod.ConsumerState<TELetterboxUpdateDialog> createState() =>
      _TELetterboxUpdateDialogState();
}

class _TELetterboxUpdateDialogState
    extends riverpod.ConsumerState<TELetterboxUpdateDialog> {
  /// Round drops inside this polygon — the points that will become the index
  /// here. Clipped on the client so the count is on screen immediately, and
  /// again by the write service, which owns the rule.
  late final List<LatLng> _fresh;

  /// True once a write has finished, so the dialog shows its outcome and the
  /// way to undo it rather than offering to write again.
  bool _wrote = false;

  /// File the surveyed polygon in Client Maps. On by default — a survey whose
  /// number never reaches the library it is quoted from has done only half a
  /// job — but untickable for a one-off correction to the index that is not
  /// an area anyone sells.
  bool _addToClientMaps = true;

  @override
  void initState() {
    super.initState();
    _fresh = widget.positions
        .where((p) => isPointInPolygon(p, widget.area))
        .toList(growable: false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _preview());
  }

  Future<void> _preview() async {
    await ref
        .read(teLetterboxWriteRiverpod)
        .preview(area: widget.area, fresh: _fresh);
  }

  Future<void> _apply() async {
    final writer = ref.read(widget.writerProvider);
    final plan = writer.plan;
    final wrote = await writer.apply(
      areaName: widget.areaName,
      client: widget.client,
      sourcePolygonId: widget.sourcePolygonId,
      addToClientMaps: _addToClientMaps,
    );
    if (!mounted) return;
    if (wrote) {
      // The comparison panel counts from a session cache; without this its
      // "expected" numbers would still be the ones just replaced.
      _indexChanged(writer.result?.touchedSuburbIds ??
          plan?.affected.map((s) => s.suburbId) ??
          const <String>[]);
      setState(() => _wrote = true);
    }
  }

  void _indexChanged(Iterable<String> suburbIds) {
    final callback = widget.onIndexChanged;
    if (callback != null) {
      callback(suburbIds);
    } else {
      ref.read(teLetterboxCheckRiverpod).invalidateSuburbs(suburbIds);
    }
  }

  Future<void> _undo() async {
    final writer = ref.read(widget.writerProvider);
    final ids = writer.undoSuburbIds;
    final restored = await writer.undoLastWrite();
    if (!mounted) return;
    _indexChanged(ids);
    if (restored) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final writer = ref.watch(widget.writerProvider);
    final plan = writer.plan;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.markunread_mailbox_outlined,
              size: 20, color: Colors.indigo.shade400),
          const SizedBox(width: 8),
          const Expanded(child: Text('Update letterbox index')),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.areaName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (_wrote)
                _DoneBody(
                  result: writer.result,
                  clientArea: writer.clientArea,
                  error: writer.error,
                )
              else if (writer.isBusy)
                _BusyBody(message: writer.progress ?? 'Working…')
              else if (writer.error != null)
                _Notice(writer.error!, tone: _Tone.bad)
              else if (plan != null) ...[
                _PlanBody(plan: plan, freshInArea: _fresh.length),
                if (plan.hasChanges && _fresh.isNotEmpty)
                  _ClientMapsToggle(
                    value: _addToClientMaps,
                    areaName: widget.areaName,
                    client: widget.client,
                    onChanged: (v) => setState(() => _addToClientMaps = v),
                  ),
              ] else
                const SizedBox.shrink(),
            ],
          ),
        ),
      ),
      actions: _actions(writer, plan),
    );
  }

  List<Widget> _actions(
      TELetterboxWriteProvider writer, LetterboxAreaPlan? plan) {
    if (_wrote) {
      return [
        if (writer.canUndo)
          TextButton(
            onPressed: writer.isBusy ? null : _undo,
            child: const Text('Undo this update'),
          ),
        FilledButton(
          onPressed: writer.isBusy
              ? null
              : () => Navigator.of(context).pop(true),
          child: const Text('Done'),
        ),
      ];
    }

    final canWrite =
        !writer.isBusy && plan != null && plan.hasChanges && _fresh.isNotEmpty;
    return [
      TextButton(
        onPressed: writer.isBusy
            ? null
            : () {
                ref.read(widget.writerProvider).clearPlan();
                Navigator.of(context).pop(false);
              },
        child: const Text('Cancel'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: Colors.indigo.shade500),
        onPressed: canWrite ? _apply : null,
        child: Text(
          plan == null
              ? 'Replace index here'
              : 'Replace ${plan.totalRemoved} with ${plan.totalAdded}',
        ),
      ),
    ];
  }
}

class _BusyBody extends StatelessWidget {
  final String message;
  const _BusyBody({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Expanded(
              child: Text(message, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

/// The pending change, suburb by suburb.
class _PlanBody extends StatelessWidget {
  final LetterboxAreaPlan plan;
  final int freshInArea;

  const _PlanBody({required this.plan, required this.freshInArea});

  @override
  Widget build(BuildContext context) {
    if (plan.suburbs.isEmpty) {
      return const _Notice(
        'This area does not overlap any suburb boundary, so there is nowhere '
        'to store its letterboxes.',
        tone: _Tone.bad,
      );
    }
    if (freshInArea == 0) {
      return const _Notice(
        'No waypoints fall inside this area, so there is nothing to replace '
        'the index with. Emptying the area is not what this action does — '
        'use the curation page for that.',
        tone: _Tone.bad,
      );
    }

    final affected = plan.affected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$freshInArea waypoint(s) inside this area will become the '
          'letterbox index here, replacing the ${plan.totalRemoved} '
          'letterbox(es) currently inside it.',
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        if (affected.isEmpty)
          const _Notice('Nothing inside this area would change.',
              tone: _Tone.neutral)
        else ...[
          Text('Per suburb',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.blueGrey.shade600)),
          const SizedBox(height: 4),
          ...affected.map((s) => _SuburbRow(s)),
        ],
        if (plan.unplacedFresh > 0) ...[
          const SizedBox(height: 10),
          _Notice(
            '${plan.unplacedFresh} waypoint(s) in this area fall outside every '
            'suburb boundary and cannot be stored — the index is kept per '
            'suburb. Nudge the area off those streets, or fix the suburb '
            'boundary, if that number looks large.',
            tone: _Tone.warn,
          ),
        ],
        if (plan.unreadable.isNotEmpty) ...[
          const SizedBox(height: 10),
          _Notice(
            'Could not read the current index for '
            '${plan.unreadable.map((s) => s.suburbName).join(', ')} — left '
            'untouched rather than overwritten.',
            tone: _Tone.bad,
          ),
        ],
        if (plan.verifiedAffected.isNotEmpty) ...[
          const SizedBox(height: 10),
          _Notice(
            'This changes curated, signed-off suburb(s): '
            '${plan.verifiedAffected.map((s) => s.suburbName).join(', ')}. '
            'They stay verified, so quotes and distributor reviews will use '
            'these new numbers straight away.',
            tone: _Tone.warn,
          ),
        ],
        const SizedBox(height: 10),
        Text(
          'Undo is available for this session only — a page reload loses it.',
          style: TextStyle(fontSize: 10, color: Colors.blueGrey.shade400),
        ),
      ],
    );
  }
}

class _SuburbRow extends StatelessWidget {
  final LetterboxAreaSuburbPlan suburb;
  const _SuburbRow(this.suburb);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(suburb.suburbName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ),
          if (suburb.wasVerified)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Tooltip(
                message: 'Curated and signed off — stays verified',
                child: Icon(Icons.verified_outlined,
                    size: 13, color: Colors.green.shade600),
              ),
            ),
          Text('−${suburb.removeCount}',
              style: TextStyle(fontSize: 12, color: Colors.red.shade600)),
          const SizedBox(width: 8),
          Text('+${suburb.addCount}',
              style: TextStyle(fontSize: 12, color: Colors.green.shade700)),
        ],
      ),
    );
  }
}

/// What the write actually did.
class _DoneBody extends StatelessWidget {
  final LetterboxAreaWriteResult? result;
  final ClientAreaUpsert? clientArea;
  final String? error;

  const _DoneBody({
    required this.result,
    required this.clientArea,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    final done = result?.succeeded ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Notice(
          'Updated ${done.length} suburb(s): removed '
          '${result?.totalRemoved ?? 0}, added ${result?.totalAdded ?? 0}.',
          tone: _Tone.good,
        ),
        const SizedBox(height: 8),
        ...done.map((o) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '${o.suburbName}  ·  −${o.removed} / +${o.added}',
                style: const TextStyle(fontSize: 11),
              ),
            )),
        if (clientArea != null) ...[
          const SizedBox(height: 8),
          _Notice(
            '${clientArea!.wasCreated ? 'Added to' : 'Updated in'} Client Maps: '
            '"${clientArea!.saved.name}" — '
            '${clientArea!.saved.letterBoxEstimate} letterboxes'
            '${_splitSuffix(clientArea!.saved.letterBoxSplit)}.',
            tone: _Tone.good,
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 8),
          _Notice(error!, tone: _Tone.bad),
        ],
      ],
    );
  }

  /// " (812 houses, 388 flat boxes in 24 blocks)", or nothing when no split
  /// was recorded.
  static String _splitSuffix(LetterBoxSplit? split) {
    if (split == null || split.isEmpty) return '';
    final parts = <String>[];
    if (split.houses > 0) parts.add('${split.houses} houses');
    if (split.apartmentBoxes > 0) {
      parts.add(split.apartmentBlocks > 0
          ? '${split.apartmentBoxes} flat boxes in '
              '${split.apartmentBlocks} blocks'
          : '${split.apartmentBoxes} flat boxes');
    }
    return parts.isEmpty ? '' : ' (${parts.join(', ')})';
  }
}

/// The "also file this in Client Maps" tick.
class _ClientMapsToggle extends StatelessWidget {
  final bool value;
  final String areaName;
  final String client;
  final ValueChanged<bool> onChanged;

  const _ClientMapsToggle({
    required this.value,
    required this.areaName,
    required this.client,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: Checkbox(
                  value: value,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) => onChanged(v ?? false),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('Also save this area to Client Maps',
                          style: TextStyle(fontSize: 12)),
                    ),
                    Text(
                      'As "$areaName"'
                      '${client.isEmpty ? '' : ' for $client'}, with the count '
                      'and houses/flats split taken from the index after this '
                      'update.',
                      style: TextStyle(
                          fontSize: 10, color: Colors.blueGrey.shade500),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _Tone { good, warn, bad, neutral }

class _Notice extends StatelessWidget {
  final String message;
  final _Tone tone;
  const _Notice(this.message, {required this.tone});

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (tone) {
      _Tone.good => (Colors.green.shade50, Colors.green.shade800),
      _Tone.warn => (Colors.orange.shade50, Colors.orange.shade900),
      _Tone.bad => (Colors.red.shade50, Colors.red.shade800),
      _Tone.neutral => (Colors.blueGrey.shade50, Colors.blueGrey.shade700),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(message, style: TextStyle(fontSize: 11, color: fg)),
    );
  }
}
