import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/dropsheet_day.dart';
import '../../models/dropsheet_task.dart';
import '../../utils/dropsheet_layout.dart';
import '../../utils/dropsheet_maps.dart';
import 'dropsheet_tab.dart' show TaskDragPayload;

/// Single task row inside a driver section.
///
/// The Location cell is type-aware: for `dropOff`/`pickUp`/`collection`/
/// `furnitureMove` the cell shows a derived label and tapping the
/// adjacent map icon opens Google Maps. Drag handle on the left lets the
/// parent ReorderableListView reorder tasks within the same section.
/// Row geometry, shared with the column headers so they line up.
const double kRowPaddingH = 8;
const double kRowHandleWidth = 36;
const double kRowNumberWidth = 48;
const double kRowStartWidth = 70;
const double kRowMenuWidth = 32;
const double kRowGap = 6;

class DropsheetTaskRow extends StatelessWidget {
  final DropsheetTask task;
  /// The map's stop number (null for fixed rows and stops with no
  /// location) — the same number the printed sheet shows.
  final int? stopNumber;
  final int dragIndex;
  final String sectionId;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;
  final ValueChanged<String>? onMoveToSection;
  final List<DropsheetDriverSection> otherSections;

  /// "Same drop point as Thabo, Sipho" when this stop shares its point with
  /// others on the run (see shared_drop_points.dart); null otherwise.
  final String? sharedNote;

  /// Vehicle-inspection status under the Inspect / Arrive rows (see
  /// InspectionStatusLine); null on every other row.
  final Widget? inspectionLine;

  const DropsheetTaskRow({
    super.key,
    required this.task,
    required this.stopNumber,
    required this.dragIndex,
    required this.sectionId,
    required this.onEdit,
    this.onDelete,
    this.onMoveToSection,
    this.otherSections = const [],
    this.sharedNote,
    this.inspectionLine,
  });

  String get _numberText {
    final n = task.isTwoStop
        ? task.twoStopNumbers(stopNumber).loading
        : stopNumber;
    return n == null ? '' : '#$n';
  }

  /// A two-stop task's Offloading line number (its own map pin).
  String get _offloadNumberText {
    final n = task.twoStopNumbers(stopNumber).offload;
    return n == null ? '' : '#$n';
  }

