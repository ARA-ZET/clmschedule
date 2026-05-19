import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/collection_job.dart';
import '../../models/dropsheet_day.dart';
import '../../models/dropsheet_task.dart';
import '../../models/dropsheet_task_type_config.dart';
import '../../providers/dropsheet_provider.dart';
import '../../providers/dropsheet_task_config_provider.dart';
import 'dropsheet_tab.dart' show TaskDragPayload;
import 'dropsheet_task_editor_dialog.dart';
import 'dropsheet_task_row.dart';

/// One driver's section: header (name + vehicle/trailer) and a reorderable
/// list of tasks. Tasks may be reordered within the section; cross-section
/// moves use the "Move to..." popup on each task row.
class DriverSectionWidget extends riverpod.ConsumerWidget {
  final DropsheetDriverSection section;
  final List<DropsheetDriverSection> allSections;
  final ValueChanged<TaskDragPayload>? onAcceptCrossSectionDrop;

  const DriverSectionWidget({
    super.key,
    required this.section,
    required this.allSections,
    this.onAcceptCrossSectionDrop,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final dropsheet = ref.read(dropsheetRiverpod);
    // Compute once per build instead of inside the itemBuilder where it
    // would allocate a new filtered list per row.
    final otherSections = _otherSections();
    final hasOtherSections = otherSections.isNotEmpty;

    return DragTarget<TaskDragPayload>(
      onWillAcceptWithDetails: (details) =>
          details.data.fromSectionId != section.id,
      onAcceptWithDetails: (details) async {
        await dropsheet.moveTask(
          fromSectionId: details.data.fromSectionId,
          fromIndex: details.data.fromIndex,
          toSectionId: section.id,
          toIndex: section.tasks.length,
        );
      },
      builder: (context, candidate, rejected) {
        final isHover = candidate.isNotEmpty;
        return Card(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: isHover ? Colors.blue : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(section: section),
              const _ColumnHeaders(),
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: section.tasks.length,
                onReorder: (oldIndex, newIndex) async {
                  // Compensate for the standard Flutter quirk where
                  // newIndex is shifted when moving down within the same list.
                  final adjusted =
                      newIndex > oldIndex ? newIndex - 1 : newIndex;
                  await dropsheet.moveTask(
                    fromSectionId: section.id,
                    fromIndex: oldIndex,
                    toSectionId: section.id,
                    toIndex: adjusted,
                  );
                },
                itemBuilder: (context, index) {
                  final task = section.tasks[index];
                  return DropsheetTaskRow(
                    key: ValueKey(task.id),
                    task: task,
                    taskNumber: index + 1,
                    dragIndex: index,
                    sectionId: section.id,
                    onEdit: () => _editTask(context, ref, task),
                    onDelete: _isLeadingTask(task)
                        ? null
                        : () => dropsheet.removeTask(section.id, task.id),
                    onMoveToSection: !hasOtherSections
                        ? null
                        : (targetSectionId) async {
                            await dropsheet.moveTask(
                              fromSectionId: section.id,
                              fromIndex: index,
                              toSectionId: targetSectionId,
                              toIndex: 0,
                            );
                          },
                    otherSections: otherSections,
                  );
                },
              ),
              if (section.tasks.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: Text(
                      isHover
                          ? 'Drop here'
                          : 'No tasks yet — drag stops here or tap “Add task”',
                      style: TextStyle(
                        color: isHover ? Colors.blue : Colors.grey,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ),
              _Footer(section: section),
            ],
          ),
        );
      },
    );
  }

  List<DropsheetDriverSection> _otherSections() =>
      allSections.where((s) => s.id != section.id).toList();

  bool _isLeadingTask(DropsheetTask task) =>
      task.isMandatory ||
      task.type == DropsheetTaskType.inspect ||
      task.type == DropsheetTaskType.pack ||
      task.type == DropsheetTaskType.leave;

  Future<void> _editTask(
      BuildContext context, riverpod.WidgetRef ref, DropsheetTask task) async {
    final sheetDate = ref.read(dropsheetRiverpod).date;
    final updated = await showDialog<DropsheetTask>(
      context: context,
      builder: (_) => DropsheetTaskEditorDialog(
        initial: task,
        sheetDate: sheetDate,
      ),
    );
    if (updated == null) return;
    await ref.read(dropsheetRiverpod).updateTask(section.id, updated);

    // When the Leave task's departure time changes and the section already
    // has a computed route, propagate new ETAs offline using stored leg data.
    if (updated.type == DropsheetTaskType.leave &&
        updated.startTime.isNotEmpty &&
        updated.startTime != task.startTime) {
      final config = ref.read(dropsheetTaskConfigRiverpod);
      await ref.read(dropsheetRiverpod).recalculateETAsFromLegs(
            section.id,
            updated.startTime,
            config.serviceMinutesFor,
          );
    }

    // For any other task: if the start time was manually changed, shift
    // all tasks that come after it in the section by the same delta so
    // relative spacing is preserved without re-running the route API.
    if (updated.type != DropsheetTaskType.leave &&
        updated.startTime.isNotEmpty &&
        task.startTime.isNotEmpty &&
        updated.startTime != task.startTime) {
      final delta =
          _hhmToMinutes(updated.startTime) - _hhmToMinutes(task.startTime);
      if (delta != 0) {
        await ref.read(dropsheetRiverpod).shiftStartTimesAfter(
              sectionId: section.id,
              taskId: updated.id,
              deltaMinutes: delta,
            );
      }
    }
  }

