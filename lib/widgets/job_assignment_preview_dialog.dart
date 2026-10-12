import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/job_assignment_service.dart';

/// Shows the proposed schedule allocation and lets the user change who each
/// day is allocated to before confirming.
class JobAssignmentPreviewDialog extends StatefulWidget {
  final List<JobAssignment> assignments;

  /// Distributors that may be picked on a date, free ones first.
  final List<DistributorCandidate> Function(DateTime date) candidatesFor;

  /// Distributors who already have a job that day are offered too.
  final bool allowOccupied;

  final ValueChanged<List<JobAssignment>> onConfirm;
  final VoidCallback onCancel;

  /// Shown above the rows, e.g. which regular-client plan this came from or
  /// areas the plan names that the map no longer has.
  final String? note;

  const JobAssignmentPreviewDialog({
    super.key,
    required this.assignments,
    required this.candidatesFor,
    required this.onConfirm,
    required this.onCancel,
    this.allowOccupied = false,
    this.note,
  });

  @override
  State<JobAssignmentPreviewDialog> createState() =>
      _JobAssignmentPreviewDialogState();
}

class _JobAssignmentPreviewDialogState
    extends State<JobAssignmentPreviewDialog> {
  late final List<JobAssignment> _assignments = [...widget.assignments];
  final Map<DateTime, List<DistributorCandidate>> _candidates = {};

  List<DistributorCandidate> _candidatesOn(DateTime date) =>
      _candidates.putIfAbsent(date, () => widget.candidatesFor(date));

  /// Options for one row: that day's candidates, less anyone already picked
  /// in another row on the same day — one person takes one share of a job.
  List<DistributorCandidate> _optionsFor(int row) {
    final a = _assignments[row];
    final takenElsewhere = {
      for (var n = 0; n < _assignments.length; n++)
        if (n != row && _sameDay(_assignments[n].date, a.date))
          _assignments[n].distributorId,
    };
    return _candidatesOn(_dayOf(a.date))
        .where((c) => !takenElsewhere.contains(c.distributor.id))
        .toList();
  }

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
  static bool _sameDay(DateTime a, DateTime b) => _dayOf(a) == _dayOf(b);

  void _pick(int row, DistributorCandidate c) {
    setState(() {
      _assignments[row] = _assignments[row].copyWith(
        distributorId: c.distributor.id,
        distributorName: c.distributor.name,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final assignments = _assignments;
    // Group row indices by date for better display
    final Map<DateTime, List<int>> groupedAssignments = {};
    for (var n = 0; n < assignments.length; n++) {
      groupedAssignments
          .putIfAbsent(_dayOf(assignments[n].date), () => [])
          .add(n);
    }

    // Sort dates
    final sortedDates = groupedAssignments.keys.toList()..sort();

    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.7,
        height: MediaQuery.of(context).size.height * 0.8,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Job Assignment Preview',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                IconButton(
                  onPressed: widget.onCancel,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Summary
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Assignment Summary',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text('Total Jobs: ${assignments.length}'),
                      ),
                      Expanded(
                        child: Text('Days Span: ${sortedDates.length}'),
                      ),
                      Expanded(
                        child: Text(
                            'Client: ${assignments.isNotEmpty ? assignments.first.client : "N/A"}'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.allowOccupied
                        ? 'Tap a name to change who it is allocated to. '
                            'Distributors who already have a job that day '
                            'can be picked too.'
                        : 'Tap a name to change who it is allocated to.',
                    style: TextStyle(
                        fontSize: 12, color: Colors.blue.shade700),
                  ),
                  if (widget.note != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      widget.note!,
                      style: TextStyle(
                          fontSize: 12, color: Colors.indigo.shade700),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Assignment Details
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Assignment Details',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 12),
                    ...sortedDates.map((date) => _buildDateSection(
                        context, date, groupedAssignments[date]!)),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: widget.onCancel,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 16),
                ElevatedButton.icon(
                  onPressed: () => widget.onConfirm(List.unmodifiable(_assignments)),
                  icon: const Icon(Icons.check),
                  label: const Text('Confirm & Add Jobs'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateSection(
      BuildContext context, DateTime date, List<int> rowsForDate) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.orange.shade100,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              DateFormat('EEEE, MMMM d, yyyy').format(date),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade800,
                  ),
            ),
          ),
          const SizedBox(height: 12),

          // Assignments for this date
          for (final row in rowsForDate) _buildRow(context, row),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, int row) {
    final assignment = _assignments[row];
    final options = _optionsFor(row);
    final current = options
        .where((c) => c.distributor.id == assignment.distributorId)
        .firstOrNull;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.person, color: Colors.blue.shade600, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (assignment.label != null)
                  Text(
                    assignment.label!,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.indigo.shade700,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    isDense: true,
                    value: current?.distributor.id,
                    hint: Text(assignment.distributorName),
                    items: [
                      for (final c in options)
                        DropdownMenuItem(
                          value: c.distributor.id,
                          child: Text(
                            c.hasJobThatDay
                                ? '${c.distributor.name}  (has a job)'
                                : c.distributor.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: c.hasJobThatDay
                                  ? Colors.orange.shade800
                                  : null,
                            ),
                          ),
                        ),
                    ],
                    onChanged: (id) {
                      final picked =
                          options.where((c) => c.distributor.id == id);
                      if (picked.isNotEmpty) _pick(row, picked.first);
                    },
                  ),
                ),
                Text(
                  assignment.workMaps.isEmpty
                      ? 'Work Area: ${assignment.workingArea}'
                      : '${assignment.workMaps.length} area'
                          '${assignment.workMaps.length == 1 ? '' : 's'}: '
                          '${assignment.workingArea}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade600,
                      ),
                ),
              ],
            ),
          ),
          if (current?.hasJobThatDay ?? false)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.orange.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Double-booked',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.orange.shade800,
                  fontWeight: FontWeight.w500,
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Scheduled',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.green.shade700,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
