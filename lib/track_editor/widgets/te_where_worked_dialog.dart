// track_editor/widgets/te_where_worked_dialog.dart
//
// The check before the report PDF is built: one row per promoter shift with
// the "Where worked" intersections the report will print. The names come
// from map servers that are sometimes busy or have no road near a spot, so a
// row can come back empty — "Retry" asks again for the missing spots one at a
// time, showing which spot it is on and how long it has been waiting, and any
// row can be typed over by hand. Above them sits the client map link each
// promoter's map opens, found from the Job List and editable too. Typed text
// is kept in TEReportProvider, so generating the report again keeps it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/te_promoter_day.dart';
import '../providers/te_report_provider.dart';
import '../services/te_place_names.dart';
import '../services/te_report_map_links.dart';
import '../services/te_report_pdf.dart';
import '../utils/te_track_analysis.dart';

final _dayFmt = DateFormat('EEE d MMM yyyy');
final _shortDayFmt = DateFormat('EEE d MMM');

/// Shows the check for [days]. Returns the place names to build the PDF
/// with (refreshed by any retry), or null when cancelled. [linkGroups] are
/// the client maps found for the days; edits to them go to
/// [TEReportProvider.setMapLinkOverride]. Typed text goes to [report] —
/// the Job List report page keeps its own; null is the Track Editor's.
Future<Map<String, TEPlaceName>?> showWhereWorkedDialog(
  BuildContext context, {
  required List<TEPromoterDay> days,
  required Map<String, TEPlaceName> places,
  List<TEMapLinkGroup> linkGroups = const [],
  TEReportProvider? report,
}) {
  return showDialog<Map<String, TEPlaceName>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WhereWorkedDialog(
        days: days, places: places, linkGroups: linkGroups, report: report),
  );
}

/// The link [group]'s maps will open: what was typed in, else what was found.
String teGroupLink(TEReportProvider report, TEMapLinkGroup group) =>
    report.mapLinkOverrideFor(group.days.first) ?? group.url;

/// Where one spot's lookup stands.
enum _SpotState { found, noRoad, noAnswer, queued, looking }

String _spotKey(TEHotspot h) =>
    tePlaceKey(h.centre.latitude, h.centre.longitude);

class _WhereWorkedDialog extends riverpod.ConsumerStatefulWidget {
  final List<TEPromoterDay> days;
  final Map<String, TEPlaceName> places;
  final List<TEMapLinkGroup> linkGroups;
  final TEReportProvider? report;
  const _WhereWorkedDialog(
      {required this.days,
      required this.places,
      required this.linkGroups,
      this.report});

  @override
  riverpod.ConsumerState<_WhereWorkedDialog> createState() =>
      _WhereWorkedDialogState();
}

