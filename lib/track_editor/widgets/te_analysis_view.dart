// track_editor/widgets/te_analysis_view.dart
//
// The Analysis pane for a distributor tab — the alternative to the map view.
//
// It answers the questions a client asks about a traffic-light flyer round:
//   * How many flyers went out, and when?
//   * Was the distributor actually working, or standing around?
//   * Where did the flyers actually go out — which intersections?
//   * Are there holes in the record (logger off, no signal)?
//
// Everything on this page is derived from two raw inputs on the tab: the
// continuous tracklog (`tab.tracks`) and one waypoint per flyer handed out
// (`tab.waypoints`). Nothing here mutates the tab.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/tab_item.dart';
import '../providers/te_tabs_provider.dart';
import '../providers/te_view_provider.dart';
import '../utils/te_track_analysis.dart';
import 'te_analysis_chart.dart';

class TEAnalysisView extends riverpod.ConsumerStatefulWidget {
  const TEAnalysisView({super.key});

  @override
  riverpod.ConsumerState<TEAnalysisView> createState() =>
      _TEAnalysisViewState();
}

class _TEAnalysisViewState extends riverpod.ConsumerState<TEAnalysisView> {
  TEAnalysisConfig _config = const TEAnalysisConfig();

  TETrackAnalysis? _cached;
  String? _cacheKey;

  /// The visible slice of the time axis, as fractions of the whole shift.
  /// Held as fractions rather than absolute times so it survives a threshold
  /// change without having to be re-clamped against new stop boundaries.
  double _v0 = 0;
  double _v1 = 1;

