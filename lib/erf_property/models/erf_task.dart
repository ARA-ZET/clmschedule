/// State of one step in a long-running ERF operation.
enum ErfStageStatus { pending, active, done, failed, skipped }

/// One named step of a multi-stage operation, e.g. "Fetch parcels".
class ErfStage {
  final String label;
  final ErfStageStatus status;

  /// Live sub-text, e.g. "3 000 of 9 954 parcels".
  final String? detail;

  const ErfStage({
    required this.label,
    this.status = ErfStageStatus.pending,
    this.detail,
  });

  ErfStage copyWith({ErfStageStatus? status, String? detail}) => ErfStage(
        label: label,
        status: status ?? this.status,
        detail: detail ?? this.detail,
      );
}

/// A long-running operation the user is waiting on.
///
/// These operations are genuinely slow — the cadastral register answers in
/// 30-60 seconds per page, so a suburb download runs for minutes. This model
/// exists so the UI can always answer "what is happening, how far in, and how
/// much longer", rather than showing an unattributed spinner.
class ErfTask {
  final String title;
  final List<ErfStage> stages;

  /// Units completed and expected, when countable. [total] is null while the
  /// size is still unknown, which renders as an indeterminate bar.
  final int done;
  final int? total;

  final DateTime startedAt;

  /// Whether the user may stop this task partway.
  final bool cancellable;

  /// Set once the user has asked to stop, so the UI can show "stopping…"
  /// while the current page finishes.
  final bool cancelling;

  ErfTask({
    required this.title,
    required this.stages,
    this.done = 0,
    this.total,
    DateTime? startedAt,
    this.cancellable = false,
    this.cancelling = false,
  }) : startedAt = startedAt ?? DateTime.now();

  ErfTask copyWith({
    String? title,
    List<ErfStage>? stages,
    int? done,
    int? total,
    bool? cancelling,
    bool clearTotal = false,
  }) {
    return ErfTask(
      title: title ?? this.title,
      stages: stages ?? this.stages,
      done: done ?? this.done,
      total: clearTotal ? null : (total ?? this.total),
      startedAt: startedAt,
      cancellable: cancellable,
      cancelling: cancelling ?? this.cancelling,
    );
  }

  /// Mark [index] active, and everything before it done.
  ///
  /// Passing `stages.length` completes the whole task. A stage that already
  /// failed or was skipped keeps that status — only pending and active
  /// stages are promoted, so a spinner never outlives its step and a failure
  /// is never silently overwritten by progress moving on.
  ErfTask activateStage(int index, {String? detail}) {
    return copyWith(stages: [
      for (var i = 0; i < stages.length; i++)
        if (i < index)
          (stages[i].status == ErfStageStatus.pending ||
                  stages[i].status == ErfStageStatus.active)
              ? stages[i].copyWith(status: ErfStageStatus.done)
              : stages[i]
        else if (i == index)
          stages[i].copyWith(status: ErfStageStatus.active, detail: detail)
        else
          stages[i],
    ]);
  }

  /// Update the detail line of the active stage.
  ErfTask withDetail(String detail) {
    final index = activeStageIndex;
    if (index < 0) return this;
    return copyWith(stages: [
      for (var i = 0; i < stages.length; i++)
        if (i == index) stages[i].copyWith(detail: detail) else stages[i],
    ]);
  }

  /// Mark the active stage failed, e.g. when storing fails but the fetch
  /// succeeded — the user should see which step broke.
  ErfTask failActiveStage(String detail) {
    final index = activeStageIndex;
    if (index < 0) return this;
    return copyWith(stages: [
      for (var i = 0; i < stages.length; i++)
        if (i == index)
          stages[i].copyWith(status: ErfStageStatus.failed, detail: detail)
        else
          stages[i],
    ]);
  }

  int get activeStageIndex =>
      stages.indexWhere((s) => s.status == ErfStageStatus.active);

  /// 1-based step number for display, or null when nothing is active.
  int? get stepNumber {
    final index = activeStageIndex;
    return index < 0 ? null : index + 1;
  }

  /// Progress through the countable work, or null when the size is unknown.
  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return (done / t).clamp(0.0, 1.0);
  }

  Duration get elapsed => DateTime.now().difference(startedAt);

  /// Rough time remaining, extrapolated from the rate so far.
  ///
  /// Only offered once enough work has completed for the estimate to mean
  /// something — an ETA from two data points is worse than none.
  Duration? get estimatedRemaining {
    final f = fraction;
    if (f == null || f <= 0.05 || f >= 1) return null;
    final elapsedMs = elapsed.inMilliseconds;
    if (elapsedMs < 2000) return null;
    final totalMs = elapsedMs / f;
    return Duration(milliseconds: (totalMs - elapsedMs).round());
  }

  /// "1m 20s" / "45s"
  static String formatDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
  }
}