  @override
  Widget build(BuildContext context) {
    if (task.typeData['isPickupDivider'] == true) {
      return _buildPickupSeparator(context);
    }

    final mapLinks = DropsheetMaps.linksFor(task);
    final locationLabel = DropsheetMaps.locationLabel(task);
    final jobLabel = task.displayJob;

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
          color: task.isMandatory ? Colors.amber.withValues(alpha: 0.08) : null,
          border: Border(
            bottom: BorderSide(color: Colors.grey.shade200),
          ),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: 8,
        ),
        child: LayoutBuilder(
          builder: (lCtx, box) => box.maxWidth >= 700
              ? _buildWideRow(lCtx, jobLabel, locationLabel, mapLinks)
              : _buildNarrowRow(lCtx, jobLabel, locationLabel, mapLinks),
        ),
      ),
    );

    // Long-press anywhere on the row body initiates a cross-section drag.
    // The drag handle on the left still uses ReorderableDragStartListener
    // for in-section reorder, so the two gestures do not conflict.
    return LongPressDraggable<TaskDragPayload>(
      data: payload,
      delay: const Duration(milliseconds: 500),
      feedback: Material(
        elevation: 6,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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

  /// Renders the "Leave and start pickups" separator row.
  ///
  /// Purely visual — it carries no time or location. Afternoon pick-up ETAs
  /// are anchored to the Arrive task's target time and computed backwards.
  Widget _buildPickupSeparator(BuildContext context) {
    const sepColor = Color(0xFF1565C0);

    final payload = TaskDragPayload(
      fromSectionId: sectionId,
      fromIndex: dragIndex,
      toIndex: 0,
      task: task,
    );

    final content = InkWell(
      onTap: onEdit,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFE3F2FD),
          border: Border.symmetric(
            horizontal: BorderSide(color: sepColor, width: 1.5),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            // Drag handle for in-section reorder.
            ReorderableDragStartListener(
              index: dragIndex,
              child: const SizedBox(
                width: 36,
                child: Icon(Icons.drag_indicator, size: 20, color: Colors.grey),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.keyboard_return, size: 15, color: sepColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                task.job.isNotEmpty ? task.job : kPickupDividerLabel,
                style: const TextStyle(
                  color: sepColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
            _buildMenuButton(context),
          ],
        ),
      ),
    );

    return LongPressDraggable<TaskDragPayload>(
      data: payload,
      delay: const Duration(milliseconds: 500),
      feedback: Material(
        elevation: 6,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: const Color(0xFFE3F2FD),
          width: 280,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.drag_indicator, color: sepColor),
              SizedBox(width: 8),
              Text(
                'Leave and start pickups',
                style: TextStyle(
                    color: sepColor, fontWeight: FontWeight.w700, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: content),
      child: content,
    );
  }

  Widget _cell(String text, {bool bold = true}) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        height: 1.1,
        fontWeight: bold ? FontWeight.bold : FontWeight.w600,
      ),
    );
  }

  Widget _cellWrap(String text, {bool bold = true}) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        height: 1.2,
        fontWeight: bold ? FontWeight.bold : FontWeight.w600,
      ),
    );
  }

  Widget _buildMenuButton(BuildContext context) {
    return SizedBox(
      width: 32,
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 16),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
          if (otherSections.isNotEmpty)
            const PopupMenuItem(value: 'move', child: Text('Move to driver…')),
          if (onDelete != null)
            const PopupMenuItem(
              value: 'delete',
              child: Text('Delete', style: TextStyle(color: Colors.red)),
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
    );
  }

  Widget _sharedNoteLine() => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 3),
        child: Row(
          children: [
            const Icon(Icons.groups, size: 14, color: Color(0xFF00796B)),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                sharedNote!,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF00796B),
                ),
              ),
            ),
          ],
        ),
      );

  /// Early (blue) or late (red) for a booked time, from route timing.
  Widget? _lateLine() {
    final note = task.bookingTimingNote;
    if (note == null) return null;
    final late = task.appointmentLateMinutes > 0;
    final color = late ? const Color(0xFFC62828) : const Color(0xFF1565C0);
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 3),
      child: Row(
        children: [
          Icon(late ? Icons.warning_amber_rounded : Icons.schedule,
              size: 14, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              note,
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWideRow(BuildContext context, String jobLabel,
      String locationLabel, List<DropsheetMapLink> mapLinks) {
    final row = task.isTwoStop
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildWideCells(
                  context,
                  task.loadingLineLabel,
                  task.loadingAddress,
                  DropsheetMaps.twoStopLinks(task.loadingAddress)),
              _buildWideCells(
                  context,
                  task.offloadingLineLabel,
                  task.offloadAddress,
                  DropsheetMaps.twoStopLinks(task.offloadAddress),
                  continuation: true),
            ],
          )
        : _buildWideCells(context, jobLabel, locationLabel, mapLinks);
    final late = _lateLine();
    if (sharedNote == null && late == null && inspectionLine == null) {
      return row;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        if (inspectionLine != null)
          Padding(
              padding: const EdgeInsets.only(left: 90),
              child: inspectionLine),
        if (late != null)
          Padding(padding: const EdgeInsets.only(left: 90), child: late),
        if (sharedNote != null)
          Padding(
            padding: const EdgeInsets.only(left: 90),
            child: _sharedNoteLine(),
          ),
      ],
    );
  }

  /// One row of cells. [continuation] is a two-stop task's Offloading line:
  /// no handle, number, details, contact or menu — those sit on the Loading
  /// line — and the offload time in Start.
  Widget _buildWideCells(BuildContext context, String jobLabel,
      String locationLabel, List<DropsheetMapLink> mapLinks,
      {bool continuation = false}) {
    return Row(
      children: [
        if (continuation)
          const SizedBox(width: kRowHandleWidth)
        else
          ReorderableDragStartListener(
            index: dragIndex,
            child: const SizedBox(
              width: 36,
              child: Icon(Icons.apps, size: 20, color: Colors.grey),
            ),
          ),
        SizedBox(
          width: kRowNumberWidth,
          child: Text(
            continuation ? _offloadNumberText : _numberText,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: kRowGap),
        Expanded(
            flex: DropsheetColumn.job.flex!,
            child: _cell(jobLabel, bold: true)),
        const SizedBox(width: kRowGap),
        Expanded(
            flex: DropsheetColumn.details.flex!,
            child: _cell(continuation ? '' : task.detailsText, bold: true)),
        const SizedBox(width: 6),
        SizedBox(
            width: kRowStartWidth,
            child: _cell(continuation ? task.offloadTime : task.startTime)),
        const SizedBox(width: kRowGap),
        Expanded(
          flex: DropsheetColumn.location.flex!,
          child: _LocationCell(label: locationLabel, links: mapLinks),
        ),
        const SizedBox(width: 6),
        Expanded(
            flex: DropsheetColumn.contact.flex!,
            child: _cell(continuation ? '' : task.contact, bold: true)),
        const SizedBox(width: kRowGap),
        Expanded(
            flex: DropsheetColumn.tel.flex!,
            child: _cell(continuation ? '' : task.tel, bold: true)),
        if (continuation)
          const SizedBox(width: kRowMenuWidth)
        else
          _buildMenuButton(context),
      ],
    );
  }

  Widget _buildNarrowRow(BuildContext context, String jobLabel,
      String locationLabel, List<DropsheetMapLink> mapLinks) {
    const indent = 90.0; // drag(36) + number(48) + gap(6)
    if (task.isTwoStop) {
      jobLabel = task.loadingLineLabel;
      locationLabel = task.loadingAddress;
      mapLinks = DropsheetMaps.twoStopLinks(task.loadingAddress);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            ReorderableDragStartListener(
              index: dragIndex,
              child: const SizedBox(
                width: 36,
                child: Icon(Icons.apps, size: 20, color: Colors.grey),
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                _numberText,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(child: _cellWrap(jobLabel)),
            const SizedBox(width: 6),
            if (task.startTime.isNotEmpty)
              SizedBox(width: 60, child: _cell(task.startTime)),
            _buildMenuButton(context),
          ],
        ),
        if (task.detailsText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: indent, top: 2),
            child: _cellWrap(task.detailsText),
          ),
        Padding(
          padding: const EdgeInsets.only(left: indent, top: 2),
          child: _LocationCell(
            label: locationLabel,
            links: mapLinks,
            allowWrap: true,
          ),
        ),
        // A two-stop task's Offloading line, under its Loading line.
        if (task.isTwoStop) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                const SizedBox(width: kRowHandleWidth),
                SizedBox(
                  width: 48,
                  child: Text(
                    _offloadNumberText,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(child: _cellWrap(task.offloadingLineLabel)),
                const SizedBox(width: 6),
                if (task.offloadTime.isNotEmpty)
                  SizedBox(width: 60, child: _cell(task.offloadTime)),
                const SizedBox(width: kRowMenuWidth),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: indent, top: 2),
            child: _LocationCell(
              label: task.offloadAddress,
              links: DropsheetMaps.twoStopLinks(task.offloadAddress),
              allowWrap: true,
            ),
          ),
        ],
        if (inspectionLine != null)
          Padding(
              padding: const EdgeInsets.only(left: indent),
              child: inspectionLine),
        if (_lateLine() case final late?)
          Padding(padding: const EdgeInsets.only(left: indent), child: late),
        if (sharedNote != null)
          Padding(
            padding: const EdgeInsets.only(left: indent),
            child: _sharedNoteLine(),
          ),
        if (task.contact.isNotEmpty || task.tel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: indent, top: 2, bottom: 4),
            child: Wrap(
              spacing: 10,
              runSpacing: 2,
              children: [
                if (task.contact.isNotEmpty) _cellWrap(task.contact),
                if (task.tel.isNotEmpty) _cellWrap(task.tel),
              ],
            ),
          ),
      ],
    );
  }
}

class _LocationCell extends StatelessWidget {
  final String label;
  final List<DropsheetMapLink> links;
  final bool allowWrap;
  const _LocationCell({
    required this.label,
    required this.links,
    this.allowWrap = false,
  });

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) {
      return Text(
        label,
        maxLines: allowWrap ? null : 1,
        overflow: allowWrap ? null : TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 11,
          height: 1.2,
          fontWeight: FontWeight.bold,
        ),
      );
    }
    if (links.length == 1) {
      return InkWell(
        onTap: () => _open(links.first.url),
        child: Row(
          children: [
            const Icon(Icons.location_on, size: 14, color: Colors.blue),
            const SizedBox(width: 2),
            Expanded(
              child: Text(
                label,
                maxLines: allowWrap ? null : 1,
                overflow: allowWrap ? null : TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
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
                  const Icon(Icons.location_on, size: 12, color: Colors.blue),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      l.label,
                      maxLines: allowWrap ? null : 1,
                      overflow: allowWrap ? null : TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.15,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                        decoration: TextDecoration.underline,
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
