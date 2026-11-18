// widgets/sync_status_banner.dart
//
// The strip at the top of the app that tells staff, in plain words, when
// what they see may be out of date or their changes haven't saved yet. Fed
// by SyncStatus. It sits ABOVE the app (a Column), never over it, so it
// can't cover a Google Map or steal its gestures.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../services/storage_health.dart';
import '../services/sync_status.dart';
import '../utils/web_reload.dart'
    if (dart.library.io) '../utils/web_reload_stub.dart';

class SyncStatusBanner extends StatelessWidget {
  final Widget child;

  /// The app-wide [SyncStatus.instance] unless a test passes its own.
  final SyncStatus? status;

  const SyncStatusBanner({super.key, required this.child, this.status});

  @override
  Widget build(BuildContext context) {
    final status = this.status ?? SyncStatus.instance;
    return ListenableBuilder(
      listenable: status,
      // Passed through untouched: the widget structure around [child] never
      // changes, so showing the banner can't rebuild the Navigator.
      child: child,
      builder: (context, child) {
        final message = _messageFor(status);
        final mq = MediaQuery.of(context);
        return Column(
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: message == null
                  ? const SizedBox(width: double.infinity)
                  : _Bar(message: message, topInset: mq.padding.top),
            ),
            Expanded(
              child: MediaQuery(
                // The bar already covers the status-bar inset.
                data: message == null ? mq : mq.removePadding(removeTop: true),
                child: child!,
              ),
            ),
          ],
        );
      },
    );
  }

  static _Message? _messageFor(SyncStatus s) {
    final pending = s.pendingWriteCount;
    final changes = pending == 1 ? '1 change' : '$pending changes';
    final waiting = pending > 0
        ? ' $changes not saved yet — keep this page open and '
            "${pending == 1 ? 'it' : 'they'} will save when the connection "
            'is back.'
        : '';

    switch (s.problem) {
      case SyncProblem.storageFull:
        return _Message(
          kind: _Kind.error,
          icon: Icons.sd_card_alert_outlined,
          text: s.storageNeedsReload
              ? "Your changes are NOT saving: this browser's storage for CLM "
                  'Schedule ran out of space. Press Fix now — it clears the '
                  'space and reloads. Nothing already saved is lost.'
              : "This browser's storage for CLM Schedule is full, so changes "
                  "can't save. Press Fix now — it clears the space and "
                  'reloads. Nothing already saved is lost.',
          actions: [_Action('Fix now', StorageHealth.instance.fixNow)],
        );
      case SyncProblem.storageLow:
        if (s.storageCondition == StorageCondition.lowDisk) {
          final mb = s.diskFreeMb;
          return _Message(
            kind: _Kind.warning,
            icon: Icons.storage,
            text: 'This computer is almost out of disk space'
                '${mb == null ? '' : ' ($mb MB left for this site)'}. '
                'Changes may stop saving — delete some files or empty the '
                'Recycle Bin.',
          );
        }
        return _Message(
          kind: _Kind.warning,
          icon: Icons.storage,
          text: "This browser's storage for CLM Schedule is "
              '${s.storagePercentFull}% full. When it is full, changes stop '
              'saving. Press Fix now to clear it (the page reloads).',
          actions: [_Action('Fix now', StorageHealth.instance.fixNow)],
        );
      case SyncProblem.offline:
        return _Message(
          kind: _Kind.error,
          icon: Icons.wifi_off,
          text: "You're offline. You're seeing the last copy saved on this "
              'device.$waiting',
        );
      case SyncProblem.liveUpdatesStopped:
        final feeds = s.stoppedFeeds;
        final what = feeds.isEmpty
            ? 'this page'
            : feeds.length == 1
                ? feeds.first
                : '${feeds.sublist(0, feeds.length - 1).join(', ')} and '
                    '${feeds.last}';
        return _Message(
          kind: _Kind.error,
          icon: Icons.sync_problem,
          busy: true,
          title: s.escalated
              ? 'Live updates for $what are still stopped'
              : 'Live updates stopped for $what',
          text: "Changes other people make won't appear here, so what you "
              'see may be out of date${_lastUpToDate(s)}. Don\'t mark '
              'payments or rely on the latest figures until this clears.'
              '${s.escalated ? ' If it doesn\'t clear, press Reload.' : ''}'
              '$waiting',
          status: () {
            final next = s.nextReconnectAt;
            final attempt = s.reconnectAttempts;
            final tries = attempt > 1 ? ' (attempt $attempt)' : '';
            if (next == null) return 'Reconnecting now…$tries';
            return 'Reconnecting automatically in ${_countdown(next)}$tries.';
          },
          actions: [
            _Action('Try now', s.retryFeedsNow),
            if (kIsWeb) const _Action('Reload', reloadPage),
          ],
        );
      case SyncProblem.slowConnection:
        final stillLoading = s.neverReachedServer;
        return _Message(
          // Yellow while it may be a passing slow patch; red once it has
          // lasted long enough that it clearly isn't.
          kind: s.escalated ? _Kind.error : _Kind.warning,
          icon: stillLoading ? Icons.network_check : Icons.cloud_off_outlined,
          busy: true,
          title: s.escalated
              ? 'Still not connected to the server'
              : stillLoading
                  ? 'Slow connection — still loading the latest data'
                  : 'Not connected to the server',
          text: 'What you see may be out of date${_lastUpToDate(s)}. '
              "Don't mark payments or rely on the latest figures until this "
              'clears.'
              '${s.escalated ? ' Check your Wi-Fi or internet, or press Reload.' : ''}'
              '$waiting',
          status: () {
            if (s.checkingServer) return 'Checking the connection now…';
            final failures = s.serverCheckFailures;
            final next = s.nextServerCheckAt;
            if (failures == 0 || next == null) {
              return 'Waiting for the server to answer…';
            }
            return "The server didn't answer "
                '${failures == 1 ? 'the last check' : '$failures checks in a row'}. '
                'Checking again in ${_countdown(next)}.';
          },
          actions: [
            _Action('Check now', () => unawaited(s.checkNowFromUser())),
            if (kIsWeb && s.escalated) const _Action('Reload', reloadPage),
          ],
        );
      case SyncProblem.savingSlowly:
        return _Message(
          kind: _Kind.warning,
          icon: Icons.cloud_upload_outlined,
          busy: true,
          text: 'Slow connection — $changes not saved yet. Keep this page '
              'open; ${pending == 1 ? 'it' : 'they'} will save as soon as '
              'the connection allows.',
        );
      case SyncProblem.none:
        if (!s.showRecovered) return null;
        return const _Message(
          kind: _Kind.ok,
          icon: Icons.cloud_done_outlined,
          text: 'Back online — everything is up to date.',
        );
    }
  }
}

