// utils/save_timeline.dart
//
// A step-by-step stopwatch for a multi-step save, printed to the browser
// console (F12) as one table once everything has settled:
//
//   ⏱ Add job "Timbuild" — you waited 0.4 s · everything saved 3.1 s
//      start    took  step
//      0.00 s  0.12 s  duplicate-name check
//      0.12 s  12.3 s  allocation preview                         (you)
//     12.42 s  0.01 s  dialog closed
//     12.42 s  2.70 s  save schedule (8 jobs, 1 transaction)  background
//
// Built after adding a job was measured at up to ~4 minutes: each step is
// timed on the PC that runs it, so a slow one can be named, not guessed at.
// Nothing is stored — the user asked for console output only. debugPrint
// prints in release web builds too.
import 'dart:async';

import 'package:flutter/foundation.dart';

class SaveTimelineEntry {
  SaveTimelineEntry(this.name, this.start,
      {this.background = false, this.byUser = false});

  final String name;
  final Duration start;

  /// Ran without the user waiting for it (after the dialog closed, or
  /// alongside another step).
  final bool background;

  /// Time the user spent in a dialog — not counted as waiting.
  final bool byUser;

  Duration? end;
  String? error;

  bool get isDone => end != null;
  Duration get took => (end ?? start) - start;
}

class SaveTimeline {
  SaveTimeline(
    this.label, {
    Duration Function()? elapsed,
    void Function(String report)? printer,
    this.giveUpAfter = const Duration(minutes: 5),
  })  : _elapsed = elapsed ?? _stopwatch(),
        _printer = printer ?? _defaultPrinter;

  final String label;
  final Duration giveUpAfter;
  final Duration Function() _elapsed;
  final void Function(String) _printer;

  final List<SaveTimelineEntry> entries = [];
  Duration? _closedAt;
  bool _finished = false;
  bool _printed = false;
  Timer? _giveUp;
  int _open = 0;

  /// The last report printed, for tests and for pasting into a bug report.
  static String? lastReport;

  static Duration Function() _stopwatch() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  static void _defaultPrinter(String report) {
    for (final line in report.split('\n')) {
      debugPrint(line);
    }
  }

  Duration get now => _elapsed();

  /// Times [body], which the user waits for.
  Future<T> step<T>(String name, Future<T> Function() body) =>
      _run(SaveTimelineEntry(name, now), body);

  /// Times [body], a dialog the user is answering — not counted as waiting.
  Future<T> userStep<T>(String name, Future<T> Function() body) =>
      _run(SaveTimelineEntry(name, now, byUser: true), body);

  /// Times [future], which runs in the background or alongside other steps.
  /// Returns it unchanged, errors included.
  Future<T> track<T>(String name, Future<T> future) =>
      _run(SaveTimelineEntry(name, now, background: true), () => future);

  /// [track] for a future nobody awaits: its failure is recorded in the
  /// table, never thrown.
  void background(String name, Future<Object?> future) {
    unawaited(track(name, future).then((_) {}, onError: (_) {}));
  }

  /// An instant marker, such as "dialog closed".
  void mark(String name) {
    final e = SaveTimelineEntry(name, now)..end = now;
    entries.add(e);
  }

  /// The user is no longer waiting: the dialog closed (or the last step it
  /// shows has finished). The table prints once background steps settle.
  void markClosed([String name = 'dialog closed']) {
    if (_closedAt != null) return;
    _closedAt = now;
    mark(name);
    finish();
  }

  /// Nothing more will be added; print once every step has settled (or after
  /// [giveUpAfter], marking the ones still running).
  void finish() {
    if (_finished) return;
    _finished = true;
    _closedAt ??= now;
    _maybePrint();
    if (!_printed) {
      _giveUp = Timer(giveUpAfter, () => _print(stillRunning: true));
    }
  }

  Future<T> _run<T>(
      SaveTimelineEntry entry, Future<T> Function() body) async {
    entries.add(entry);
    _open++;
    try {
      return await body();
    } catch (e) {
      entry.error = _short(e);
      rethrow;
    } finally {
      entry.end = now;
      _open--;
      _maybePrint();
    }
  }

  void _maybePrint() {
    if (_finished && _open == 0) _print();
  }

  /// Time the user sat waiting: until the dialog closed, minus the time
  /// they spent answering dialogs of their own.
  Duration get userWaited {
    final closed = _closedAt ?? now;
    var waited = closed;
    for (final e in entries) {
      if (!e.byUser) continue;
      final end = e.end ?? closed;
      final until = end < closed ? end : closed;
      if (until > e.start) waited -= until - e.start;
    }
    return waited.isNegative ? Duration.zero : waited;
  }

  /// When the last step finished.
  Duration get allDone {
    var last = _closedAt ?? Duration.zero;
    for (final e in entries) {
      final end = e.end;
      if (end != null && end > last) last = end;
    }
    return last;
  }

  String report({bool stillRunning = false}) {
    final buf = StringBuffer()
      ..write('⏱ $label — you waited ${fmt(userWaited)}')
      ..write(stillRunning
          ? ' · still saving after ${fmt(now)}'
          : ' · everything saved ${fmt(allDone)}');
    final failed = entries.where((e) => e.error != null).length;
    if (failed > 0) buf.write(' · $failed failed');
    buf.write('\n   start     took  step');
    for (final e in entries) {
      final took = e.isDone ? fmt(e.took) : 'running';
      final tags = [
        if (e.byUser) '(you)',
        if (e.background) 'background',
        if (e.error != null) 'FAILED: ${e.error}',
      ].join(' ');
      buf.write('\n  ${fmt(e.start).padLeft(7)} ${took.padLeft(8)}  '
          '${e.name}${tags.isEmpty ? '' : '  $tags'}');
    }
    return buf.toString();
  }

  void _print({bool stillRunning = false}) {
    if (_printed) return;
    _printed = true;
    _giveUp?.cancel();
    final text = report(stillRunning: stillRunning);
    lastReport = text;
    _printer(text);
  }

  static String fmt(Duration d) {
    final s = d.inMicroseconds / 1e6;
    return s >= 10 ? '${s.toStringAsFixed(1)} s' : '${s.toStringAsFixed(2)} s';
  }

  static String _short(Object e) {
    final text = e.toString().replaceAll('\n', ' ');
    return text.length > 120 ? '${text.substring(0, 117)}…' : text;
  }
}