  /// Never let the window collapse to nothing.
  static const double _minWindow = 0.005;

  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Bring the chart back into view after a tap further down the page. The
  /// tap reframes the time axis, and the whole point of reframing it is to
  /// look at it — leaving the user parked over a table two thousand pixels
  /// below the thing they just changed is the wrong end of the page.
  void _scrollToChart() {
    if (!_scroll.hasClients || _scroll.offset <= 0) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  /// Recompute only when the underlying data or the thresholds actually
  /// change — a full shift is tens of thousands of trackpoints and this
  /// widget rebuilds on every tab notification.
  TETrackAnalysis _analysisFor(TETabItem tab) {
    final trkPts = tab.tracks.fold<int>(
        0, (a, t) => a + t.trksegs.fold<int>(0, (b, s) => b + s.trkpts.length));
    final key = '${identityHashCode(tab)}|$trkPts|${tab.waypoints.length}'
        '|${_config.stopRadiusM}|${_config.minStop.inSeconds}'
        '|${_config.breakThreshold.inSeconds}|${_config.gapThreshold.inSeconds}';
    if (_cacheKey == key && _cached != null) return _cached!;
    final a = TETrackAnalysis.from(
      tracks: tab.tracks,
      waypoints: tab.waypoints,
      config: _config,
    );
    // Different data (or a different tab) means the old window points at
    // times that no longer exist — go back to the whole shift.
    if (_cacheKey != null) {
      _v0 = 0;
      _v1 = 1;
    }
    _cacheKey = key;
    _cached = a;
    return a;
  }

  DateTime _at(TETrackAnalysis a, double f) => a.start
      .add(Duration(milliseconds: (f * a.elapsed.inMilliseconds).round()));

  void _setWindow(double v0, double v1) {
    var lo = v0.clamp(0.0, 1.0 - _minWindow);
    var hi = v1.clamp(_minWindow, 1.0);
    if (hi - lo < _minWindow) hi = (lo + _minWindow).clamp(0.0, 1.0);
    if (hi - lo < _minWindow) lo = hi - _minWindow;
    setState(() {
      _v0 = lo;
      _v1 = hi;
    });
  }

  /// Widen or narrow the window about its own centre.
  void _zoomBy(double factor) {
    final centre = (_v0 + _v1) / 2;
    final half = ((_v1 - _v0) * factor / 2).clamp(_minWindow / 2, 0.5);
    var lo = centre - half;
    var hi = centre + half;
    if (lo < 0) {
      hi -= lo;
      lo = 0;
    }
    if (hi > 1) {
      lo -= hi - 1;
      hi = 1;
    }
    _setWindow(lo, hi);
  }

  /// Slide the window without changing how much time it covers.
  void _panBy(TETrackAnalysis a, int deltaMs) {
    final total = a.elapsed.inMilliseconds;
    if (total <= 0) return;
    final width = _v1 - _v0;
    var lo = _v0 + deltaMs / total;
    if (lo < 0) lo = 0;
    if (lo + width > 1) lo = 1 - width;
    _setWindow(lo, lo + width);
  }

  /// Frame an absolute time range — used by the hour chips and by tapping a
  /// row of the hourly table.
  void _focus(TETrackAnalysis a, DateTime from, DateTime to) {
    final total = a.elapsed.inMilliseconds;
    if (total <= 0) return;
    _setWindow(
      from.difference(a.start).inMilliseconds / total,
      to.difference(a.start).inMilliseconds / total,
    );
    _scrollToChart();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = ref.watch(teTabsRiverpod);
    if (tabs.tabs.isEmpty) return const SizedBox.shrink();
    final tab = tabs.tabs[tabs.currentTab];
    final viewP = ref.watch(teViewRiverpod);
    // The pane lives inside an IndexedStack so the map keeps its camera and
    // selections while hidden. That means this widget is built even on the
    // map view — skip the (expensive) analysis until it is actually shown.
    // The State, and with it the cached result, survives the switch.
    if (viewP.view != TEPaneView.analysis) return const SizedBox.shrink();
    final a = _analysisFor(tab);

    return Container(
      decoration: BoxDecoration(
        color: TEChartColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TEChartColors.grid),
      ),
      clipBehavior: Clip.antiAlias,
      // The Container above paints an opaque background, which would hide any
      // ink splash drawn on the Material further up the tree — every tappable
      // row in here would look dead. This transparent Material gives the ink
      // something to paint on ABOVE that background.
      child: Material(
        type: MaterialType.transparency,
        child: a.isEmpty
            ? const _EmptyState()
            : ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  _Header(
                    tab: tab,
                    analysis: a,
                    overlay: viewP.overlaySeries,
                    onOverlayChanged: (v) =>
                        ref.read(teViewRiverpod).setOverlaySeries(v),
                    secondary: viewP.secondary,
                    onSecondaryChanged: (v) =>
                        ref.read(teViewRiverpod).setSecondary(v),
                    config: _config,
                    onConfigChanged: (c) => setState(() => _config = c),
                  ),
                  const SizedBox(height: 10),
                  _Legend(secondary: viewP.secondary),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: viewP.overlaySeries ? 300 : 400,
                    child: TEAnalysisChart(
                      analysis: a,
                      overlay: viewP.overlaySeries,
                      secondary: viewP.secondary,
                      viewStart: _at(a, _v0),
                      viewEnd: _at(a, _v1),
                      onPan: (ms) => _panBy(a, ms),
                    ),
                  ),
                  const SizedBox(height: 6),
                  _TimeZoom(
                    analysis: a,
                    v0: _v0,
                    v1: _v1,
                    onChanged: _setWindow,
                    onZoom: _zoomBy,
                    onFocus: (from, to) => _focus(a, from, to),
                  ),
                  const SizedBox(height: 20),
                  _SummaryTiles(analysis: a),
                  const SizedBox(height: 20),
                  _TimeSplit(analysis: a),
                  const SizedBox(height: 20),
                  _RateHistogram(
                    analysis: a,
                    windowFrom: _at(a, _v0),
                    windowTo: _at(a, _v1),
                    onFocus: (from, to) => _focus(a, from, to),
                  ),
                  const SizedBox(height: 20),
                  _HourlyTable(
                    analysis: a,
                    windowFrom: _at(a, _v0),
                    windowTo: _at(a, _v1),
                    onFocusHour: (h) => _focus(a, h.from, h.to),
                  ),
                ],
              ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insights, size: 40, color: TEChartColors.axis),
            SizedBox(height: 12),
            Text(
              'Nothing to analyse on this tab yet',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: TEChartColors.secondaryInk),
            ),
            SizedBox(height: 6),
            Text(
              'Load a distributor’s GPX — the tracklog gives speed and\n'
              'position, the waypoints give the handout presses.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: TEChartColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// HEADER
// ════════════════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final TETabItem tab;
  final TETrackAnalysis analysis;
  final bool overlay;
  final ValueChanged<bool> onOverlayChanged;
  final TESecondarySeries secondary;
  final ValueChanged<TESecondarySeries> onSecondaryChanged;
  final TEAnalysisConfig config;
  final ValueChanged<TEAnalysisConfig> onConfigChanged;

  const _Header({
    required this.tab,
    required this.analysis,
    required this.overlay,
    required this.onOverlayChanged,
    required this.secondary,
    required this.onSecondaryChanged,
    required this.config,
    required this.onConfigChanged,
  });

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tab.title,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: TEChartColors.primaryInk),
              ),
              const SizedBox(height: 2),
              Text(
                '${teFormatClock(a.start)} – ${teFormatClock(a.end)}   ·   '
                '${teFormatDuration(a.elapsed)} on the clock   ·   '
                '${a.totalHandouts} handouts',
                style: const TextStyle(
                    fontSize: 11.5, color: TEChartColors.secondaryInk),
              ),
              if (a.isMotionTriggered) ...[
                const SizedBox(height: 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sensors_off,
                        size: 13, color: TEChartColors.idle),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        'Motion-triggered logger: it writes a point about '
                        'every ${a.medianIntervalSeconds.round()}s while '
                        'moving and goes quiet when the distributor stops, '
                        'so the standing time below was read from the '
                        'silences rather than from the trackpoints.',
                        style: const TextStyle(
                            fontSize: 11, color: TEChartColors.idle),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        _SegToggle(
          leftLabel: 'Handouts',
          rightLabel: 'Distance',
          leftSelected: secondary == TESecondarySeries.handouts,
          onChanged: (isLeft) => onSecondaryChanged(
              isLeft ? TESecondarySeries.handouts : TESecondarySeries.distance),
          tooltip: 'What the second line tracks alongside speed: the running '
              'handout\ncount, or the cumulative distance walked.',
        ),
        const SizedBox(width: 6),
        _SegToggle(
          leftLabel: 'Overlay',
          rightLabel: 'Split',
          leftSelected: overlay,
          onChanged: (isLeft) => onOverlayChanged(isLeft),
          tooltip: 'Overlay puts speed and the second line in one plot with '
              'two\ny-axes. Split stacks them as two plots sharing the time '
              'axis,\nso neither scale distorts the other.',
        ),
        const SizedBox(width: 6),
        _ThresholdsButton(config: config, onChanged: onConfigChanged),
      ],
    );
  }
}

