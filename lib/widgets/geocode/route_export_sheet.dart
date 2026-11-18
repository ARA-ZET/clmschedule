import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/route_export_service.dart';
import '../../services/route_planner_service.dart';
// save_file.dart is the web (File System Access API) implementation; the
// stub takes over wherever dart:io exists, matching the other call sites.
import '../../utils/save_with_picker.dart';
import 'geocode_ui.dart';

/// Everything you can take away from a planned route: the KML for Google
/// Earth / My Maps, the spreadsheet for the office, the GPX for the van,
/// and the live Google Maps directions link for the driver's phone.
class RouteExportSheet extends StatefulWidget {
  final PlannedRoute route;

  /// Used to name the files — normally the suburb.
  final String baseName;

  /// Opens the run in the shareable map editor, where it can be saved to
  /// the gallery and shared with a client. Null when there is no route to
  /// hand over.
  final Future<void> Function()? onOpenClientMap;

  /// Cadastral boundaries to draw under the stops, keyed by
  /// [Address.erfId]. Empty for a run that came from plain geocoding.
  final Map<String, RouteParcel> parcels;

  const RouteExportSheet({
    super.key,
    required this.route,
    required this.baseName,
    this.onOpenClientMap,
    this.parcels = const {},
  });

  static Future<void> show(
    BuildContext context, {
    required PlannedRoute route,
    required String baseName,
    Future<void> Function()? onOpenClientMap,
    Map<String, RouteParcel> parcels = const {},
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (_) => RouteExportSheet(
        route: route,
        baseName: baseName,
        onOpenClientMap: onOpenClientMap,
        parcels: parcels,
      ),
    );
  }

  @override
  State<RouteExportSheet> createState() => _RouteExportSheetState();
}

class _RouteExportSheetState extends State<RouteExportSheet> {
  String? _busyAction;

