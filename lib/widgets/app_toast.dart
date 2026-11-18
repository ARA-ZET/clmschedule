import 'package:flutter/material.dart';

import '../shareable_maps/widgets/map_overlay.dart';

/// App-wide notifications that replace the bottom [SnackBar].
///
/// Snackbars were disruptive in two ways:
///
///  * **Some never went away.** Since Flutter 3.29 a SnackBar with an `action`
///    defaults to `persist: true` and ignores its duration, so every "Undo" /
///    "View" / "OK" bar stayed up until someone closed it by hand.
///  * **They queued.** ScaffoldMessenger shows one at a time and each waits its
///    full duration, so a burst of messages drained for half a minute after the
///    work was done.
///
/// Toasts here are small cards stacked in the bottom-right corner (bottom
/// centre on phones). They show side by side instead of queueing, always time
/// out — even with an action — pause while hovered, and close on ✕ or a swipe.
///
/// Call sites keep building a normal [SnackBar] and call [AppToastMessenger.
/// showToast] instead of `showSnackBar`; content, colour, action and duration
/// are all carried over. Without an [AppToastHost] in the tree (tests, the
/// public map viewer) it falls back to an ordinary snackbar.
class AppToastHost extends StatefulWidget {
  final Widget child;

  const AppToastHost({super.key, required this.child});

  /// Wraps the navigator in every MaterialApp: `builder: AppToastHost.builder`.
  static Widget builder(BuildContext context, Widget? child) =>
      AppToastHost(child: child ?? const SizedBox.shrink());

  @override
  State<AppToastHost> createState() => _AppToastHostState();
}

/// Most toasts on screen at once; a new one pushes the oldest out.
const int _maxVisible = 3;

/// A toast is never shorter than this, so a 1 s message is still readable.
const Duration _minDuration = Duration(seconds: 2);

/// A toast is never longer than this. Long-running work shows its own spinner;
/// a toast is not a progress indicator.
const Duration _maxDuration = Duration(seconds: 10);

/// Toasts with a button stay a little longer so there is time to reach it.
const Duration _minActionDuration = Duration(seconds: 6);

/// Layouts narrower than this centre the toasts along the bottom edge.
const double _wideBreakpoint = 600;

_AppToastHostState? _activeHost;

class _ToastData {
  final int id;
  final SnackBar snackBar;
  final String? text;
  bool closing = false;

  _ToastData(this.id, this.snackBar, this.text);

  Duration get lifetime {
    var d = snackBar.duration;
    if (d < _minDuration) d = _minDuration;
    if (d > _maxDuration) d = _maxDuration;
    if (snackBar.action != null && d < _minActionDuration) {
      d = _minActionDuration;
    }
    return d;
  }
}

class _AppToastHostState extends State<AppToastHost> {
  final List<_ToastData> _toasts = [];
  int _nextId = 0;

  @override
  void initState() {
    super.initState();
    _activeHost = this;
  }

  @override
  void dispose() {
    if (identical(_activeHost, this)) _activeHost = null;
    super.dispose();
  }

  void show(SnackBar snackBar) {
    final text = _plainText(snackBar.content);
    setState(() {
      // The same message fired again (a repeated save, a double click)
      // replaces the visible copy instead of stacking duplicates.
      if (text != null) {
        for (final t in _toasts) {
          if (!t.closing && t.text == text) t.closing = true;
        }
      }
      _toasts.add(_ToastData(_nextId++, snackBar, text));
      final open = _toasts.where((t) => !t.closing).toList();
      for (var i = 0; i < open.length - _maxVisible; i++) {
        open[i].closing = true;
      }
    });
  }

  /// Closes the newest toast — what `hideCurrentSnackBar` did for the one
  /// visible snackbar, typically just before showing its replacement.
  void hideCurrent() {
    final open = _toasts.where((t) => !t.closing);
    if (open.isEmpty) return;
    setState(() => open.last.closing = true);
  }

  void _close(_ToastData toast) {
    if (toast.closing) return;
    setState(() => toast.closing = true);
  }