class _SegToggle extends StatelessWidget {
  final String leftLabel;
  final String rightLabel;
  final bool leftSelected;
  final ValueChanged<bool> onChanged;
  final String? tooltip;

  const _SegToggle({
    required this.leftLabel,
    required this.rightLabel,
    required this.leftSelected,
    required this.onChanged,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, bool selected, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: selected ? TEChartColors.speed : Colors.transparent,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : TEChartColors.secondaryInk,
              ),
            ),
          ),
        );

    final w = Container(
      decoration: BoxDecoration(
        border: Border.all(color: TEChartColors.axis),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg(leftLabel, leftSelected, () => onChanged(true)),
          Container(width: 1, height: 26, color: TEChartColors.grid),
          seg(rightLabel, !leftSelected, () => onChanged(false)),
        ],
      ),
    );
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

/// Lets the reviewer retune what counts as "stopped" and what counts as a
/// break. Different rounds behave differently — a highway off-ramp island is
/// bigger than a suburban robot — so these are not baked in.
class _ThresholdsButton extends StatelessWidget {
  final TEAnalysisConfig config;
  final ValueChanged<TEAnalysisConfig> onChanged;

  const _ThresholdsButton({required this.config, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void>(
      tooltip: 'Detection thresholds',
      icon: const Icon(Icons.tune, size: 18, color: TEChartColors.secondaryInk),
      itemBuilder: (_) {
        // Declared here, OUTSIDE the StatefulBuilder's rebuilding closure, so
        // it is captured once when the menu opens and survives every
        // `setLocal` rebuild that follows. It used to sit inside the
        // builder, which re-read `config` (this widget's prop, fixed at
        // menu-open time) on every rebuild — so the very first drag tick
        // discarded the drag and snapped every slider straight back to
        // wherever it started, before the user could ever see it move.
        var c = config;
        return [
          PopupMenuItem<void>(
            enabled: false,
            child: StatefulBuilder(
              builder: (context, setLocal) {
                return SizedBox(
                  width: 300,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Detection thresholds',
                          style: TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      _slider(
                        label: 'Stop radius',
                        value: c.stopRadiusM,
                        min: 10,
                        max: 120,
                        divisions: 22,
                        format: (v) => '${v.round()} m',
                        onChanged: (v) {
                          c = c.copyWith(stopRadiusM: v);
                          setLocal(() {});
                          onChanged(c);
                        },
                      ),
                      _slider(
                        label: 'Minimum stop',
                        value: c.minStop.inSeconds.toDouble(),
                        min: 30,
                        max: 900,
                        divisions: 29,
                        format: (v) => '${(v / 60).toStringAsFixed(1)} min',
                        onChanged: (v) {
                          c = c.copyWith(minStop: Duration(seconds: v.round()));
                          setLocal(() {});
                          onChanged(c);
                        },
                      ),
                      _slider(
                        label: 'Counts as a break',
                        value: c.breakThreshold.inMinutes.toDouble(),
                        min: 5,
                        max: 90,
                        divisions: 17,
                        format: (v) => '${v.round()} min',
                        onChanged: (v) {
                          c = c.copyWith(
                              breakThreshold: Duration(minutes: v.round()));
                          setLocal(() {});
                          onChanged(c);
                        },
                      ),
                      _slider(
                        label: 'Tracklog gap',
                        value: c.gapThreshold.inMinutes.toDouble(),
                        min: 1,
                        max: 30,
                        divisions: 29,
                        format: (v) => '${v.round()} min',
                        onChanged: (v) {
                          c = c.copyWith(
                              gapThreshold: Duration(minutes: v.round()));
                          setLocal(() {});
                          onChanged(c);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ];
      },
    );
  }

  static Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 11, color: TEChartColors.secondaryInk)),
            Text(format(value),
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: TEChartColors.primaryInk)),
          ],
        ),
        SliderTheme(
          data: const SliderThemeData(
            trackHeight: 2,
            overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            activeColor: TEChartColors.speed,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// LEGEND — identity is never colour alone; every swatch carries its label
// ════════════════════════════════════════════════════════════════════════════

class _Legend extends StatelessWidget {
  final TESecondarySeries secondary;
  const _Legend({required this.secondary});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [
        const _LegendItem(
            color: TEChartColors.speed, label: 'Speed', line: true),
        _LegendItem(
            color: TEChartColors.handouts,
            label: secondary == TESecondarySeries.handouts
                ? 'Handouts (cumulative)'
                : 'Distance walked (cumulative)',
            line: true),
        const _LegendItem(color: TEChartColors.handouts, label: 'Working'),
        const _LegendItem(color: TEChartColors.idle, label: 'Idle / waiting'),
        const _LegendItem(
            color: TEChartColors.idle, label: 'Break', hatched: true),
        const _LegendItem(
            color: TEChartColors.gap, label: 'No tracklog', hatched: true),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  final bool line;
  final bool hatched;

  const _LegendItem({
    required this.color,
    required this.label,
    this.line = false,
    this.hatched = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: Size(line ? 16 : 12, line ? 3 : 12),
          painter: _SwatchPainter(color: color, line: line, hatched: hatched),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(
                fontSize: 11, color: TEChartColors.secondaryInk)),
      ],
    );
  }
}

class _SwatchPainter extends CustomPainter {
  final Color color;
  final bool line;
  final bool hatched;
  const _SwatchPainter(
      {required this.color, required this.line, required this.hatched});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (line) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()..color = color,
      );
      return;
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(2)),
      Paint()..color = color.withValues(alpha: hatched ? 0.35 : 0.85),
    );
    if (hatched) {
      canvas.save();
      canvas.clipRect(rect);
      final p = Paint()
        ..color = color
        ..strokeWidth = 1;
      for (var x = -size.height; x < size.width; x += 4) {
        canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_SwatchPainter old) =>
      old.color != color || old.line != line || old.hatched != hatched;
}

// ════════════════════════════════════════════════════════════════════════════
// TIME ZOOM — narrow the chart's axis onto part of the shift
// ════════════════════════════════════════════════════════════════════════════

/// The range slider under the chart. Both thumbs together set the window, so
/// one control does zoom and position at once; the hour chips beside it jump
/// straight to a clock hour, which is how a round is usually discussed
/// ("what was he doing between ten and eleven?").
class _TimeZoom extends StatelessWidget {
  final TETrackAnalysis analysis;
  final double v0;
  final double v1;
  final void Function(double, double) onChanged;
  final void Function(double factor) onZoom;
  final void Function(DateTime from, DateTime to) onFocus;

  const _TimeZoom({
    required this.analysis,
    required this.v0,
    required this.v1,
    required this.onChanged,
    required this.onZoom,
    required this.onFocus,
  });

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    final from = a.start
        .add(Duration(milliseconds: (v0 * a.elapsed.inMilliseconds).round()));
    final to = a.start
        .add(Duration(milliseconds: (v1 * a.elapsed.inMilliseconds).round()));
    final zoomed = v0 > 0.0005 || v1 < 0.9995;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(width: 46), // line the slider up with the plot
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  activeTrackColor: TEChartColors.speed,
                  inactiveTrackColor: TEChartColors.grid,
                  thumbColor: TEChartColors.speed,
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                  rangeThumbShape:
                      const RoundRangeSliderThumbShape(enabledThumbRadius: 7),
                  rangeTrackShape: const RectangularRangeSliderTrackShape(),
                ),
                child: RangeSlider(
                  values: RangeValues(v0.clamp(0.0, 1.0), v1.clamp(0.0, 1.0)),
                  onChanged: (r) => onChanged(r.start, r.end),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _IconBtn(
              icon: Icons.zoom_in,
              tooltip: 'Zoom in',
              onTap: () => onZoom(0.5),
            ),
            _IconBtn(
              icon: Icons.zoom_out,
              tooltip: 'Zoom out',
              onTap: () => onZoom(2.0),
            ),
            _IconBtn(
              icon: Icons.fit_screen_outlined,
              tooltip: 'Whole shift',
              enabled: zoomed,
              onTap: () => onChanged(0, 1),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 46),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                zoomed
                    ? 'Showing ${teFormatClockSeconds(from)} – '
                        '${teFormatClockSeconds(to)}  '
                        '(${teFormatDuration(to.difference(from))} of '
                        '${teFormatDuration(a.elapsed)}) · drag the chart to pan'
                    : 'Showing the whole shift · drag the slider to zoom in',
                style:
                    const TextStyle(fontSize: 11, color: TEChartColors.muted),
              ),
              const SizedBox(width: 4),
              for (final h in a.hourly)
                _HourChip(
                  label: teFormatClock(h.hourStart).substring(0, 2),
                  selected: teFramesExactly(from, to, h.from, h.to),
                  onTap: () => onFocus(h.from, h.to),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HourChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _HourChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Zoom to the $label:00 hour',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: selected ? TEChartColors.speed : Colors.transparent,
            border: Border.all(
                color: selected ? TEChartColors.speed : TEChartColors.axis),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : TEChartColors.secondaryInk,
            ),
          ),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon,
              size: 17,
              color: enabled ? TEChartColors.secondaryInk : TEChartColors.axis),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// HOURLY TABLE
