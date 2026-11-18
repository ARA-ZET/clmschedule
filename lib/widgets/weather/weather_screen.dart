// widgets/weather/weather_screen.dart
//
// Apps → Weather, laid out like yr.no: a "now" hero on a sky that matches
// the conditions, the hour-by-hour graph for the next 48 hours, and the
// ~10-day table whose rows open into hourly detail — all rated for
// distribution. Forecasts come from MET Norway (yr's data) through the
// cached `weatherForecast` callable.
import 'package:clmschedule/utils/text_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart' show DateFormat;

import '../../models/weather_forecast.dart';
import '../../providers/weather_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/schedule_time.dart';
import 'weather_day_table.dart';
import 'weather_meteogram.dart';
import 'weather_now_card.dart';
import 'weather_symbol.dart';

class WeatherScreen extends riverpod.ConsumerStatefulWidget {
  /// Day to open on (a schedule civil date), e.g. from a header badge.
  final DateTime? initialDate;

  const WeatherScreen({super.key, this.initialDate});

  @override
  riverpod.ConsumerState<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends riverpod.ConsumerState<WeatherScreen> {
  String? _locationId; // null = depot (first entry)
  late DateTime? _expandedDay = widget.initialDate == null
      ? null
      : DateTime(widget.initialDate!.year, widget.initialDate!.month,
          widget.initialDate!.day);
  late bool _scrollToExpanded = widget.initialDate != null;
  final _rowKeys = <DateTime, GlobalKey>{};

  Future<void> _pickLocation(List<WeatherLocation> locations) async {
    final id = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _LocationPickerDialog(
        locations: locations,
        selectedId: _locationId ?? locations.first.id,
      ),
    );
    if (id != null && mounted) setState(() => _locationId = id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locations = ref.watch(weatherLocationsRiverpod);
    final location = locations.firstWhere(
      (l) => l.id == _locationId,
      orElse: () => locations.first,
    );
    final forecast = ref.watch(weatherForecastRiverpod(location.key));
    void refresh() => ref.invalidate(weatherForecastRiverpod(location.key));

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text('Weather'),
        actions: [
          TextButton.icon(
            onPressed: () => _pickLocation(locations),
            icon: const Icon(Icons.search),
            label: const Text('Change place'),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: refresh,
          ),
          const SizedBox(width: 8),
        ],
        bottom: forecast.isLoading && forecast.hasValue
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: forecast.when(
        loading: () => const _LoadingView(),
        error: (e, _) => _ErrorView(
          message: friendlyFirebaseError(e, action: 'load the forecast'),
          onRetry: refresh,
        ),
        data: (f) {
          if (_scrollToExpanded) {
            _scrollToExpanded = false;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final ctx = _rowKeys[_expandedDay]?.currentContext;
              if (ctx != null) {
                Scrollable.ensureVisible(
                  ctx,
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.easeOutCubic,
                  alignment: 0.1,
                );
              }
            });
          }
          return _ForecastBody(
            forecast: f,
            location: location,
            onChangeLocation: () => _pickLocation(locations),
            expandedDay: _expandedDay,
            rowKeys: _rowKeys,
            onToggleDay: (d) =>
                setState(() => _expandedDay = _expandedDay == d ? null : d),
          );
        },
      ),
    );
  }
}

class _ForecastBody extends StatelessWidget {
  final WeatherForecast forecast;
  final WeatherLocation location;
  final VoidCallback onChangeLocation;
  final DateTime? expandedDay;
  final Map<DateTime, GlobalKey> rowKeys;
  final ValueChanged<DateTime> onToggleDay;