/// " — last up to date at 14:32 (3 min ago)", or "" if never live.
String _lastUpToDate(SyncStatus s) {
  final at = s.lastLiveAt;
  if (at == null) return '';
  final mins = DateTime.now().difference(at).inMinutes;
  final ago = mins < 1
      ? 'just now'
      : mins < 60
          ? '$mins min ago'
          : '${mins ~/ 60} h ${mins % 60} min ago';
  return ' — last up to date at ${DateFormat('HH:mm').format(at)} ($ago)';
}

/// "12 s" / "1 min 5 s" until [at]; "a moment" once it is due.
String _countdown(DateTime at) {
  final secs = at.difference(DateTime.now()).inSeconds;
  if (secs <= 0) return 'a moment';
  if (secs < 60) return '$secs s';
  return '${secs ~/ 60} min ${secs % 60} s';
}

enum _Kind { ok, warning, error }

class _Action {
  final String label;
  final VoidCallback onPressed;
  const _Action(this.label, this.onPressed);
}

class _Message {
  final _Kind kind;
  final IconData icon;

  /// Bold first line, when the message needs one.
  final String? title;
  final String text;

  /// A live line under the text (countdowns), rebuilt every second.
  final String Function()? status;
  final bool busy;
  final List<_Action> actions;

  const _Message({
    required this.kind,
    required this.icon,
    required this.text,
    this.title,
    this.status,
    this.busy = false,
    this.actions = const [],
  });
}

/// Rebuilds [build] once a second while shown — the countdowns.
class _Ticking extends StatefulWidget {
  final String Function() build;
  final TextStyle style;
  const _Ticking({required this.build, required this.style});

  @override
  State<_Ticking> createState() => _TickingState();
}

class _TickingState extends State<_Ticking> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Text(widget.build(), style: widget.style);
}

class _Bar extends StatelessWidget {
  final _Message message;
  final double topInset;

  const _Bar({required this.message, required this.topInset});

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (message.kind) {
      _Kind.ok => (Colors.green.shade700, Colors.white),
      _Kind.warning => (Colors.amber.shade600, Colors.black87),
      _Kind.error => (Colors.red.shade700, Colors.white),
    };
    return Material(
      color: background,
      child: Semantics(
        liveRegion: true,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, topInset + 6, 8, 6),
          child: Row(
            children: [
              Icon(message.icon, size: 18, color: foreground),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.title != null)
                      Text(
                        message.title!,
                        style: TextStyle(
                            color: foreground,
                            fontSize: 14,
                            fontWeight: FontWeight.w700),
                      ),
                    Text(
                      message.text,
                      style: TextStyle(
                          color: foreground,
                          fontSize: 13,
                          fontWeight: FontWeight.w500),
                    ),
                    if (message.status != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: _Ticking(
                          build: message.status!,
                          style: TextStyle(
                              color: foreground.withValues(alpha: 0.85),
                              fontSize: 12,
                              fontStyle: FontStyle.italic),
                        ),
                      ),
                  ],
                ),
              ),
              if (message.busy) ...[
                const SizedBox(width: 10),
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: foreground),
                ),
              ],
              for (final action in message.actions)
                TextButton(
                  onPressed: action.onPressed,
                  style: TextButton.styleFrom(foregroundColor: foreground),
                  child: Text(
                    action.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              if (message.actions.isEmpty) const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
