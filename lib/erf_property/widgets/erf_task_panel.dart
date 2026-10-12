import 'dart:async';

import 'package:flutter/material.dart';

import '../models/erf_task.dart';

/// Live view of a running ERF operation.
///
/// Shows the named stages, which one is active, a determinate bar whenever
/// the size is known, and — the part that matters most here — elapsed time
/// with an estimate of what is left. The cadastral register takes 30-60
/// seconds per page, so without this a suburb download is several minutes of
/// an unexplained spinner.
class ErfTaskPanel extends StatefulWidget {
  const ErfTaskPanel({
    super.key,
    required this.task,
    this.onCancel,
    this.compact = false,
  });

  final ErfTask task;
  final VoidCallback? onCancel;

  /// Narrow layouts drop the stage list and keep the headline plus bar.
  final bool compact;

  @override
  State<ErfTaskPanel> createState() => _ErfTaskPanelState();
}

class _ErfTaskPanelState extends State<ErfTaskPanel> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // The elapsed clock has to advance on its own — progress callbacks can be
    // half a minute apart, and a frozen timer reads as a frozen app.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final task = widget.task;
    final remaining = task.estimatedRemaining;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    value: task.cancelling ? null : task.fraction,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    task.cancelling ? 'Stopping ${task.title}…' : task.title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.onCancel != null && task.cancellable)
                  TextButton(
                    onPressed: task.cancelling ? null : widget.onCancel,
                    child: Text(task.cancelling ? 'Stopping…' : 'Stop'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.cancelling ? null : task.fraction,
                minHeight: 6,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 8),
            _buildTimingRow(theme, task, remaining),
            if (!widget.compact && task.stages.length > 1) ...[
              const SizedBox(height: 14),
              ...List.generate(
                task.stages.length,
                (i) => _buildStageRow(theme, task.stages[i], i),
              ),
            ] else if (widget.compact) ...[
              const SizedBox(height: 6),
              Text(
                _activeDetail(task),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTimingRow(
      ThemeData theme, ErfTask task, Duration? remaining) {
    final scheme = theme.colorScheme;
    final step = task.stepNumber;

    final left = <String>[
      if (step != null) 'Step $step of ${task.stages.length}',
      if (task.fraction != null)
        '${(task.fraction! * 100).round()}%',
    ].join(' · ');

    final right = <String>[
      ErfTask.formatDuration(task.elapsed),
      if (remaining != null) '~${ErfTask.formatDuration(remaining)} left',
    ].join(' · ');

    return Row(
      children: [
        Expanded(
          child: Text(
            left,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          right,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _buildStageRow(ThemeData theme, ErfStage stage, int index) {
    final scheme = theme.colorScheme;

    late final Widget leading;
    late final Color textColor;
    switch (stage.status) {
      case ErfStageStatus.done:
        leading = Icon(Icons.check_circle, size: 18, color: scheme.primary);
        textColor = scheme.onSurfaceVariant;
      case ErfStageStatus.active:
        leading = SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: scheme.primary),
        );
        textColor = scheme.onSurface;
      case ErfStageStatus.failed:
        leading = Icon(Icons.error, size: 18, color: scheme.error);
        textColor = scheme.error;
      case ErfStageStatus.skipped:
        leading =
            Icon(Icons.remove_circle_outline, size: 18, color: scheme.outline);
        textColor = scheme.outline;
      case ErfStageStatus.pending:
        leading =
            Icon(Icons.circle_outlined, size: 18, color: scheme.outlineVariant);
        textColor = scheme.outline;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stage.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: textColor,
                    fontWeight: stage.status == ErfStageStatus.active
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
                if (stage.detail != null && stage.detail!.isNotEmpty)
                  Text(
                    stage.detail!,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _activeDetail(ErfTask task) {
    final index = task.activeStageIndex;
    if (index < 0) return '';
    final stage = task.stages[index];
    return stage.detail?.isNotEmpty == true
        ? '${stage.label} — ${stage.detail}'
        : stage.label;
  }
}