class _WhereWorkedDialogState
    extends riverpod.ConsumerState<_WhereWorkedDialog> {
  late Map<String, TEPlaceName> _places = widget.places;
  late final List<TEPromoterDay> _days = [...widget.days]..sort((a, b) {
      final byDate = a.date.compareTo(b.date);
      return byDate != 0
          ? byDate
          : a.distributor.name.compareTo(b.distributor.name);
    });
  late final bool _multiDate =
      _days.map((d) => _dayFmt.format(d.date)).toSet().length > 1;
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, TextEditingController> _linkControllers = {};

  // ── Retry state ──
  bool _retrying = false;
  bool _stopRequested = false;
  TEPlaceProgress? _progress;

  /// Spots in the current retry that haven't been looked up yet.
  final Set<String> _queued = {};
  DateTime? _currentSince;
  Timer? _ticker;

  /// What the last retry came to, shown once it ends.
  (String, bool)? _summary;

  TEReportProvider get _report => widget.report ?? ref.read(teReportRiverpod);

  List<(double, double)> get _allPoints => [
        for (final d in _days)
          for (final h in teWorkSpots(d.analysis))
            (h.centre.latitude, h.centre.longitude),
      ];

  String _auto(TEPromoterDay day) =>
      teAutoWhere(day.analysis, _places).join('\n');

  @override
  void initState() {
    super.initState();
    for (final d in _days) {
      _controllers[d.key] = TextEditingController(
          text: _report.whereOverrideFor(d) ?? _auto(d));
    }
    for (final g in widget.linkGroups) {
      _linkControllers[g.key] =
          TextEditingController(text: teGroupLink(_report, g));
    }
  }

  @override
  void dispose() {
    _stopRequested = true;
    _ticker?.cancel();
    for (final c in [..._controllers.values, ..._linkControllers.values]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _missing =>
      _days.where((d) => _controllers[d.key]!.text.trim().isEmpty).length;

  _SpotState _stateOf(String key, double lat, double lon) {
    if (_progress?.current.contains(key) ?? false) return _SpotState.looking;
    if (_queued.contains(key)) return _SpotState.queued;
    final (looked, name) = cachedIntersection(lat, lon);
    if (!looked) return _SpotState.noAnswer;
    return name == null ? _SpotState.noRoad : _SpotState.found;
  }

  /// The unnamed spots of every row not typed by hand — what Retry asks for.
  Map<String, (double, double)> get _retryPoints {
    final out = <String, (double, double)>{};
    for (final d in _days) {
      if (_report.whereOverrideFor(d) != null) continue;
      for (final h in teWorkSpots(d.analysis)) {
        final (lat, lon) = (h.centre.latitude, h.centre.longitude);
        final (looked, name) = cachedIntersection(lat, lon);
        if (!looked || name == null) out[_spotKey(h)] = (lat, lon);
      }
    }
    return out;
  }

  /// "Nolan · Spot 2 (240 flyers)" for the spot with [key].
  String _labelFor(String key) {
    for (final d in _days) {
      final spots = teWorkSpots(d.analysis);
      for (var i = 0; i < spots.length; i++) {
        if (_spotKey(spots[i]) != key) continue;
        final who = _multiDate
            ? '${d.distributor.name}, ${_shortDayFmt.format(d.date)}'
            : d.distributor.name;
        return '$who · Spot ${i + 1} (${spots[i].handouts} flyers)';
      }
    }
    return 'a spot';
  }

  /// Picks up whatever names have come back; rows typed by hand keep their
  /// typing.
  void _refreshNames() {
    _places = cachedPlaceNames(_allPoints);
    for (final d in _days) {
      if (_report.whereOverrideFor(d) == null) {
        _controllers[d.key]!.text = _auto(d);
      }
    }
  }

  void _onChanged(TEPromoterDay day, String text) {
    // Typing the looked-up names back in is the same as not editing.
    _report.setWhereOverride(day, text.trim() == _auto(day) ? null : text);
    setState(() {});
  }

  void _onLinkChanged(TEMapLinkGroup group, String text) {
    _report.setMapLinkOverride(
        group.days, text.trim() == group.url ? null : text.trim());
    setState(() {});
  }

  void _reset(TEPromoterDay day) {
    _report.setWhereOverride(day, null);
    setState(() => _controllers[day.key]!.text = _auto(day));
  }

  Future<void> _retry() async {
    final points = _retryPoints;
    if (points.isEmpty) return;
    forgetUnnamedPlaces(points.values);
    setState(() {
      _retrying = true;
      _stopRequested = false;
      _summary = null;
      _queued
        ..clear()
        ..addAll(points.keys);
      _progress = TEPlaceProgress(done: 0, total: points.length);
    });
    // Ticks the "waiting 12 s" counter so a slow server still shows signs
    // of life.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    try {
      // One spot per query: the progress moves spot by spot, and a small
      // query is the one a busy server is most likely to answer in time.
      await resolvePlaceNames(
        points.values,
        batchSize: 1,
        isCancelled: () => _stopRequested,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            // A new spot started: restart its waiting counter.
            if (p.current.join() != _progress?.current.join()) {
              _currentSince = DateTime.now();
            }
            _queued.removeAll(p.current);
            _progress = p;
            _refreshNames();
          });
        },
      );
    } catch (e) {
      debugPrint('Where worked: retry failed: $e');
    }

    _ticker?.cancel();
    _ticker = null;
    if (!mounted) return;
    setState(() {
      _refreshNames();
      final found = points.keys.where((k) {
        final p = points[k]!;
        return cachedIntersection(p.$1, p.$2).$2 != null;
      }).length;
      final stopped = _stopRequested;
      _summary = (
        '${stopped ? 'Stopped' : 'Done'}: found $found of ${points.length} '
            'spot${points.length == 1 ? '' : 's'}.'
            '${found < points.length ? ' Type the rest in, or retry again shortly.' : ''}',
        found == points.length,
      );
      _retrying = false;
      _stopRequested = false;
      _queued.clear();
      _progress = null;
      _currentSince = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final missing = _missing;
    final retryCount = _retrying ? 0 : _retryPoints.length;

    final rows = <Widget>[];
    String? lastDate;
    for (final d in _days) {
      final date = _dayFmt.format(d.date);
      if (_multiDate && date != lastDate) {
        rows.add(Padding(
          padding: EdgeInsets.only(top: lastDate == null ? 0 : 12, bottom: 4),
          child: Text(date,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.black54)),
        ));
        lastDate = date;
      }
      final spots = teWorkSpots(d.analysis);
      rows.add(_ShiftWhereRow(
        day: d,
        spots: spots,
        spotStates: [
          for (final h in spots)
            _stateOf(_spotKey(h), h.centre.latitude, h.centre.longitude),
        ],
        controller: _controllers[d.key]!,
        edited: _report.whereOverrideFor(d) != null,
        busyRound: _progress?.round ?? 1,
        onChanged: (t) => _onChanged(d, t),
        onReset: () => _reset(d),
      ));
    }

    return AlertDialog(
      title: const Text('Check the report'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.linkGroups.isNotEmpty) ...[
              const Text('Client map link',
                  style:
                      TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              const Text(
                'Clicking a promoter\'s map in the PDF opens this map.',
                style: TextStyle(fontSize: 12.5, color: Colors.black54),
              ),
              const SizedBox(height: 8),
              for (final g in widget.linkGroups)
                _LinkRow(
                  group: g,
                  controller: _linkControllers[g.key]!,
                  multiple: widget.linkGroups.length > 1,
                  onChanged: (t) => _onLinkChanged(g, t),
                ),
              const Divider(height: 20),
            ],
            const Text('Where worked',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            const Text(
              'These are the intersections the report prints under "Where '
              'worked". Fix anything wrong or missing, one per line. Tap a '
              'spot to see it on Google Maps.',
              style: TextStyle(fontSize: 12.5, color: Colors.black54),
            ),
            if (_retrying && _progress != null) ...[
              const SizedBox(height: 10),
              _RetryProgress(
                progress: _progress!,
                currentLabel: _progress!.current.isEmpty
                    ? null
                    : _labelFor(_progress!.current.first),
                waiting: _currentSince == null
                    ? Duration.zero
                    : DateTime.now().difference(_currentSince!),
                stopping: _stopRequested,
              ),
            ] else if (_summary != null) ...[
              const SizedBox(height: 10),
              _Banner(
                text: _summary!.$1,
                ok: _summary!.$2,
              ),
            ],
            if (missing > 0 && !_retrying) ...[
              const SizedBox(height: 10),
              _Banner(
                text: '$missing of ${_days.length} '
                    '${_days.length == 1 ? 'shift has' : 'shifts have'} '
                    'no intersection. Retry the lookup or type it in — '
                    'otherwise the report shows "—".',
                ok: false,
              ),
            ],
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: rows,
                ),
              ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        if (_retrying)
          TextButton.icon(
            onPressed: _stopRequested
                ? null
                : () => setState(() => _stopRequested = true),
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: Text(_stopRequested ? 'Stopping…' : 'Stop'),
          )
        else
          TextButton.icon(
            onPressed: retryCount == 0 ? null : _retry,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(retryCount == 0
                ? 'Nothing to retry'
                : 'Retry $retryCount missing '
                    'spot${retryCount == 1 ? '' : 's'}'),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () {
                _stopRequested = true;
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed:
                  _retrying ? null : () => Navigator.of(context).pop(_places),
              icon: const Icon(Icons.picture_as_pdf, size: 18),
              label: const Text('Build PDF'),
            ),
          ],
        ),
      ],
    );
  }
}