  static int _hhmToMinutes(String hhmm) {
    final p = hhmm.split(':');
    if (p.length != 2) return 0;
    return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }
}

class _Header extends riverpod.ConsumerWidget {
  final DropsheetDriverSection section;
  const _Header({required this.section});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final isUnassigned = section.id == kUnassignedSectionId;
    return Container(
      color: isUnassigned ? Colors.orange.shade50 : Colors.grey.shade200,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (isUnassigned)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.inbox, color: Colors.orange),
            ),
          Text(
            section.driverName,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 16),
          if (section.vehicle != null)
            _Chip(label: section.vehicle!.displayName, color: Colors.blue),
          const SizedBox(width: 6),
          if (section.trailer != null &&
              section.trailer != TrailerType.noTrailer)
            _Chip(
                label: section.trailer!.displayName, color: Colors.deepPurple),
          if (isUnassigned)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Text(
                'Long-press a stop and drop it onto a driver',
                style: TextStyle(
                    color: Colors.orange,
                    fontSize: 12,
                    fontStyle: FontStyle.italic),
              ),
            ),
          const Spacer(),
          if (!isUnassigned)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'edit', child: Text('Edit driver / vehicle')),
                PopupMenuItem(value: 'remove', child: Text('Remove section')),
              ],
              onSelected: (v) async {
                final dropsheet = ref.read(dropsheetRiverpod);
                if (v == 'remove') {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Remove section?'),
                      content: Text(
                          'Remove ${section.driverName} from this dropsheet? All their tasks will be lost.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('CANCEL')),
                        FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: Colors.red),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('REMOVE')),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await dropsheet.removeDriverSection(section.id);
                  }
                } else if (v == 'edit') {
                  await _editVehicleTrailer(context, ref);
                }
              },
            ),
        ],
      ),
    );
  }

  Future<void> _editVehicleTrailer(
      BuildContext context, riverpod.WidgetRef ref) async {
    VehicleType? vehicle = section.vehicle;
    TrailerType? trailer = section.trailer ?? TrailerType.noTrailer;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('${section.driverName} — vehicle'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<VehicleType>(
                initialValue: vehicle,
                decoration: const InputDecoration(labelText: 'Vehicle'),
                items: VehicleType.values
                    .map((v) =>
                        DropdownMenuItem(value: v, child: Text(v.displayName)))
                    .toList(),
                onChanged: (v) => setState(() => vehicle = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<TrailerType>(
                initialValue: trailer,
                decoration: const InputDecoration(labelText: 'Trailer'),
                items: TrailerType.values
                    .map((t) =>
                        DropdownMenuItem(value: t, child: Text(t.displayName)))
                    .toList(),
                onChanged: (t) => setState(() => trailer = t),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('CANCEL')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('SAVE')),
          ],
        ),
      ),
    );
    if (ok == true) {
      await ref.read(dropsheetRiverpod).updateDriverSection(
            section.copyWith(vehicle: vehicle, trailer: trailer),
          );
    }
  }
}

class _ColumnHeaders extends StatelessWidget {
  const _ColumnHeaders();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontWeight: FontWeight.bold, fontSize: 12);
    return Container(
      color: Colors.grey.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: const Row(
        children: [
          SizedBox(width: 32), // drag handle space
          SizedBox(width: 64, child: Text('Task', style: style)),
          SizedBox(width: 12),
          Expanded(flex: 2, child: Text('Job', style: style)),
          SizedBox(width: 12),
          Expanded(flex: 3, child: Text('Details', style: style)),
          SizedBox(width: 12),
          SizedBox(width: 70, child: Text('Start', style: style)),
          SizedBox(width: 12),
          Expanded(flex: 3, child: Text('Location', style: style)),
          SizedBox(width: 12),
          Expanded(flex: 2, child: Text('Contact', style: style)),
          SizedBox(width: 12),
          Expanded(flex: 2, child: Text('Tel', style: style)),
          SizedBox(width: 40), // actions
        ],
      ),
    );
  }
}

class _Footer extends riverpod.ConsumerWidget {
  final DropsheetDriverSection section;
  const _Footer({required this.section});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () async {
            // Step 1: pick the type.
            final selection = await showDialog<TaskTypeSelection>(
              context: context,
              builder: (_) => const DropsheetTaskTypePicker(),
            );
            if (selection == null) return;
            if (!context.mounted) return;
            final dropsheet = ref.read(dropsheetRiverpod);
            // Build the initial task based on whether it's a dynamic type.
            final DropsheetTask initialTask;
            if (selection.isDynamic) {
              final def = selection.dynamicType!;
              initialTask = DropsheetTask(
                id: 't_${DateTime.now().microsecondsSinceEpoch}',
                type: DropsheetTaskType.custom,
                job: def.label,
                typeData: {'dynamicTypeId': def.id},
              );
            } else {
              final t = selection.type;
              initialTask = DropsheetTask(
                id: 't_${DateTime.now().microsecondsSinceEpoch}',
                type: t,
                job: t.displayName,
              );
            }
            // Step 2: open the type-aware editor.
            final newTask = await showDialog<DropsheetTask>(
              context: context,
              builder: (_) => DropsheetTaskEditorDialog(
                initial: initialTask,
                sheetDate: dropsheet.date,
              ),
            );
            if (newTask != null) {
              await dropsheet.addTask(section.id, task: newTask);
            }
          },
          icon: const Icon(Icons.add),
          label: const Text('Add task'),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}