  void _remove(_ToastData toast) {
    if (!mounted) return;
    setState(() => _toasts.remove(toast));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final wide = media.size.width >= _wideBreakpoint;
    final bottom = 16 + media.viewInsets.bottom + media.viewPadding.bottom;

    return Stack(
      children: [
        widget.child,
        if (_toasts.isNotEmpty)
          Positioned(
            right: 16 + media.viewPadding.right,
            left: wide ? null : 16 + media.viewPadding.left,
            bottom: bottom,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 380 : 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final t in _toasts)
                    _ToastCard(
                      key: ValueKey(t.id),
                      data: t,
                      onClose: () => _close(t),
                      onGone: () => _remove(t),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

enum _ToastKind { warning, success, neutral }

/// Every warning/error toast is this red and every success toast this green,
/// whatever shade the call site picked, so the two read at a glance.
final Color _warningColor = Colors.red.shade700;
final Color _successColor = Colors.green.shade700;

/// Error-sounding messages that call sites left uncoloured.
final RegExp _warningText = RegExp(
  r"^(error|failed|failure|could ?not|couldn't|cannot|can't|unable)\b|\bfailed\b|\berror:",
  caseSensitive: false,
);

/// Call sites signal intent through `backgroundColor` — red, orange and the
/// theme's error colours for problems, green for success. Anything else
/// (blue info, grey, none) stays neutral.
_ToastKind _kindOf(SnackBar snackBar, String? text, ColorScheme scheme) {
  final bg = snackBar.backgroundColor;
  if (bg != null) {
    if (bg == scheme.error || bg == scheme.errorContainer) {
      return _ToastKind.warning;
    }
    final hsv = HSVColor.fromColor(bg);
    if (hsv.saturation > 0.3) {
      // Reds through amber (orange is how call sites mark partial failures).
      if (hsv.hue <= 50 || hsv.hue >= 330) return _ToastKind.warning;
      if (hsv.hue >= 75 && hsv.hue <= 165) return _ToastKind.success;
    }
    return _ToastKind.neutral;
  }
  if (text != null && _warningText.hasMatch(text.trim())) {
    return _ToastKind.warning;
  }
  return _ToastKind.neutral;
}

/// Content that already starts with its own icon gets no badge, so it doesn't
/// show two.
bool _leadsWithIcon(Widget content) {
  if (content is! Row || content.children.isEmpty) return false;
  var first = content.children.first;
  if (first is Padding && first.child != null) first = first.child!;
  return first is Icon || first is SizedBox && first.child is Icon;
}

/// The round white ✓ / ! at the start of a success or warning toast.
class _Badge extends StatelessWidget {
  final _ToastKind kind;

  const _Badge({required this.kind});

  @override
  Widget build(BuildContext context) {
    final warning = kind == _ToastKind.warning;
    return Container(
      width: 22,
      height: 22,
      decoration:
          const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
      child: Icon(
        warning ? Icons.priority_high_rounded : Icons.check_rounded,
        size: 15,
        color: warning ? _warningColor : _successColor,
      ),
    );
  }
}

/// The text of a plain `Text('...')` content, used to drop duplicates.
String? _plainText(Widget content) {
  if (content is Text) return content.data ?? content.textSpan?.toPlainText();
  return null;
}

class _ToastCard extends StatefulWidget {
  final _ToastData data;
  final VoidCallback onClose;
  final VoidCallback onGone;

  const _ToastCard({
    super.key,
    required this.data,
    required this.onClose,
    required this.onGone,
  });

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> with TickerProviderStateMixin {
  /// Slide/fade/size in and out.
  late final AnimationController _presence = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
  );

  /// Time left on screen; also drives the thin countdown line.
  late final AnimationController _life = AnimationController(
    vsync: this,
    duration: widget.data.lifetime,
  );

  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _life.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onClose();
    });
    // Superseded in the same frame it was shown (a duplicate, or a burst past
    // the visible limit): never animate in, just leave.
    if (widget.data.closing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onGone();
      });
      return;
    }
    _presence.forward().whenComplete(() {
      if (mounted && !_hovered && !widget.data.closing) _life.forward();
    });
  }