/// One client map's link: what the PDF's maps for [group]'s promoters open.
class _LinkRow extends StatelessWidget {
  final TEMapLinkGroup group;
  final TextEditingController controller;
  final bool multiple;
  final ValueChanged<String> onChanged;

  const _LinkRow({
    required this.group,
    required this.controller,
    required this.multiple,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final text = controller.text.trim();
    final uri = Uri.tryParse(text);
    final valid = text.isEmpty ||
        (uri != null && uri.hasScheme && uri.host.isNotEmpty);
    final names = {for (final d in group.days) d.distributor.name};
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (multiple)
            SizedBox(
              width: 150,
              child: Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.label,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    Text(names.join(', '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black45)),
                  ],
                ),
              ),
            ),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: 'https://maps.communitylifemedia.co.za/map/…',
                helperText: !valid
                    ? 'Should be a full link starting with https://'
                    : (text.isEmpty
                        ? (group.url.isEmpty
                            ? 'No linked map found for this job — paste the '
                                'client map link, or leave blank for no link'
                            : 'Left blank: the maps won\'t link anywhere')
                        : null),
                helperMaxLines: 2,
                helperStyle: TextStyle(color: Colors.amber.shade900),
                suffixIcon: valid && text.isNotEmpty
                    ? IconButton(
                        tooltip: 'Open this map',
                        icon: const Icon(Icons.open_in_new, size: 18),
                        onPressed: () => launchUrl(uri!,
                            mode: LaunchMode.externalApplication),
                      )
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The live readout while Retry works: which spot, how many done, and how
/// long the current one has been waiting on the servers.
class _RetryProgress extends StatelessWidget {
  final TEPlaceProgress progress;
  final String? currentLabel;
  final Duration waiting;
  final bool stopping;