// ════════════════════════════════════════════════════════════════════════════

/// One row per clock hour: how many flyers went out, and what the hour was
/// actually spent doing. Tapping a row zooms the chart onto that hour.
class _HourlyTable extends StatelessWidget {
  final TETrackAnalysis analysis;
  final DateTime windowFrom;
  final DateTime windowTo;
  final void Function(TEHourStat) onFocusHour;

  const _HourlyTable({
    required this.analysis,
    required this.windowFrom,
    required this.windowTo,
    required this.onFocusHour,
  });

  static const double hourW = 148;
  static const double countW = 74;
  static const double shareW = 58;
  static const double timeW = 84;

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    if (a.hourly.isEmpty) return const SizedBox.shrink();
    final total = a.handoutTimes.length;
    final peak =
        a.hourly.fold<int>(0, (m, h) => h.handouts > m ? h.handouts : m);

    return _Section(
      title: 'Hour by hour',
      subtitle: 'Every clock hour the shift touches. A part-hour at either end '
          'is marked, and its rate is scaled to a full hour so the column '
          'still compares. Tap a row to zoom the chart onto it.',
      child: Column(
        children: [
          const _HourRowHeader(),
          for (final h in a.hourly)
            _HourRow(
              hour: h,
              total: total,
              peak: peak,
              inWindow: h.to.isAfter(windowFrom) && h.from.isBefore(windowTo),
              selected: teFramesExactly(windowFrom, windowTo, h.from, h.to),
              onTap: () => onFocusHour(h),
            ),
          _HourTotalsRow(analysis: a),
        ],
      ),
    );
  }
}

