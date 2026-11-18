// widgets/slow_action_hint.dart
//
// Feedback for saves that take longer than they should on a slow connection.
// Quick saves show nothing extra (no nagging); a save still running after a
// few seconds says so, and tells the user not to press again — impatient
// repeat clicks are what turned one invoice into twelve.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// How long a save may run before the hint appears.
const Duration kSlowActionAfter = Duration(seconds: 4);

/// When the hint escalates to "the connection is very slow".
const Duration kVerySlowActionAfter = Duration(seconds: 15);

/// A line of text shown under an action's buttons while [busy] has been true
/// for longer than [after]. Renders nothing otherwise.
class SlowActionHint extends StatefulWidget {
  final bool busy;

  /// What is being done, e.g. "Creating the invoice in Zoho".
  final String action;

  final Duration after;

  const SlowActionHint({
    super.key,
    required this.busy,
    this.action = 'Saving',
    this.after = kSlowActionAfter,
  });

  @override
  State<SlowActionHint> createState() => _SlowActionHintState();
}

class _SlowActionHintState extends State<SlowActionHint> {
  Timer? _timer;

  /// Seconds busy so far, counted by the timer (a background tab's slowed
  /// timers only ever under-count, which errs towards saying nothing).
  int _elapsed = 0;

  @override
  void initState() {
    super.initState();
    if (widget.busy) _start();
  }

  @override
  void didUpdateWidget(SlowActionHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy && !oldWidget.busy) _start();
    if (!widget.busy && oldWidget.busy) _stop();
  }

  void _start() {
    _elapsed = 0;
    _timer?.cancel();
    // Ticks once a second so the wording can escalate and the elapsed time
    // stays current.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _elapsed = 0;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.busy || _timer == null) return const SizedBox.shrink();
    final elapsed = Duration(seconds: _elapsed);
    if (elapsed < widget.after) return const SizedBox.shrink();

    final verySlow = elapsed >= kVerySlowActionAfter;
    final color = verySlow ? Colors.orange.shade800 : Colors.blueGrey.shade600;
    final text = verySlow
        ? '${widget.action} — the connection is very slow '
            '(${elapsed.inSeconds}s). It is still going: please wait and '
            "don't press again or close this window."
        : '${widget.action} — still working on a slow connection. '
            "Please wait, don't press again.";

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(verySlow ? Icons.wifi_tethering_error : Icons.hourglass_top,
              size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }
}

/// A compact chip for a screen's queue of background saves ([pending] =
/// writes not yet confirmed). Hidden while saves finish promptly; after
/// [after] it shows "Saving…", and on a very slow connection reassures the
/// user that their changes are queued, so they don't redo them.
class PendingSavesChip extends StatefulWidget {
  final ValueListenable<int> pending;
  final Duration after;

  const PendingSavesChip({
    super.key,
    required this.pending,
    this.after = const Duration(seconds: 3),
  });

  @override
  State<PendingSavesChip> createState() => _PendingSavesChipState();
}

class _PendingSavesChipState extends State<PendingSavesChip> {
  Timer? _timer;

  /// Seconds the queue has been non-empty, counted by the timer.
  int _elapsed = 0;

  @override
  void initState() {
    super.initState();
    widget.pending.addListener(_onPending);
    _onPending();
  }

  @override
  void didUpdateWidget(PendingSavesChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pending != widget.pending) {
      oldWidget.pending.removeListener(_onPending);
      widget.pending.addListener(_onPending);
      _onPending();
    }
  }

  void _onPending() {
    final busy = widget.pending.value > 0;
    if (busy && _timer == null) {
      _elapsed = 0;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed++);
      });
    } else if (!busy && _timer != null) {
      _timer?.cancel();
      _timer = null;
      _elapsed = 0;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.pending.removeListener(_onPending);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.pending.value;
    if (_timer == null || count == 0) return const SizedBox.shrink();
    final elapsed = Duration(seconds: _elapsed);
    if (elapsed < widget.after) return const SizedBox.shrink();

    final verySlow = elapsed >= kVerySlowActionAfter;
    final color = verySlow ? Colors.orange.shade800 : Colors.blueGrey.shade700;
    final label = count == 1 ? 'Saving 1 change…' : 'Saving $count changes…';

    return Tooltip(
      message: verySlow
          ? 'The connection is slow. Your changes are on screen and queued — '
              'they will save automatically as soon as the connection allows. '
              "No need to redo them. Don't close the tab until this goes away."
          : 'Your changes are being saved.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: verySlow ? Colors.orange.shade50 : Colors.blueGrey.shade50,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color:
                  verySlow ? Colors.orange.shade300 : Colors.blueGrey.shade200),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
            const SizedBox(width: 6),
            Text(
              verySlow ? 'Slow connection · $label' : label,
              style: TextStyle(
                  fontSize: 12, color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
