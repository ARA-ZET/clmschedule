// widgets/linked_map_polygon_picker.dart
//
// Picks polygons out of a linked client map. Used in two places, which is
// why it lives on its own: linking a map to a schedule job
// (`job_map_link.dart`) and adopting polygons inside the work-areas map
// editor (`ShareableMapEditor`). Both ask the same question — which of this
// client map's outlines become the distributor's ground?
import 'package:flutter/material.dart';

import '../models/custom_polygon.dart';
import '../shareable_maps/utils/linked_map_polygons.dart';

export '../shareable_maps/utils/linked_map_polygons.dart'
    show
        LinkedMapPolygonGroup,
        allocatedPolygonStyle,
        linkedMapPolygonGroups,
        polygonGeometryKey;

/// Shows the picker. Returns the chosen polygons, or null if cancelled.
/// Polygons whose outline is in [alreadyAdded] are listed as ticked and
/// disabled.
Future<List<CustomPolygon>?> showLinkedMapPolygonPicker(
  BuildContext context, {
  required String mapName,
  required List<LinkedMapPolygonGroup> groups,
  required Set<String> alreadyAdded,
  String? title,
}) =>
    showDialog<List<CustomPolygon>>(
      context: context,
      builder: (_) => _PickerDialog(
        mapName: mapName,
        groups: groups,
        alreadyAdded: alreadyAdded,
        title: title,
      ),
    );

class _PickerDialog extends StatefulWidget {
  final String mapName;
  final List<LinkedMapPolygonGroup> groups;
  final Set<String> alreadyAdded;
  final String? title;

  const _PickerDialog({
    required this.mapName,
    required this.groups,
    required this.alreadyAdded,
    this.title,
  });

  @override
  State<_PickerDialog> createState() =>
      _PickerDialogState();
}

class _PickerDialogState
    extends State<_PickerDialog> {
  final Set<CustomPolygon> _selected = {};

  bool _isAdded(CustomPolygon p) =>
      widget.alreadyAdded.contains(polygonGeometryKey(p));

  List<CustomPolygon> get _selectable => [
        for (final g in widget.groups)
          for (final p in g.polygons)
            if (!_isAdded(p)) p,
      ];

  @override
  Widget build(BuildContext context) {
    final selectable = _selectable;
    final allSelected =
        selectable.isNotEmpty && selectable.every(_selected.contains);
    final showLayerHeaders = widget.groups.length > 1;

    return AlertDialog(
      title: Text(widget.title ?? 'Add polygons from "${widget.mapName}"'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Selected polygons are added to this job, so they show on the '
              'day planner and in the track editor.',
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Select all'),
              value: allSelected,
              onChanged: selectable.isEmpty
                  ? null
                  : (v) => setState(() {
                        if (v == true) {
                          _selected.addAll(selectable);
                        } else {
                          _selected.clear();
                        }
                      }),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final g in widget.groups) ...[
                    if (showLayerHeaders)
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 2),
                        child: Text(
                          g.name.isNotEmpty ? g.name : 'Layer',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                    for (final p in g.polygons) _polygonTile(p),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Skip'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected.toList()),
          child: Text(_selected.isEmpty
              ? 'Add to job'
              : 'Add ${_selected.length} to job'),
        ),
      ],
    );
  }

  Widget _polygonTile(CustomPolygon p) {
    final onJob = _isAdded(p);
    final estimate = p.letterBoxEstimate;
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: onJob || _selected.contains(p),
      onChanged: onJob
          ? null
          : (v) => setState(() {
                if (v == true) {
                  _selected.add(p);
                } else {
                  _selected.remove(p);
                }
              }),
      secondary: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: p.color.withValues(alpha: 0.6),
          border: Border.all(color: p.color, width: 2),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      title: Text(p.name),
      subtitle: onJob
          ? const Text('Already on this job')
          : estimate > 0
              ? Text('$estimate letterboxes')
              : null,
    );
  }
}