  const _RetryProgress({
    required this.progress,
    required this.currentLabel,
    required this.waiting,
    required this.stopping,
  });

  @override
  Widget build(BuildContext context) {
    final n = progress.done + 1;
    final secs = waiting.inSeconds;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        border: Border.all(color: Colors.blue.shade100),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  stopping
                      ? 'Stopping after this spot…'
                      : 'Looking up spot ${n > progress.total ? progress.total : n} '
                          'of ${progress.total}'
                          '${currentLabel == null ? '' : ': $currentLabel'}',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.blue.shade900),
                ),
              ),
              if (secs > 0)
                Text('${secs}s',
                    style:
                        TextStyle(fontSize: 12, color: Colors.blue.shade900)),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: progress.total == 0 ? null : progress.done / progress.total,
            minHeight: 5,
            borderRadius: BorderRadius.circular(3),
          ),
          if (progress.round > 1 || secs >= 15) ...[
            const SizedBox(height: 6),
            Text(
              progress.round > 1
                  ? 'No server answered the first time — asking again. '
                      'This can take up to a minute per spot.'
                  : 'The map servers are slow right now; still waiting for '
                      'an answer.',
              style: TextStyle(fontSize: 11.5, color: Colors.blue.shade900),
            ),
          ],
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String text;
  final bool ok;
  const _Banner({required this.text, required this.ok});

  @override
  Widget build(BuildContext context) {
    final colour = ok ? Colors.green : Colors.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colour.shade50,
        border: Border.all(color: colour.shade200),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.warning_amber_rounded,
              size: 18, color: ok ? colour.shade800 : colour.shade900),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12,
                    color: ok ? colour.shade900 : Colors.amber.shade900)),
          ),
        ],
      ),
    );
  }
}