  @override
  void didUpdateWidget(_ToastCard old) {
    super.didUpdateWidget(old);
    if (widget.data.closing &&
        _presence.status != AnimationStatus.reverse &&
        _presence.status != AnimationStatus.dismissed) {
      _life.stop();
      _presence.reverse().whenComplete(() {
        if (mounted) widget.onGone();
      });
    }
  }

  @override
  void dispose() {
    _presence.dispose();
    _life.dispose();
    super.dispose();
  }

  void _setHovered(bool hovered) {
    _hovered = hovered;
    if (widget.data.closing || !_presence.isCompleted) return;
    hovered ? _life.stop() : _life.forward();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final snackBar = widget.data.snackBar;
    final kind = _kindOf(snackBar, widget.data.text, scheme);
    final bg = switch (kind) {
      _ToastKind.warning => _warningColor,
      _ToastKind.success => _successColor,
      _ToastKind.neutral => snackBar.backgroundColor ?? scheme.inverseSurface,
    };
    final fg = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    final action = snackBar.action;
    final badge = kind == _ToastKind.neutral || _leadsWithIcon(snackBar.content)
        ? null
        : _Badge(kind: kind);

    final curve = CurvedAnimation(
      parent: _presence,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return SizeTransition(
      sizeFactor: curve,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.3), end: Offset.zero)
              .animate(curve),
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: MapOverlay(
              child: MouseRegion(
                onEnter: (_) => _setHovered(true),
                onExit: (_) => _setHovered(false),
                child: Dismissible(
                  key: ValueKey('dismiss-${widget.data.id}'),
                  direction: DismissDirection.horizontal,
                  onDismissed: (_) {
                    widget.data.closing = true;
                    widget.onGone();
                  },
                  child: Semantics(
                    container: true,
                    liveRegion: true,
                    child: Material(
                      color: bg,
                      elevation: 6,
                      borderRadius: BorderRadius.circular(10),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                            child: Row(
                              children: [
                                if (badge != null) ...[
                                  badge,
                                  const SizedBox(width: 10),
                                ],
                                Expanded(
                                  child: Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 6),
                                    child: IconTheme.merge(
                                      data: IconThemeData(color: fg, size: 18),
                                      child: DefaultTextStyle.merge(
                                        style: TextStyle(
                                            color: fg, fontSize: 13.5),
                                        child: snackBar.content,
                                      ),
                                    ),
                                  ),
                                ),
                                if (action != null)
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      foregroundColor:
                                          kind != _ToastKind.neutral
                                              ? Colors.white
                                              : action.textColor ??
                                                  (fg == Colors.white
                                                      ? scheme.inversePrimary
                                                      : scheme.primary),
                                      textStyle: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    onPressed: () {
                                      widget.onClose();
                                      action.onPressed();
                                    },
                                    child: Text(action.label),
                                  ),
                                IconButton(
                                  icon: const Icon(Icons.close, size: 16),
                                  color: fg.withValues(alpha: 0.7),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 32, minHeight: 32),
                                  onPressed: widget.onClose,
                                ),
                              ],
                            ),
                          ),
                          AnimatedBuilder(
                            animation: _life,
                            builder: (_, __) => LinearProgressIndicator(
                              value: 1 - _life.value,
                              minHeight: 2,
                              backgroundColor: Colors.transparent,
                              color: fg.withValues(alpha: 0.35),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Drop-in replacements for `showSnackBar` / `hideCurrentSnackBar`.
extension AppToastMessenger on ScaffoldMessengerState {
  void showToast(SnackBar snackBar) {
    final host = _activeHost;
    if (host != null && host.mounted) {
      host.show(snackBar);
    } else {
      showSnackBar(snackBar);
    }
  }

  void hideCurrentToast() {
    final host = _activeHost;
    if (host != null && host.mounted) {
      host.hideCurrent();
    } else {
      hideCurrentSnackBar();
    }
  }
}