  Future<void> _run(String action, Future<String> Function() task) async {
    setState(() => _busyAction = action);
    try {
      final message = await task();
      if (!mounted) return;
      showGeocodeSnack(context, message);
    } catch (e) {
      if (!mounted) return;
      showGeocodeSnack(context, 'Export failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  /// Offer the OS save dialog first, falling back to a plain download so
  /// the user always ends up with the file somewhere they chose.
  Future<String> _save(
    String content,
    String extension,
    String mimeType,
    String typeDescription,
  ) async {
    final name = RouteExportService.fileName(
      widget.baseName,
      extension,
      widget.route.plannedAt,
    );
    final result = await saveWithPicker(
      fileName: name,
      load: () async => RouteExportService.toBytes(content),
      mimeType: mimeType,
      typeDescription: typeDescription,
    );
    return result.message;
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final theme = Theme.of(context);
    final mapsUrls = RouteExportService.mapsDirectionsUrls(route);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.ios_share_rounded,
                    color: GeocodeColors.brand),
                const SizedBox(width: 10),
                Text(
                  'Export the route',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${route.deliveryStops.length} stops in drive order · '
              '${route.totalDistanceFormatted} · '
              '${route.totalDrivingFormatted} driving',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor),
            ),
            if (!route.usedRealRoads) ...[
              const SizedBox(height: 10),
              _warningBanner(
                'These figures are straight-line estimates — the Directions '
                'service did not answer. Re-optimise before relying on them.',
              ),
            ],
            const SizedBox(height: 18),

            _sectionLabel(context, 'Spreadsheet'),
            _tile(
              action: 'tsv',
              icon: Icons.content_paste_go_rounded,
              title: 'Copy for Google Sheets',
              subtitle:
                  'Tab-separated — paste straight into a sheet and the columns land themselves.',
              onTap: () => _run('tsv', () async {
                await Clipboard.setData(
                  ClipboardData(text: RouteExportService.buildTsv(route)),
                );
                return 'Route copied — paste into a Google Sheet';
              }),
            ),
            _tile(
              action: 'csv',
              icon: Icons.table_chart_rounded,
              title: 'Download CSV',
              subtitle:
                  'Stops in drive order with legs, cumulative totals and ETAs.',
              onTap: () => _run(
                'csv',
                () => _save(
                  RouteExportService.buildCsv(route),
                  'csv',
                  'text/csv',
                  'Spreadsheet (CSV)',
                ),
              ),
            ),

            if (widget.onOpenClientMap != null) ...[
              const SizedBox(height: 14),
              _sectionLabel(context, 'Share with a client'),
              _tile(
                action: 'client-map',
                icon: Icons.share_location_rounded,
                title: 'Publish as a client map',
                subtitle: widget.parcels.isNotEmpty
                    ? '${widget.parcels.length} parcel boundaries, numbered '
                        'stops and the route, saved to the maps gallery with '
                        'a share link.'
                    : 'Numbered stops and the route, saved to the maps '
                        'gallery with a share link.',
                onTap: () => _run('client-map', () async {
                  Navigator.of(context).pop();
                  await widget.onOpenClientMap!.call();
                  return 'Client map published';
                }),
              ),
            ],

            const SizedBox(height: 14),
            _sectionLabel(context, 'Mapping'),
            _tile(
              action: 'kml',
              icon: Icons.public_rounded,
              title: 'Download KML',
              subtitle: widget.parcels.isNotEmpty
                  ? 'Parcel boundaries, numbered stop pins and the driven '
                      'roads. Opens in Google Earth and imports into My Maps.'
                  : 'Numbered stop pins plus the driven roads. Opens in '
                      'Google Earth and imports into My Maps.',
              onTap: () => _run(
                'kml',
                () => _save(
                  RouteExportService.buildKml(
                    route,
                    name: '${widget.baseName} route',
                    parcels: widget.parcels,
                  ),
                  'kml',
                  'application/vnd.google-earth.kml+xml',
                  'Google Earth (KML)',
                ),
              ),
            ),
            _tile(
              action: 'kml-points',
              icon: Icons.pin_drop_rounded,
              title: 'Download KML — stops only',
              subtitle:
                  'Just the numbered delivery points, without the road geometry.',
              onTap: () => _run(
                'kml-points',
                () => _save(
                  RouteExportService.buildKml(
                    route,
                    name: '${widget.baseName} stops',
                    includeRoadPath: false,
                  ),
                  'kml',
                  'application/vnd.google-earth.kml+xml',
                  'Google Earth (KML)',
                ),
              ),
            ),
            _tile(
              action: 'gpx',
              icon: Icons.navigation_rounded,
              title: 'Download GPX',
              subtitle: 'Waypoints and track for a handheld or in-cab unit.',
              onTap: () => _run(
                'gpx',
                () => _save(
                  RouteExportService.buildGpx(
                    route,
                    name: '${widget.baseName} route',
                  ),
                  'gpx',
                  'application/gpx+xml',
                  'GPS exchange (GPX)',
                ),
              ),
            ),

            const SizedBox(height: 14),
            _sectionLabel(context, 'Navigation'),
            if (mapsUrls.isEmpty)
              _tile(
                action: 'maps',
                icon: Icons.map_outlined,
                title: 'Open in Google Maps',
                subtitle: 'Needs at least two geocoded stops.',
                enabled: false,
                onTap: () async {},
              )
            else ...[
              for (var i = 0; i < mapsUrls.length; i++)
                _tile(
                  action: 'maps-$i',
                  icon: Icons.map_rounded,
                  title: mapsUrls.length == 1
                      ? 'Open in Google Maps'
                      : 'Open in Google Maps — part ${i + 1} of ${mapsUrls.length}',
                  subtitle: mapsUrls.length == 1
                      ? 'Turn-by-turn directions through every stop.'
                      : 'Google Maps takes 25 points per link, so the run '
                          'opens in ${mapsUrls.length} parts.',
                  onTap: () => _run('maps-$i', () async {
                    final uri = Uri.parse(mapsUrls[i]);
                    final ok = await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                    if (!ok) throw Exception('could not open Google Maps');
                    return 'Opened Google Maps';
                  }),
                ),
              _tile(
                action: 'maps-copy',
                icon: Icons.link_rounded,
                title: 'Copy directions link${mapsUrls.length > 1 ? 's' : ''}',
                subtitle: 'Send it to the driver to open on their phone.',
                onTap: () => _run('maps-copy', () async {
                  await Clipboard.setData(
                      ClipboardData(text: mapsUrls.join('\n')));
                  return 'Link${mapsUrls.length > 1 ? 's' : ''} copied';
                }),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).hintColor,
              ),
        ),
      );

  Widget _tile({
    required String action,
    required IconData icon,
    required String title,
    required String subtitle,
    required Future<void> Function() onTap,
    bool enabled = true,
  }) {
    final busy = _busyAction == action;
    final blocked = !enabled || (_busyAction != null && !busy);

    return Opacity(
      opacity: blocked ? 0.45 : 1,
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Theme.of(context).dividerColor),
        ),
        child: ListTile(
          onTap: blocked ? null : onTap,
          leading: busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                )
              : Icon(icon, color: GeocodeColors.brand),
          title: Text(title,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
          trailing: const Icon(Icons.chevron_right, size: 20),
        ),
      ),
    );
  }

  Widget _warningBanner(String message) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: GeocodeColors.warning.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: GeocodeColors.warning.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded,
                size: 18, color: GeocodeColors.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message,
                  style: const TextStyle(fontSize: 12, height: 1.35)),
            ),
          ],
        ),
      );
}