class _ShiftWhereRow extends StatelessWidget {
  final TEPromoterDay day;
  final List<TEHotspot> spots;
  final List<_SpotState> spotStates;
  final TextEditingController controller;
  final bool edited;
  final int busyRound;
  final ValueChanged<String> onChanged;
  final VoidCallback onReset;

  const _ShiftWhereRow({
    required this.day,
    required this.spots,
    required this.spotStates,
    required this.controller,
    required this.edited,
    required this.busyRound,
    required this.onChanged,
    required this.onReset,
  });

  String? get _helper {
    if (spotStates.contains(_SpotState.looking)) {
      return busyRound > 1 ? 'Looking up… (asking again)' : 'Looking up…';
    }
    if (spotStates.contains(_SpotState.queued)) return 'Waiting its turn…';
    if (edited) return 'Typed by hand';
    if (controller.text.trim().isNotEmpty || spots.isEmpty) return null;
    return spotStates.contains(_SpotState.noAnswer)
        ? "Map servers didn't answer — retry, or type it in"
        : 'No named road near this spot — type it in';
  }

  @override
  Widget build(BuildContext context) {
    final empty = controller.text.trim().isEmpty;
    final busy = spotStates.contains(_SpotState.looking) ||
        spotStates.contains(_SpotState.queued);
    final warn = empty && !busy;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(day.distributor.name,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  onChanged: onChanged,
                  minLines: 1,
                  maxLines: 3,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    hintText: 'e.g. Voortrekker Rd & Durban Rd',
                    helperText: _helper,
                    helperStyle: TextStyle(
                        color: warn
                            ? Colors.amber.shade900
                            : (busy
                                ? Colors.blue.shade700
                                : Colors.blueGrey.shade600)),
                    enabledBorder: warn
                        ? OutlineInputBorder(
                            borderSide:
                                BorderSide(color: Colors.amber.shade700))
                        : null,
                    suffixIcon: edited
                        ? IconButton(
                            tooltip: 'Use the looked-up intersections',
                            icon: const Icon(Icons.undo, size: 18),
                            onPressed: onReset,
                          )
                        : null,
                  ),
                ),
                if (spots.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'No handout points in this shift to look up.',
                      style: TextStyle(fontSize: 11.5, color: Colors.black45),
                    ),
                  )
                else
                  Wrap(
                    spacing: 4,
                    children: [
                      for (var i = 0; i < spots.length; i++)
                        Tooltip(
                          message: switch (spotStates[i]) {
                            _SpotState.found => 'Intersection found',
                            _SpotState.noRoad =>
                              'No named road within 120 m of this spot',
                            _SpotState.noAnswer =>
                              "Map servers didn't answer for this spot",
                            _SpotState.queued => 'Waiting to be looked up',
                            _SpotState.looking => 'Looking up now…',
                          },
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              visualDensity: VisualDensity.compact,
                              textStyle: const TextStyle(fontSize: 11.5),
                            ),
                            onPressed: () => _openMap(spots[i]),
                            icon: _spotIcon(spotStates[i]),
                            label: Text(
                                'Spot ${i + 1} · ${spots[i].handouts} flyers'),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _spotIcon(_SpotState s) => switch (s) {
        _SpotState.looking => const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          ),
        _SpotState.queued =>
          const Icon(Icons.schedule, size: 15, color: Colors.black38),
        _SpotState.found =>
          Icon(Icons.check_circle, size: 15, color: Colors.green.shade600),
        _SpotState.noRoad || _SpotState.noAnswer => Icon(
            Icons.error_outline,
            size: 15,
            color: Colors.amber.shade800),
      };

  Future<void> _openMap(TEHotspot spot) async {
    final c = spot.centre;
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1'
        '&query=${c.latitude},${c.longitude}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