class _HourRowHeader extends StatelessWidget {
  const _HourRowHeader();

  @override
  Widget build(BuildContext context) {
    const st = TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        color: TEChartColors.muted);
    return Padding(
      padding: const EdgeInsets.only(left: _FocusRow.contentInset, bottom: 4),
      child: Row(
        children: const [
          SizedBox(width: _HourlyTable.hourW, child: Text('HOUR', style: st)),
          SizedBox(
              width: _HourlyTable.countW,
              child: Text('HANDOUTS', style: st, textAlign: TextAlign.right)),
          SizedBox(
              width: _HourlyTable.shareW,
              child: Text('SHARE', style: st, textAlign: TextAlign.right)),
          SizedBox(width: 12),
          Expanded(child: Text('', style: st)),
          SizedBox(width: 12),
          SizedBox(
              width: _HourlyTable.timeW,
              child: Text('WORKING', style: st, textAlign: TextAlign.right)),
          SizedBox(
              width: _HourlyTable.timeW,
              child: Text('IDLE+BREAK', style: st, textAlign: TextAlign.right)),
          SizedBox(
              width: _HourlyTable.timeW,
              child: Text('MOVING', style: st, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

class _HourRow extends StatelessWidget {
  final TEHourStat hour;
  final int total;
  final int peak;
  final bool inWindow;
  final bool selected;
  final VoidCallback onTap;

  const _HourRow({
    required this.hour,
    required this.total,
    required this.peak,
    required this.inWindow,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const num_ = TextStyle(
        fontSize: 11.5,
        color: TEChartColors.primaryInk,
        fontFeatures: [FontFeature.tabularFigures()]);
    const dim = TextStyle(
        fontSize: 11,
        color: TEChartColors.muted,
        fontFeatures: [FontFeature.tabularFigures()]);

    // Minute resolution: seconds add noise to a table whose rows are hours.
    String d(Duration v) {
      if (v.inSeconds == 0) return '—';
      if (v.inSeconds < 60) return '<1m';
      if (v.inHours > 0) {
        return '${v.inHours}h '
            '${v.inMinutes.remainder(60).toString().padLeft(2, '0')}m';
      }
      return '${v.inMinutes}m';
    }

    // The chart's current window is marked here too, so the two read as one
    // thing rather than as a chart and an unrelated table.
    return _FocusRow(
      selected: selected,
      inWindow: inWindow,
      onTap: onTap,
      child: Row(
        children: [
          SizedBox(
            width: _HourlyTable.hourW,
            child: Row(
              children: [
                Text(
                  '${teFormatClock(hour.hourStart)}–'
                  '${teFormatClock(hour.hourEnd)}',
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: TEChartColors.primaryInk,
                      fontFeatures: [FontFeature.tabularFigures()]),
                ),
                if (hour.isPartial) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text('${hour.covered.inMinutes}m only',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: dim),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(
            width: _HourlyTable.countW,
            child: Text('${hour.handouts}',
                style: num_.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.right),
          ),
          SizedBox(
            width: _HourlyTable.shareW,
            child: Text(
              total == 0
                  ? '—'
                  : '${(hour.handouts * 100 / total).toStringAsFixed(0)}%',
              style: dim,
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor:
                    peak == 0 ? 0.0 : (hour.handouts / peak).clamp(0.0, 1.0),
                child: Container(
                  height: 11,
                  decoration: const BoxDecoration(
                    color: TEChartColors.handouts,
                    borderRadius:
                        BorderRadius.horizontal(right: Radius.circular(4)),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
              width: _HourlyTable.timeW,
              child: Text(d(hour.working),
                  style: num_,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right)),
          SizedBox(
              width: _HourlyTable.timeW,
              child: Text(d(hour.idle + hour.breakTime),
                  style: num_,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right)),
          SizedBox(
              width: _HourlyTable.timeW,
              child: Text(d(hour.moving),
                  style: num_,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

class _HourTotalsRow extends StatelessWidget {
  final TETrackAnalysis analysis;
  const _HourTotalsRow({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    const st = TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: TEChartColors.primaryInk,
        fontFeatures: [FontFeature.tabularFigures()]);
    return Container(
      padding: const EdgeInsets.only(left: _FocusRow.contentInset, top: 6),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: TEChartColors.axis)),
      ),
      child: Row(
        children: [
          const SizedBox(
              width: _HourlyTable.hourW,
              child: Text('Whole shift',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: TEChartColors.secondaryInk))),
          SizedBox(
              width: _HourlyTable.countW,
              child: Text('${a.handoutTimes.length}',
                  style: st, textAlign: TextAlign.right)),
          const SizedBox(width: _HourlyTable.shareW),
          const SizedBox(width: 12),
          const Expanded(child: SizedBox.shrink()),
          const SizedBox(width: 12),
          SizedBox(
              width: _HourlyTable.timeW,
              child: Text(teFormatDuration(a.workingStopTime),
                  style: st, textAlign: TextAlign.right)),
          SizedBox(
              width: _HourlyTable.timeW,
              child: Text(teFormatDuration(a.idleTime + a.breakTime),
                  style: st, textAlign: TextAlign.right)),
          SizedBox(
              width: _HourlyTable.timeW,
              child: Text(teFormatDuration(a.movingTime),
                  style: st, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SUMMARY TILES
// ════════════════════════════════════════════════════════════════════════════

class _SummaryTiles extends StatelessWidget {
  final TETrackAnalysis analysis;
  const _SummaryTiles({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    // Six numbers, each one a plain fact a client can read without knowing
    // anything about how it was worked out. No jargon in a label ("dwell",
    // "interval") and no tile whose whole point is to explain another tile.
    final tiles = <Widget>[
      _Tile(
        value: '${a.totalHandouts}',
        label: 'Flyers handed out',
        note: a.untimedHandouts > 0
            ? '${a.untimedHandouts} without a timestamp'
            : null,
        accent: TEChartColors.handouts,
      ),
      _Tile(
        value: '${a.distanceKm.toStringAsFixed(1)} km',
        label: 'Distance walked',
        accent: TEChartColors.speed,
      ),
      _Tile(
        value: teFormatDuration(a.elapsed),
        label: 'Shift length',
        note: '${teFormatClock(a.start)} – ${teFormatClock(a.end)}',
      ),
      _Tile(
        value: a.ratePerHourWorking == null
            ? '—'
            : a.ratePerHourWorking!.toStringAsFixed(0),
        label: 'Handouts / working hour',
        note: 'while actually handing out flyers',
        accent: TEChartColors.handouts,
      ),
      _Tile(
        value: a.breakAndLunchTime.inSeconds == 0
            ? '—'
            : teFormatDuration(a.breakAndLunchTime),
        label: 'Break and lunch',
        note: 'stops of 10 min or more with no handouts',
        accent: TEChartColors.idle,
      ),
      _Tile(
        value: a.bestHour == null ? '—' : '${a.bestHour!.handouts}',
        label: 'Best hour',
        note: a.bestHour == null
            ? null
            : '${teFormatClock(a.bestHour!.hourStart)} – '
                '${teFormatClock(a.bestHour!.hourEnd)}',
      ),
    ];

    return _Section(
      title: 'Shift summary',
      child: Wrap(spacing: 10, runSpacing: 10, children: tiles),
    );
  }
}

class _Tile extends StatelessWidget {
  final String value;
  final String label;
  final String? note;
  final Color? accent;

  const _Tile({
    required this.value,
    required this.label,
    this.note,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 176,
      // Fixed height so the wrapped tiles line up as a grid instead of
      // stepping up and down with the length of each note.
      height: 96,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: TEChartColors.grid),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (accent != null) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                      color: accent, borderRadius: BorderRadius.circular(1)),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: TEChartColors.primaryInk,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: TEChartColors.secondaryInk)),
          if (note != null) ...[
            const SizedBox(height: 1),
            Flexible(
              child: Text(note!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 10.5, color: TEChartColors.muted)),
            ),
          ],
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// TIME SPLIT — one stacked bar of where the shift went
// ════════════════════════════════════════════════════════════════════════════

class _TimeSplit extends StatelessWidget {
  final TETrackAnalysis analysis;
  const _TimeSplit({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    final parts = <(String, Duration, Color, bool)>[
      ('Working stops', a.workingStopTime, TEChartColors.handouts, false),
      ('On the move', a.movingTime, TEChartColors.speed, false),
      ('Idle / waiting', a.idleTime, TEChartColors.idle, false),
      ('Break', a.breakTime, TEChartColors.idle, true),
      ('No tracklog', a.gapTime, TEChartColors.gap, true),
    ].where((p) => p.$2.inSeconds > 0).toList();
    final total = parts.fold<int>(0, (s, p) => s + p.$2.inSeconds);
    if (total == 0) return const SizedBox.shrink();

    return _Section(
      title: 'Where the shift went',
      subtitle: 'Share of the ${teFormatDuration(a.elapsed)} between the '
          'first and last log entry.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 22,
            // 2px surface gaps keep adjacent segments from reading as one.
            child: Row(
              children: [
                for (var i = 0; i < parts.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  Expanded(
                    flex: (parts[i].$2.inSeconds * 1000 ~/ total)
                        .clamp(1, 1000000),
                    child: Tooltip(
                      message: '${parts[i].$1} · '
                          '${teFormatDuration(parts[i].$2)} · '
                          '${(parts[i].$2.inSeconds * 100 / total).toStringAsFixed(0)}%',
                      child: CustomPaint(
                        painter: _SwatchPainter(
                            color: parts[i].$3,
                            line: false,
                            hatched: parts[i].$4),
                        // A CustomPaint with neither a child nor an explicit
                        // size lays out at zero and paints nothing.
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              for (final p in parts)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CustomPaint(
                      size: const Size(12, 12),
                      painter: _SwatchPainter(
                          color: p.$3, line: false, hatched: p.$4),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${p.$1}  ${teFormatDuration(p.$2)}  '
                      '(${(p.$2.inSeconds * 100 / total).toStringAsFixed(0)}%)',
                      style: const TextStyle(
                          fontSize: 11, color: TEChartColors.secondaryInk),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// RATE HISTOGRAM
// ════════════════════════════════════════════════════════════════════════════

class _RateHistogram extends StatelessWidget {
  final TETrackAnalysis analysis;
  final DateTime windowFrom;
  final DateTime windowTo;
  final void Function(DateTime from, DateTime to) onFocus;

  const _RateHistogram({
    required this.analysis,
    required this.windowFrom,
    required this.windowTo,
    required this.onFocus,
  });

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    if (a.buckets.isEmpty) return const SizedBox.shrink();
    final peak =
        a.buckets.fold<int>(0, (m, b) => b.handouts > m ? b.handouts : m);
    if (peak == 0) return const SizedBox.shrink();

    return _Section(
      title: 'Handouts per ${a.config.bucket.inMinutes} minutes',
      subtitle: 'Bursts line up with the traffic-light cycles the distributor '
          'worked; flat runs are walking, waiting or breaks. '
          'Tap a bar to zoom the chart onto it.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 84,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < a.buckets.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  Expanded(
                    child: _FocusBar(
                      selected: teFramesExactly(windowFrom, windowTo,
                          a.buckets[i].start, a.buckets[i].end),
                      inWindow: a.buckets[i].end.isAfter(windowFrom) &&
                          a.buckets[i].start.isBefore(windowTo),
                      tooltip:
                          '${teFormatClock(a.buckets[i].start)}–${teFormatClock(a.buckets[i].end)}'
                          '\n${a.buckets[i].handouts} handouts'
                          '\nTap to zoom the chart onto this',
                      onTap: () =>
                          onFocus(a.buckets[i].start, a.buckets[i].end),
                      heightFactor:
                          (a.buckets[i].handouts / peak).clamp(0.0, 1.0),
                      color: TEChartColors.handouts,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(height: 1, color: TEChartColors.axis),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(teFormatClock(a.start),
                  style: const TextStyle(
                      fontSize: 10, color: TEChartColors.muted)),
              Text('peak $peak in one bucket',
                  style: const TextStyle(
                      fontSize: 10, color: TEChartColors.muted)),
              Text(teFormatClock(a.end),
                  style: const TextStyle(
                      fontSize: 10, color: TEChartColors.muted)),
            ],
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// FOCUS ROW — shared chrome for anything that reframes the chart when tapped
// ════════════════════════════════════════════════════════════════════════════

/// A table row that zooms the chart onto its own slice of the shift.
///
/// Carries all three states a clickable row needs: it looks clickable before
/// the tap (hover wash + pointer cursor), it flashes on the tap (ink ripple),
/// and it STAYS marked afterwards with an accent bar down its left edge — so
/// after the page scrolls back to the chart, the row you picked is still the
/// one that is obviously picked when you scroll down again.
class _FocusRow extends StatelessWidget {
  /// The window is exactly this row's range — this row is what is on screen.
  final bool selected;

  /// The window merely overlaps this row.
  final bool inWindow;

  final VoidCallback onTap;
  final Widget child;

  const _FocusRow({
    required this.selected,
    required this.inWindow,
    required this.onTap,
    required this.child,
  });

  /// How far a focus row's content sits from the table's left edge: the
  /// selection bar plus its breathing room. Column headers and totals rows
  /// must use the same inset or the columns will not line up.
  static const double contentInset = 9;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      hoverColor: TEChartColors.speed.withValues(alpha: 0.05),
      splashColor: TEChartColors.speed.withValues(alpha: 0.18),
      highlightColor: TEChartColors.speed.withValues(alpha: 0.10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.fromLTRB(6, 5, 0, 5),
        decoration: BoxDecoration(
          color: selected
              ? TEChartColors.speed.withValues(alpha: 0.13)
              : inWindow
                  ? TEChartColors.speed.withValues(alpha: 0.05)
                  : Colors.transparent,
          border: Border(
            top: const BorderSide(color: TEChartColors.grid),
            // Transparent when unselected rather than absent, so the row's
            // columns do not shift sideways as the selection moves.
            left: BorderSide(
              color: selected ? TEChartColors.speed : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: child,
      ),
    );
  }
}

/// A histogram bar that reframes the chart when tapped.
///
/// A bar is a small target, so the hit area is the FULL column height, not
/// just the painted bar — a short bar for a quiet quarter-hour is still easy
/// to hit. The bar itself dims when it is outside the chart's window and
/// darkens when it is the window, so the histogram doubles as a position
/// indicator once you have zoomed in.
class _FocusBar extends StatelessWidget {
  final bool selected;
  final bool inWindow;
  final String tooltip;
  final VoidCallback onTap;
  final double heightFactor;
  final Color color;

  const _FocusBar({
    required this.selected,
    required this.inWindow,
    required this.tooltip,
    required this.onTap,
    required this.heightFactor,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 300),
      child: InkWell(
        onTap: onTap,
        hoverColor: TEChartColors.speed.withValues(alpha: 0.08),
        splashColor: TEChartColors.speed.withValues(alpha: 0.20),
        highlightColor: TEChartColors.speed.withValues(alpha: 0.12),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            heightFactor: heightFactor,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              constraints: const BoxConstraints(minHeight: 2),
              decoration: BoxDecoration(
                color: color.withValues(
                    alpha: selected ? 1.0 : (inWindow ? 0.85 : 0.35)),
                // 4px rounded data-end, square on the baseline.
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(4)),
                border: selected
                    ? const Border(
                        top: BorderSide(
                            color: TEChartColors.primaryInk, width: 2))
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// True when the visible window is (near enough) exactly [from]–[to]. The
/// tolerance absorbs the rounding of a window held as a fraction of the shift.
bool teFramesExactly(
  DateTime windowFrom,
  DateTime windowTo,
  DateTime from,
  DateTime to,
) {
  const slack = Duration(seconds: 30);
  return windowFrom.difference(from).abs() < slack &&
      windowTo.difference(to).abs() < slack;
}

// ════════════════════════════════════════════════════════════════════════════
// SECTION SHELL
// ════════════════════════════════════════════════════════════════════════════

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const _Section({
    required this.title,
    this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: TEChartColors.primaryInk)),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle!,
              style: const TextStyle(fontSize: 11, color: TEChartColors.muted)),
        ],
        const SizedBox(height: 10),
        child,
      ],
    );
  }
}