  const _ForecastBody({
    required this.forecast,
    required this.location,
    required this.onChangeLocation,
    required this.expandedDay,
    required this.rowKeys,
    required this.onToggleDay,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nowInstant = DateTime.now().toUtc();
    final now = forecast.stepAt(nowInstant);
    final today = forecast.dayFor(scheduleToday());
    final hourly = forecast.steps
        .where((s) => s.hours == 1 && s.end.isAfter(nowInstant))
        .take(48)
        .toList();
    final updated = forecast.updatedAt;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (now != null)
                WeatherNowCard(
                  locationName: location.name,
                  onChangeLocation: onChangeLocation,
                  now: now,
                  today: today,
                  lat: location.lat,
                  lon: location.lon,
                ),
              if (hourly.isNotEmpty) ...[
                const SizedBox(height: 32),
                const _SectionTitle(
                  title: 'Hour by hour',
                  subtitle: 'Next 48 hours — temperature, rain (mm) and wind '
                      '(km/h). Shaded columns are night.',
                ),
                const SizedBox(height: 12),
                Card(
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                    child: WeatherMeteogram(
                      steps: hourly,
                      lat: location.lat,
                      lon: location.lon,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 32),
              _SectionTitle(
                title: '${forecast.days.length}-day forecast',
                subtitle: 'Tap a day for its hourly detail. The coloured edge '
                    'rates the 06:00–18:00 working day for distribution.',
                trailing: const _RatingLegend(),
              ),
              const SizedBox(height: 12),
              WeatherDayTable(
                days: forecast.days,
                steps: forecast.steps,
                expandedDay: expandedDay,
                onToggle: onToggleDay,
                rowKeys: rowKeys,
              ),
              const SizedBox(height: 24),
              _Attribution(updated: updated),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _SectionTitle({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    if (trailing == null) return text;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.end,
      spacing: 16,
      runSpacing: 8,
      children: [text, trailing!],
    );
  }
}

class _RatingLegend extends StatelessWidget {
  const _RatingLegend();

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final explain = {
      DistributionRating.good:
          'Under ${DistributionWeatherThresholds.marginalRainMm} mm rain and ${kmh(DistributionWeatherThresholds.marginalWindMs)} km/h wind',
      DistributionRating.marginal:
          'From ${DistributionWeatherThresholds.marginalRainMm} mm rain or ${kmh(DistributionWeatherThresholds.marginalWindMs)} km/h wind',
      DistributionRating.poor:
          'From ${DistributionWeatherThresholds.poorRainMm.round()} mm rain or ${kmh(DistributionWeatherThresholds.poorWindMs)} km/h wind',
    };
    return Wrap(
      spacing: 12,
      children: [
        for (final r in DistributionRating.values)
          Tooltip(
            message: explain[r]!,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: distributionRatingColor(r, b),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(distributionRatingShort(r),
                    style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
          ),
      ],
    );
  }
}

class _Attribution extends StatelessWidget {
  final DateTime? updated;

  const _Attribution({required this.updated});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      children: [
        Text(
          'Forecast from MET Norway — the same data as yr.no'
          '${updated == null ? '' : ' · model run ${DateFormat('EEE d MMM, HH:mm').format(toScheduleCivil(updated!))}'}',
          textAlign: TextAlign.center,
          style: style,
        ),
        Text(
          'Data CC BY 4.0 MET Norway · Weather symbols © Yr/NRK, CC BY 4.0',
          textAlign: TextAlign.center,
          style: style,
        ),
      ],
    );
  }
}

class _LocationPickerDialog extends StatefulWidget {
  final List<WeatherLocation> locations;
  final String selectedId;

  const _LocationPickerDialog({
    required this.locations,
    required this.selectedId,
  });

  @override
  State<_LocationPickerDialog> createState() => _LocationPickerDialogState();
}

class _LocationPickerDialogState extends State<_LocationPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches =
        TextSearch(_query).rank(widget.locations, (l) => [l.name]);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search work suburbs',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Flexible(
              child: matches.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No matching place.'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: matches.length,
                      itemBuilder: (_, i) {
                        final l = matches[i];
                        final selected = l.id == widget.selectedId;
                        final isBase = l.id == widget.locations.first.id;
                        return ListTile(
                          leading: Icon(
                            isBase
                                ? Icons.warehouse_outlined
                                : Icons.place_outlined,
                            color: selected ? theme.colorScheme.primary : null,
                          ),
                          title: Text(l.name),
                          subtitle: isBase
                              ? const Text(
                                  'Where every distribution day starts')
                              : null,
                          trailing: selected
                              ? Icon(Icons.check,
                                  color: theme.colorScheme.primary)
                              : null,
                          selected: selected,
                          // The dialog's own context, so this closes the
                          // dialog rather than the page under it.
                          onTap: () => Navigator.of(context).pop(l.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const WeatherSymbolIcon('partlycloudy_day', size: 72),
          const SizedBox(height: 16),
          const SizedBox(
            width: 160,
            child: LinearProgressIndicator(minHeight: 3),
          ),
          const SizedBox(height: 12),
          Text('Fetching the forecast…',
              style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 56),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
