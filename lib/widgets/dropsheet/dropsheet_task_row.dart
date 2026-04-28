import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/dropsheet_day.dart';
import '../../models/dropsheet_task.dart';
import '../../utils/dropsheet_maps.dart';
import 'dropsheet_tab.dart' show TaskDragPayload;

/// Single task row inside a driver section.
///
/// The Location cell is type-aware: for `dropOff`/`pickUp`/`collection`/
/// `furnitureMove` the cell shows a derived label and tapping the
/// adjacent map icon opens Google Maps. Drag handle on the left lets the
/// parent ReorderableListView reorder tasks within the same section.
class DropsheetTaskRow extends StatelessWidget {
  final DropsheetTask task;
  final int taskNumber; // 1-based
  final int dragIndex;
  final String sectionId;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;
  final ValueChanged<String>? onMoveToSection;
  final List<DropsheetDriverSection> otherSections;

  const DropsheetTaskRow({
    super.key,
    required this.task,
    required this.taskNumber,
    required this.dragIndex,
    required this.sectionId,
    required this.onEdit,
    this.onDelete,
    this.onMoveToSection,
    this.otherSections = const [],
  });

  @override
  Widget build(BuildContext context) {
    final mapLinks = DropsheetMaps.linksFor(task);
    final locationLabel = DropsheetMaps.locationLabel(task);
    final jobLabel = task.job.isNotEmpty
        ? task.job
        : DropsheetMaps.defaultJobLabel(task.type);

    final payload = TaskDragPayload(
      fromSectionId: sectionId,
      fromIndex: dragIndex,
      toIndex: 0,
      task: task,
    );

    final rowContent = InkWell(
      onTap: onEdit,
      child: Container(
        decoration: BoxDecoration(
          color: task.isMandatory
              ? Colors.amber.withValues(alpha: 0.08)
              : null,
          border: Border(
            bottom: BorderSide(color: Colors.grey.shade200),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: dragIndex,
              child: const SizedBox(
                width: 32,
                child: Icon(Icons.drag_indicator,
                    size: 18, color: Colors.grey),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                'Task $taskNumber',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: _cell(jobLabel, bold: true)),
            const SizedBox(width: 12),
            Expanded(flex: 3, child: _cell(task.details)),
            const SizedBox(width: 12),
            SizedBox(width: 70, child: _cell(task.startTime)),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: _LocationCell(
                label: locationLabel,
                links: mapLinks,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: _cell(task.contact)),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: _cell(task.tel)),
            SizedBox(
              width: 40,
              child: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 18),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  if (otherSections.isNotEmpty)
                    const PopupMenuItem(
                        value: 'move', child: Text('Move to driver…')),
                  if (onDelete != null)
                    const PopupMenuItem(
                      value: 'delete',
                      child:
                          Text('Delete', style: TextStyle(color: Colors.red)),
                    ),
                ],
                onSelected: (v) async {
                  if (v == 'edit') {
                    onEdit();
                  } else if (v == 'delete') {
                    onDelete?.call();
                  } else if (v == 'move') {
                    final sel = await showDialog<String>(
                      context: context,
                      builder: (ctx) => SimpleDialog(
                        title: const Text('Move to driver'),
                        children: otherSections
                            .map(
                              (s) => SimpleDialogOption(
                                onPressed: () => Navigator.pop(ctx, s.id),
                                child: Text(s.driverName),
                              ),
                            )
                            .toList(),
                      ),
                    );
                    if (sel != null) onMoveToSection?.call(sel);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );

    // Long-press anywhere on the row body initiates a cross-section drag.
    // The drag handle on the left still uses ReorderableDragStartListener
    // for in-section reorder, so the two gestures do not conflict.
    return LongPressDraggable<TaskDragPayload>(
      data: payload,
      delay: const Duration(milliseconds: 300),
      feedback: Material(
        elevation: 6,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: Colors.white,
          width: 320,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.drag_indicator, color: Colors.blue),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  jobLabel.isEmpty ? 'Task' : jobLabel,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: rowContent),
      child: rowContent,
    );
  }

  Widget _cell(String text, {bool bold = false}) {
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
      ),
    );
  }
}

class _LocationCell extends StatelessWidget {
  final String label;
  final List<DropsheetMapLink> links;
  const _LocationCell({required this.label, required this.links});

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) {
      return Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (links.length == 1) {
      return InkWell(
        onTap: () => _open(links.first.url),
        child: Row(
          children: [
            const Icon(Icons.location_on, size: 16, color: Colors.blue),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.blue,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      );
    }
    // Multiple stops (furniture move).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: links
          .map(
            (l) => InkWell(
              onTap: () => _open(l.url),
              child: Row(
                children: [
                  const Icon(Icons.location_on, size: 14, color: Colors.blue),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      l.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.blue,
                        decoration: TextDecoration.underline,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
