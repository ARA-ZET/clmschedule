import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/work_suburb.dart';
import '../../shareable_maps/providers/map_gesture_provider.dart';
import '../../shareable_maps/services/map_bitmap_cache.dart';
import '../../utils/route_marker_icons.dart';
import '../models/letterbox_suburb.dart';
import '../providers/letterbox_provider.dart';
import '../widgets/letterbox_folder_picker.dart';
import '../../shareable_maps/widgets/map_overlay.dart';
import '../theme/letterbox_theme.dart';
import '../utils/letterbox_clusters.dart';
import '../widgets/letterbox_suburb_list.dart';

/// Where a seed's waypoints come from.
enum _SeedSource { cloud, device }

/// How much of the suburb a seed replaces.
enum _SeedScope { wholeSuburb, drawnArea }

/// Curate one suburb's letterbox positions.
///
/// Left: the 613 suburbs with their curation status. Right: a map of the
/// selected suburb's boundary and its letterboxes, with the bulk tools that
/// make a ~1 500-point suburb workable — lasso delete above all.
class LetterboxCurationPage extends riverpod.ConsumerStatefulWidget {
  const LetterboxCurationPage({super.key});

  @override
  riverpod.ConsumerState<LetterboxCurationPage> createState() =>
      _LetterboxCurationPageState();
}

class _LetterboxCurationPageState
    extends riverpod.ConsumerState<LetterboxCurationPage> {
  final LetterboxProvider _provider = LetterboxProvider();
  final MapBitmapCache _bitmaps = MapBitmapCache.instance;
  GoogleMapController? _map;

  @override
  void initState() {
    super.initState();
    _provider.addListener(_onProviderChanged);
    _provider.loadCatalogue();
    _bitmaps.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _provider.removeListener(_onProviderChanged);
    _provider.dispose();
    super.dispose();
  }

  // ── Stable map sets ──────────────────────────────────────────────────
  // GoogleMap.didUpdateWidget compares its polygon/marker Sets by IDENTITY, so
  // handing it a freshly-built Set every rebuild forces a full re-diff of every
  // polygon and marker across the JS bridge. With 613 suburb outlines and a
  // few thousand letterboxes that is the difference between a smooth map and
  // an unusable one — and a rebuild fires on every provider notify, including
  // the mouse simply moving over a panel.
  //
  // So the sets are cached and only rebuilt when something that actually
  // affects them changes. Same trick as shareable_map_editor.dart.
  Set<Polygon>? _stablePolygons;
  String? _stablePolygonsKey;
  Set<Marker>? _stableMarkers;
  String? _stableMarkersKey;

  /// Numbered pins for apartment blocks, keyed by box count. Rasterising a
  /// glyph is not free, so distinct counts are rendered once and reused —
  /// a suburb typically has only a handful of distinct block sizes.
  final Map<int, BitmapDescriptor> _blockIcons = {};
  String _blockIconsKey = '';

  /// Set once the camera has been framed to real data. Without this the map
  /// opens fitted to nothing: onMapCreated fires before the 613 suburbs have
  /// loaded, so the initial fit had no bounds to work with and the view stayed
  /// zoomed out over half the province.
  bool _framed = false;

  void _onProviderChanged() {
    if (!mounted) return;
    setState(() {});
    if (!_framed &&
        _provider.selected == null &&
        _provider.suburbs.isNotEmpty &&
        _map != null) {
      _framed = true;
      _fitAllSuburbs();
    }
  }

  Future<void> _openSuburb(WorkSuburb suburb) async {
    if (_provider.isDirty && !await _confirmDiscard()) return;
    await _provider.selectSuburb(suburb);
    final bounds = _boundsOf(suburb.polygonPoints);
    if (bounds != null) {
      await _map?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 48));
    }
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showMapDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        content: Text(
          'You have unsaved edits to '
          '${_provider.selected?.name ?? 'this suburb'}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _seed() async {
    final suburb = _provider.selected;
    if (suburb == null) return;

    // An outlined area makes the scope ambiguous, so ask rather than guess:
    // re-seeding the whole suburb would throw away curation everywhere else.
    final hasArea = _provider.lassoPoints.length >= 3;
    var scope = _SeedScope.wholeSuburb;
    if (hasArea) {
      final chosen = await _askSeedScope(suburb.name);
      if (chosen == null || !mounted) return;
      scope = chosen;
    }

    if (scope == _SeedScope.drawnArea) {
      await _replaceArea();
      return;
    }

    if (_provider.points.isNotEmpty) {
      final ok = await showMapDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Replace every letterbox in this suburb?'),
          content: Text(
            'Seeding rebuilds ${suburb.name} from GPS drops. All '
            '${formatCount(_provider.points.length)} letterbox(es) currently '
            'loaded are removed and replaced — including anything you have '
            'corrected by hand.\n\n'
            'To re-survey only part of the suburb, cancel, outline it with the '
            'Area tool, and use Replace inside.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace all'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    if (!mounted) return;
    final source = await _askSeedSource(title: 'Seed ${suburb.name} from…');
    if (source == null || !mounted) return;

    if (source == _SeedSource.device) {
      final files = await _pickGpxFiles();
      if (files == null || files.isEmpty) return;
      await _provider.seedFromDeviceFiles(files);
      // The files turned out to hold only a walked path. Offer to use it
      // rather than leaving an empty map and no way forward.
      if (mounted && _provider.lastUploadWasTracksOnly) {
        if (await _confirmTrackPoints()) {
          await _provider.seedFromDeviceFiles(files, includeTrackPoints: true);
        }
      }
      return;
    }

    final folders = await showMapDialog<List<String>>(
      context: context,
      builder: (_) => LetterboxFolderPicker(provider: _provider),
    );
    if (folders == null || folders.isEmpty) return;
    await _provider.seedFrom(folders);
  }

  /// Whole suburb, or just the outlined area? Only asked when an area is drawn.
  Future<_SeedScope?> _askSeedScope(String suburbName) {
    return showMapDialog<_SeedScope>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Seed which part?'),
        children: [
          ListTile(
            leading: const Icon(Icons.highlight_alt),
            title: const Text('Just the outlined area'),
            subtitle: const Text(
                'Replaces letterboxes inside it, keeps the rest of the suburb'),
            onTap: () => Navigator.pop(ctx, _SeedScope.drawnArea),
          ),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: Text('All of $suburbName'),
            subtitle: const Text(
                'Replaces every letterbox in the suburb, including hand edits'),
            onTap: () => Navigator.pop(ctx, _SeedScope.wholeSuburb),
          ),
        ],
      ),
    );
  }

  /// The upload held only a walked path. Confirm before treating every track
  /// point as a letterbox — for most exports that would be badly wrong, but for
  /// some devices it is exactly how deliveries are recorded.
  Future<bool> _confirmTrackPoints() async {
    final ok = await showMapDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use track points as letterboxes?'),
        content: const Text(
          'Those files contain no waypoints — only a recorded track.\n\n'
          'On most devices a track is the path walked between deliveries, so '
          'treating every point as a letterbox would massively overcount. '
          'Only do this if your device records each delivery as a track '
          'point.\n\n'
          'Points closer together than about 5 m are merged either way, but '
          'that will not rescue a continuously-recorded walking path.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Use track points'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Ask where the waypoints should come from. Returns null if cancelled.
  Future<_SeedSource?> _askSeedSource({required String title}) {
    return showMapDialog<_SeedSource>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('Cloud folders'),
            subtitle: const Text(
                'Compiled waypoints already uploaded to Distribution/'),
            onTap: () => Navigator.pop(ctx, _SeedSource.cloud),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Upload GPX from this device'),
            subtitle: const Text('Pick .gpx files from your computer'),
            onTap: () => Navigator.pop(ctx, _SeedSource.device),
          ),
        ],
      ),
    );
  }

  /// Pick .gpx files off the device. Returns null if cancelled or empty.
  Future<List<Uint8List>?> _pickGpxFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowMultiple: true,
      allowedExtensions: ['gpx'],
      // Required on web, where there is no readable file path.
      withData: true,
    );
    if (result == null) return null;

    final files = <Uint8List>[
      for (final f in result.files)
        if (f.bytes != null) f.bytes!,
    ];
    if (files.isEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read those files.')),
      );
      return null;
    }
    return files;
  }

  /// Replace the letterboxes inside the drawn area with a fresh survey,
  /// leaving the rest of the suburb alone.
  /// Replace the letterboxes inside the drawn area, across every suburb it
  /// overlaps, leaving everything outside the polygon alone.
  Future<void> _replaceArea() async {
    final area = _provider.lassoPoints;
    if (area.length < 3) return;

    // Unsaved edits in the open suburb would be overwritten by the pass, which
    // writes each affected suburb straight to storage.
    if (_provider.isDirty && !await _confirmDiscard()) return;
    if (!mounted) return;

    final affected = _provider.suburbsOverlapping(area);
    if (affected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That area does not overlap any suburb.')),
      );
      return;
    }

    final verified = affected
        .where(
            (s) => _provider.statusOf(s.id) == LetterboxSuburbStatus.verified)
        .toList();

    final ok = await showMapDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(affected.length == 1
            ? 'Replace this area in ${affected.first.name}?'
            : 'Replace this area across ${affected.length} suburbs?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Letterboxes inside the outline are replaced by the new survey. '
              'Each one stays with the suburb that contains it, and anything '
              'outside the outline is untouched.',
            ),
            const SizedBox(height: LetterboxTheme.s3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: Text(
                  affected.map((s) => s.name).join('\n'),
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ),
            ),
            if (verified.isNotEmpty) ...[
              const SizedBox(height: LetterboxTheme.s3),
              Container(
                padding: const EdgeInsets.all(LetterboxTheme.s2 + 2),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.errorContainer,
                  borderRadius:
                      BorderRadius.circular(LetterboxTheme.radiusSmall),
                ),
                child: Text(
                  '${verified.length} of these are already verified '
                  '(${verified.map((s) => s.name).join(', ')}). They stay '
                  'marked verified, so re-check them afterwards.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final source = await _askSeedSource(title: 'Replace this area from…');
    if (source == null || !mounted) return;

    if (source == _SeedSource.device) {
      final files = await _pickGpxFiles();
      if (files == null || files.isEmpty) return;
      await _provider.replaceAreaFromDeviceFiles(area, files);
      if (mounted && _provider.lastUploadWasTracksOnly) {
        if (await _confirmTrackPoints()) {
          await _provider.replaceAreaFromDeviceFiles(area, files,
              includeTrackPoints: true);
        }
      }
    } else {
      final folders = await showMapDialog<List<String>>(
        context: context,
        builder: (_) => LetterboxFolderPicker(provider: _provider),
      );
      if (folders == null || folders.isEmpty) return;
      await _provider.replaceAreaFromFolders(area, folders);
    }

    // The area has served its purpose; clear it so the map is readable again.
    if (mounted) _provider.cancelLasso();
  }

  /// Seed every suburb at once, from cloud folders or device files.
  Future<void> _seedAll() async {
    if (_provider.isDirty && !await _confirmDiscard()) return;
    if (!mounted) return;

    final source = await _askSeedSource(title: 'Seed all suburbs from…');
    if (source == null || !mounted) return;

    List<String>? folders;
    List<Uint8List>? files;

    if (source == _SeedSource.device) {
      files = await _pickGpxFiles();
      if (files == null || files.isEmpty) return;
    } else {
      folders = await showMapDialog<List<String>>(
        context: context,
        builder: (_) => LetterboxFolderPicker(provider: _provider),
      );
      if (folders == null || folders.isEmpty) return;
    }
    if (!mounted) return;

    final sourceLine = files != null
        ? 'This reads ${files.length} GPX file(s) from your device'
        : 'This reads ${folders!.length} cloud folder(s)';

    final ok = await showMapDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Seed all suburbs?'),
        content: Text(
          '$sourceLine and rebuilds candidate letterboxes for every suburb '
          'they cover.\n\n'
          'Suburbs already marked verified are never overwritten — they are '
          'flagged for review instead.\n\n'
          'A large selection will take a while and use a lot of memory in the '
          'browser.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Seed all'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    if (files != null) {
      await _provider.seedAllFromDeviceFiles(files);
      if (mounted && _provider.lastUploadWasTracksOnly) {
        if (await _confirmTrackPoints()) {
          await _provider.seedAllFromDeviceFiles(files,
              includeTrackPoints: true);
        }
      }
    } else {
      await _provider.seedAllSuburbs(folders!);
    }
  }

  Future<void> _save({required bool verify}) async {
    if (verify) {
      final ok = await showMapDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Mark as verified?'),
          content: Text(
            'This marks ${_provider.selected?.name} as curated and signed '
            'off. Its ${_provider.count} letterboxes become the trusted '
            'number used for quoting and for reviewing distributor '
            'performance.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mark verified'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _provider.save(markVerified: verify);
  }

  static LatLngBounds? _boundsOf(List<LatLng> points) {
    if (points.isEmpty) return null;
    var minLat = points.first.latitude, maxLat = points.first.latitude;
    var minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  @override
  Widget build(BuildContext context) {
    final suburb = _provider.selected;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: LetterboxTheme.s4,
        title: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius:
                    BorderRadius.circular(LetterboxTheme.radiusSmall - 2),
              ),
              child: Icon(Icons.markunread_mailbox_outlined,
                  size: 17,
                  color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: LetterboxTheme.s3),
            const Text('Letterbox Index'),
          ],
        ),
        actions: [
          _AppBarChip(
            icon: _provider.showLetterboxes
                ? Icons.markunread_mailbox_outlined
                : Icons.visibility_off_outlined,
            label: _provider.count == 0
                ? 'Letterboxes'
                : 'Letterboxes ${formatCount(_provider.count)}',
            selected: _provider.showLetterboxes,
            onTap: () =>
                _provider.setShowLetterboxes(!_provider.showLetterboxes),
          ),
          const SizedBox(width: LetterboxTheme.s2),
          if (_provider.unmatchedTotal > 0) ...[
            _AppBarChip(
              icon: Icons.report_gmailerrorred_outlined,
              label: 'Outside suburbs '
                  '${formatCount(_provider.unmatchedTotal)}',
              selected: _provider.showUnmatched,
              onTap: () => _provider.setShowUnmatched(!_provider.showUnmatched),
            ),
            const SizedBox(width: LetterboxTheme.s2),
          ],
          _AppBarChip(
            icon: Icons.layers_outlined,
            label: 'All suburbs',
            selected: _provider.showAllSuburbs,
            onTap: () => _provider.setShowAllSuburbs(!_provider.showAllSuburbs),
          ),
          const SizedBox(width: LetterboxTheme.s2),
          IconButton(
            tooltip: 'Zoom to fit every suburb',
            icon: const Icon(Icons.fit_screen_outlined, size: 20),
            onPressed: _fitAllSuburbs,
          ),
          const SizedBox(width: LetterboxTheme.s2),
          FilledButton.tonalIcon(
            onPressed: _provider.isBusy ? null : _seedAll,
            icon: const Icon(Icons.auto_awesome_outlined, size: 18),
            label: const Text('Seed all'),
          ),
          const SizedBox(width: LetterboxTheme.s4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
            height: 1,
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withValues(alpha: 0.5),
          ),
        ),
      ),
      body: Row(
        children: [
          SizedBox(
            width: 316,
            child: LetterboxSuburbList(
              provider: _provider,
              onSelect: _openSuburb,
            ),
          ),
          VerticalDivider(
            width: 1,
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withValues(alpha: 0.5),
          ),
          Expanded(
            child: Column(
              children: [
                // The map is always shown — with no suburb selected it is the
                // city-wide view of all 613 boundaries, which is how you pick
                // one and how you see curation progress.
                if (suburb != null)
                  _Toolbar(
                    provider: _provider,
                    onSeed: _seed,
                    onSave: () => _save(verify: false),
                    onVerify: () => _save(verify: true),
                  )
                else
                  _PickPrompt(
                    provider: _provider,
                    onReplaceArea: _replaceArea,
                  ),
                if (_provider.statusMessage != null)
                  _StatusBar(
                    message: _provider.statusMessage!,
                    onDismiss: _provider.clearStatus,
                    // Offered right where the "replaced across N suburbs"
                    // message lands, which is the moment you find out the
                    // replacement was not what you wanted.
                    onUndo: _provider.canUndoAreaReplace && !_provider.isBusy
                        ? _provider.undoAreaReplace
                        : null,
                  ),
                Expanded(child: _buildMap(suburb)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMap(WorkSuburb? suburb) {
    final icon = _bitmaps.waypoint ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);

    final groups = _provider.groups;
    if (_provider.showLetterboxes && _provider.showApartments) {
      // Deferred: this rasterises glyphs and calls setState when they land, so
      // firing it directly from build would setState during a build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureBlockIcons(groups.blocks);
      });
    }

    final markerKey = 'p:${_provider.pointsVersion}'
        '|i:${_bitmaps.waypoint != null}'
        '|m:${_provider.measurePoints.length}'
        '|show:${_provider.showLetterboxes}'
        '|h:${_provider.showHouses}|a:${_provider.showApartments}'
        '|bi:$_blockIconsKey:${_blockIcons.length}'
        '|un:${_provider.unmatchedVersion}:${_provider.showUnmatched}';

    Set<Marker> markers;
    if (markerKey == _stableMarkersKey && _stableMarkers != null) {
      markers = _stableMarkers!;
    } else {
      // Houses get a pin each; a block gets ONE pin carrying its box count, so
      // a bank of twelve reads as "12" rather than twelve overlapping dots.
      final showBoxes = _provider.showLetterboxes;
      final houses =
          showBoxes && _provider.showHouses ? groups.houses : const <LatLng>[];
      final blocks = showBoxes && _provider.showApartments
          ? groups.blocks
          : const <LetterboxBlock>[];
      final measure = _provider.measurePoints;
      markers = <Marker>{
        for (var i = 0; i < houses.length; i++)
          Marker(
            markerId: MarkerId('lb_$i'),
            position: houses[i],
            icon: icon,
            anchor: const Offset(0.5, 0.5),
            consumeTapEvents: false,
          ),
        for (var i = 0; i < blocks.length; i++)
          Marker(
            markerId: MarkerId('blk_$i'),
            position: blocks[i].centre,
            icon: _blockIcons[blocks[i].count] ??
                BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueViolet),
            infoWindow: InfoWindow(
              title: '${blocks[i].count} letterboxes',
              snippet: 'Apartment block',
            ),
          ),
        // Drops that landed outside every suburb, in red. Capped: a large
        // file can leave tens of thousands, and the point is to see WHERE the
        // gaps are, which a few thousand shows just as well as all of them.
        if (_provider.showUnmatched)
          for (var i = 0; i < _provider.unmatchedPoints.length && i < 2000; i++)
            Marker(
              markerId: MarkerId('un_$i'),
              position: _provider.unmatchedPoints[i],
              icon: BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueRed),
              anchor: const Offset(0.5, 0.5),
              consumeTapEvents: false,
            ),
        // Vertex handles, so a half-drawn area is visible before it closes.
        for (var i = 0; i < measure.length; i++)
          Marker(
            markerId: MarkerId('measure_v$i'),
            position: measure[i],
            icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueAzure),
            anchor: const Offset(0.5, 0.5),
          ),
      };
      _stableMarkers = markers;
      _stableMarkersKey = markerKey;
    }

    // 613 outlines: only rebuild them when something they depend on moves.
    final polyKey = 'all:${_provider.showAllSuburbs}'
        '|sel:${suburb?.id ?? ''}'
        '|meta:${_provider.metaVersion}'
        '|subs:${_provider.suburbs.length}'
        '|tool:${_provider.tool.index}'
        '|lasso:${_provider.lassoPoints.length}'
        '|meas:${_provider.measurePoints.length}';

    Set<Polygon> polygons;
    if (polyKey == _stablePolygonsKey && _stablePolygons != null) {
      polygons = _stablePolygons!;
    } else {
      polygons = <Polygon>{};

      // Context: every other suburb, shaded by curation status and tappable so
      // the map itself is a picker. Whole set is ~14 800 vertices, so drawing
      // them all costs nothing — rebuilding them every frame does not.
      if (_provider.showAllSuburbs) {
        for (final s in _provider.suburbs) {
          if (s.id == suburb?.id) continue;
          final colour = statusColour(_provider.statusOf(s.id));
          polygons.add(Polygon(
            polygonId: PolygonId('ctx_${s.id}'),
            points: s.polygonPoints,
            strokeColor: colour.withValues(alpha: 0.55),
            strokeWidth: 1,
            fillColor: colour.withValues(alpha: 0.10),
            // While drawing or lassoing, taps belong to the tool, not the
            // picker.
            consumeTapEvents: _provider.tool == LetterboxTool.browse,
            onTap: _provider.tool == LetterboxTool.browse
                ? () {
                    // Guard: a click on a panel sitting over this polygon
                    // would otherwise also open the suburb underneath it.
                    if (ref.read(mapGestureRiverpod).isHeld) return;
                    _openSuburb(s);
                  }
                : null,
          ));
        }
      }

      // The suburb being edited, drawn last so it sits above the context.
      if (suburb != null) {
        polygons.add(Polygon(
          polygonId: PolygonId('suburb_${suburb.id}'),
          points: suburb.polygonPoints,
          strokeColor: Theme.of(context).colorScheme.primary,
          strokeWidth: 3,
          fillColor:
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.07),
        ));
      }

      if (_provider.lassoPoints.length >= 3) {
        polygons.add(Polygon(
          polygonId: const PolygonId('lasso'),
          points: _provider.lassoPoints,
          strokeColor: Colors.redAccent,
          strokeWidth: 2,
          fillColor: Colors.redAccent.withValues(alpha: 0.15),
        ));
      }

      if (_provider.measurePoints.length >= 3) {
        polygons.add(Polygon(
          polygonId: const PolygonId('measure'),
          points: _provider.measurePoints,
          strokeColor: Colors.blue,
          strokeWidth: 3,
          fillColor: Colors.blue.withValues(alpha: 0.12),
        ));
      }

      _stablePolygons = polygons;
      _stablePolygonsKey = polyKey;
    }

    final polylines = <Polyline>{
      if (_provider.lassoPoints.length == 2)
        Polyline(
          polylineId: const PolylineId('lasso_line'),
          points: _provider.lassoPoints,
          color: Colors.redAccent,
          width: 2,
        ),
      if (_provider.measurePoints.length == 2)
        Polyline(
          polylineId: const PolylineId('measure_line'),
          points: _provider.measurePoints,
          color: Colors.blue,
          width: 3,
        ),
    };

    // Cape Town, so the all-suburbs view opens somewhere useful.
    final centre = suburb?.polygonPoints.first ?? const LatLng(-33.95, 18.55);

    return Stack(
      children: [
        // Scoped Consumer, not a top-level ref.watch: gesture handling flips
        // on every mouse enter/exit of a panel, and watching it in the page's
        // build rebuilt the sidebar and toolbar too — hundreds of widgets, many
        // times a second, just from moving the cursor.
        riverpod.Consumer(
          builder: (context, ref, _) => GoogleMap(
            initialCameraPosition: CameraPosition(
              target: centre,
              zoom: suburb == null ? 10 : 14,
            ),
            onMapCreated: (c) {
              _map = c;
              final target = suburb?.polygonPoints ?? _allSuburbPoints();
              final bounds = _boundsOf(target);
              if (bounds != null) {
                _framed = true;
                c.animateCamera(CameraUpdate.newLatLngBounds(bounds, 48));
              }
            },
            // The map is an HTML element on web and swallows gestures meant for
            // Flutter widgets drawn over it. The only reliable fix is to switch
            // its own gesture handling off while the pointer is over an overlay
            // — see _mapOverlay below, and the same pattern in
            // shareable_map_editor.dart. Tap/gesture detectors on the overlays
            // do not work; the platform view still consumes the event.
            webGestureHandling: ref.watch(mapGestureRiverpod).gestureHandling,
            onTap: (position) {
              // A click that began on an overlay can still reach the map
              // underneath. A held map means the pointer is over UI (or a
              // dialog is open), so this tap is not for the map.
              if (ref.read(mapGestureRiverpod).isHeld) return;
              _provider.handleMapTap(position);
            },
            markers: markers,
            polygons: polygons,
            polylines: polylines,
            myLocationButtonEnabled: false,
            mapToolbarEnabled: false,
            zoomControlsEnabled: true,
          ),
        ),
        Positioned(
          right: 12,
          top: 12,
          child: _mapOverlay(_MapLegend(provider: _provider)),
        ),
        if (_provider.isBusy)
          Positioned.fill(
            child: _mapOverlay(
              const ColoredBox(
                color: Color(0x33000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          ),
        // Hidden letterboxes must never look like missing ones.
        if (!_provider.showLetterboxes && _provider.count > 0)
          Positioned(
            left: 12,
            top: 12,
            child: _mapOverlay(
              _HiddenNotice(
                count: _provider.count,
                onShow: () => _provider.setShowLetterboxes(true),
              ),
            ),
          ),
        if (_provider.tool == LetterboxTool.lassoDelete)
          Positioned(
            left: 12,
            bottom: 12,
            child: _mapOverlay(_LassoControls(
              provider: _provider,
              onReplace: _replaceArea,
            )),
          ),
        if (_provider.tool == LetterboxTool.measure)
          Positioned(
            left: 12,
            bottom: 12,
            child: _mapOverlay(_MeasurePanel(provider: _provider)),
          ),
      ],
    );
  }

  /// Wrap a widget that sits on top of the map. See [MapOverlay].
  Widget _mapOverlay(Widget child) => MapOverlay(child: child);

  /// Rasterise a numbered pin for each distinct block size on screen.
  Future<void> _ensureBlockIcons(List<LetterboxBlock> blocks) async {
    final counts = blocks.map((b) => b.count).toSet().toList()..sort();
    final key = counts.join(',');
    if (key == _blockIconsKey) return;
    _blockIconsKey = key;

    for (final count in counts) {
      if (_blockIcons.containsKey(count)) continue;
      _blockIcons[count] = await RouteMarkerIcons.numbered(
        '$count',
        color: LetterboxTheme.apartment,
      );
    }
    if (mounted) setState(() {});
  }

  /// Every vertex of every suburb, for framing the city-wide view.
  List<LatLng> _allSuburbPoints() =>
      _provider.suburbs.expand((s) => s.polygonPoints).toList();

  Future<void> _fitAllSuburbs() async {
    final bounds = _boundsOf(_allSuburbPoints());
    if (bounds != null) {
      await _map?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 48));
    }
  }
}

// ── Small pieces ───────────────────────────────────────────────────────

/// Shown when no suburb is open. Still offers the test-area tool, because
/// "how many letterboxes are in this shape?" is a question you ask across
/// suburb boundaries, not inside one.
class _PickPrompt extends StatelessWidget {
  final LetterboxProvider provider;
  final VoidCallback onReplaceArea;

  const _PickPrompt({required this.provider, required this.onReplaceArea});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tool = provider.tool;
    final measuring = tool == LetterboxTool.measure;
    final outlining = tool == LetterboxTool.lassoDelete;

    final message = measuring
        ? 'Tap points on the map to outline an area — its letterbox count '
            'appears as soon as it closes.'
        : outlining
            ? 'Outline an area, then Replace inside. It can span suburbs: each '
                'letterbox stays with the suburb that contains it.'
            : 'Tap a suburb on the map, or pick one from the list, to start '
                'curating its letterboxes.';

    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(LetterboxTheme.s4, LetterboxTheme.s3,
          LetterboxTheme.s4, LetterboxTheme.s3),
      child: Row(
        children: [
          Icon(
            measuring
                ? Icons.straighten
                : outlining
                    ? Icons.highlight_alt
                    : Icons.touch_app_outlined,
            size: 17,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: LetterboxTheme.s2 + 2),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: LetterboxTheme.s3),
          if (outlining && provider.lassoPoints.length >= 3) ...[
            OutlinedButton.icon(
              onPressed: provider.isBusy ? null : onReplaceArea,
              icon: const Icon(Icons.sync_alt_rounded, size: 17),
              label: const Text('Replace inside'),
            ),
            const SizedBox(width: LetterboxTheme.s2),
          ],
          // Available with no suburb open: the polygon defines the scope, so
          // an area spanning several suburbs does not need one picked first.
          _AppBarChip(
            icon: Icons.highlight_alt,
            label: 'Area',
            selected: outlining,
            onTap: () => provider.setTool(
              outlining ? LetterboxTool.browse : LetterboxTool.lassoDelete,
            ),
          ),
          const SizedBox(width: LetterboxTheme.s2),
          _AppBarChip(
            icon: Icons.straighten,
            label: 'Test area',
            selected: measuring,
            onTap: () => provider.setTool(
              measuring ? LetterboxTool.browse : LetterboxTool.measure,
            ),
          ),
        ],
      ),
    );
  }
}

/// Colour key for the all-suburbs overlay. The on/off toggle lives in the app
/// bar; this is only the legend, so it disappears with the overlay it explains.
class _MapLegend extends StatelessWidget {
  final LetterboxProvider provider;

  const _MapLegend({required this.provider});

  @override
  Widget build(BuildContext context) {
    if (!provider.showAllSuburbs) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return _FloatingPanel(
      padding: const EdgeInsets.symmetric(
          horizontal: LetterboxTheme.s3, vertical: LetterboxTheme.s2 + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final status in LetterboxSuburbStatus.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: statusColour(status),
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                  const SizedBox(width: LetterboxTheme.s2),
                  Text(
                    statusLabel(status),
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: LetterboxTheme.s3),
                  Text(
                    '${_countWith(provider, status)}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static int _countWith(LetterboxProvider p, LetterboxSuburbStatus status) =>
      p.statusCounts[status] ?? 0;
}

/// Compact toggle for the app bar. A Switch is too tall and a FilterChip too
/// loud next to a filled button, so this is a quiet pill that reads as on/off.
class _AppBarChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _AppBarChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(LetterboxTheme.radiusSmall),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LetterboxTheme.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: LetterboxTheme.s3, vertical: LetterboxTheme.s2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 17,
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant),
              const SizedBox(width: LetterboxTheme.s2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A panel that floats over the map. Surface tint alone cannot separate a card
/// from map imagery, so these get a real shadow.
class _FloatingPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const _FloatingPanel({
    required this.child,
    this.padding = const EdgeInsets.all(LetterboxTheme.s3),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(LetterboxTheme.radius),
        boxShadow: LetterboxTheme.floatingShadow,
      ),
      padding: padding,
      child: child,
    );
  }
}

/// Inline result/error line under the toolbar. Errors get the error container;
/// everything else stays quiet so a routine confirmation does not look alarming.
class _StatusBar extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  /// Roll back the last area replacement. Null unless one is undoable — the
  /// record lives in memory, so it is gone after a reload.
  final VoidCallback? onUndo;

  const _StatusBar({
    required this.message,
    required this.onDismiss,
    this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isProblem = message.contains('failed') ||
        message.contains('MISMATCH') ||
        message.contains('Could not') ||
        message.contains('no waypoints') ||
        message.contains('nothing to seed');

    return Container(
      width: double.infinity,
      color: isProblem ? scheme.errorContainer : scheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(LetterboxTheme.s4,
          LetterboxTheme.s2 + 2, LetterboxTheme.s2, LetterboxTheme.s2 + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isProblem
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
            size: 17,
            color: isProblem ? scheme.onErrorContainer : scheme.primary,
          ),
          const SizedBox(width: LetterboxTheme.s2 + 2),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: isProblem ? scheme.onErrorContainer : scheme.onSurface,
              ),
            ),
          ),
          if (onUndo != null)
            TextButton.icon(
              onPressed: onUndo,
              icon: const Icon(Icons.undo_rounded, size: 16),
              label: const Text('Undo replace'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12.5),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 17),
            onPressed: onDismiss,
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Controls for the area tool: delete what is inside, or replace it from a
/// fresh survey.
class _LassoControls extends StatelessWidget {
  final LetterboxProvider provider;
  final VoidCallback onReplace;

  const _LassoControls({required this.provider, required this.onReplace});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = provider.lassoPoints.length;
    final ready = n >= 3;

    return _FloatingPanel(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.highlight_alt, size: 17, color: scheme.primary),
          const SizedBox(width: LetterboxTheme.s2),
          Text(
            ready ? '$n points' : 'Tap ${3 - n} more point(s)',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: LetterboxTheme.s3),
          TextButton(
            onPressed: n == 0 ? null : provider.undoLassoPoint,
            child: const Text('Undo'),
          ),
          TextButton(
            onPressed: n == 0 ? null : provider.cancelLasso,
            child: const Text('Cancel'),
          ),
          const SizedBox(width: LetterboxTheme.s1),
          OutlinedButton.icon(
            onPressed: !ready || provider.isBusy ? null : onReplace,
            icon: const Icon(Icons.sync_alt_rounded, size: 17),
            label: const Text('Replace inside'),
          ),
          const SizedBox(width: LetterboxTheme.s2),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
              padding: const EdgeInsets.symmetric(
                  horizontal: LetterboxTheme.s3, vertical: LetterboxTheme.s2),
            ),
            onPressed: !ready ? null : provider.applyLassoDelete,
            icon: const Icon(Icons.delete_outline, size: 17),
            label: const Text('Delete inside'),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final LetterboxProvider provider;
  final VoidCallback onSeed;
  final VoidCallback onSave;
  final VoidCallback onVerify;

  const _Toolbar({
    required this.provider,
    required this.onSeed,
    required this.onSave,
    required this.onVerify,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = provider.isBusy;
    final suburb = provider.selected;
    final status = suburb == null ? null : provider.statusOf(suburb.id);
    final hint = _hintFor(provider.tool);

    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(LetterboxTheme.s4, LetterboxTheme.s3,
          LetterboxTheme.s4, LetterboxTheme.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        suburb?.name ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: LetterboxTheme.s3),
                    _CountPill(
                      breakdown: provider.breakdown,
                      dirty: provider.isDirty,
                      status: status,
                      showHouses: provider.showHouses,
                      showApartments: provider.showApartments,
                      onToggleHouses: () =>
                          provider.setShowHouses(!provider.showHouses),
                      onToggleApartments: () =>
                          provider.setShowApartments(!provider.showApartments),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: LetterboxTheme.s3),
              OutlinedButton.icon(
                onPressed: busy ? null : onSeed,
                icon: const Icon(Icons.download_outlined, size: 17),
                label: const Text('Seed'),
              ),
              const SizedBox(width: LetterboxTheme.s2),
              OutlinedButton.icon(
                onPressed: busy ? null : provider.verifyRoundTrip,
                icon: const Icon(Icons.fact_check_outlined, size: 17),
                label: const Text('Check'),
              ),
              const SizedBox(width: LetterboxTheme.s2),
              FilledButton.icon(
                onPressed: busy ? null : onSave,
                icon: const Icon(Icons.save_outlined, size: 17),
                label: const Text('Save'),
              ),
              const SizedBox(width: LetterboxTheme.s2),
              if (status == LetterboxSuburbStatus.verified)
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => provider.unverifySuburbs([provider.selected!.id]),
                  icon: const Icon(Icons.remove_moderator_outlined, size: 17),
                  label: const Text('Unverify'),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: busy || provider.isDirty ? null : onVerify,
                  icon: const Icon(Icons.verified_outlined, size: 17),
                  label: const Text('Verify'),
                ),
            ],
          ),
          const SizedBox(height: LetterboxTheme.s3),
          Row(
            children: [
              SegmentedButton<LetterboxTool>(
                segments: const [
                  ButtonSegment(
                    value: LetterboxTool.browse,
                    icon: Icon(Icons.pan_tool_alt_outlined, size: 16),
                    label: Text('Browse'),
                  ),
                  ButtonSegment(
                    value: LetterboxTool.add,
                    icon: Icon(Icons.add_location_alt_outlined, size: 16),
                    label: Text('Add'),
                  ),
                  ButtonSegment(
                    value: LetterboxTool.remove,
                    icon: Icon(Icons.wrong_location_outlined, size: 16),
                    label: Text('Remove'),
                  ),
                  ButtonSegment(
                    value: LetterboxTool.lassoDelete,
                    icon: Icon(Icons.highlight_alt, size: 16),
                    label: Text('Area'),
                  ),
                  ButtonSegment(
                    value: LetterboxTool.measure,
                    icon: Icon(Icons.straighten, size: 16),
                    label: Text('Test area'),
                  ),
                ],
                selected: {provider.tool},
                onSelectionChanged:
                    busy ? null : (sel) => provider.setTool(sel.first),
              ),
              const SizedBox(width: LetterboxTheme.s2),
              IconButton(
                onPressed: provider.canUndo ? provider.undo : null,
                icon: const Icon(Icons.undo_rounded, size: 19),
                tooltip: 'Undo',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                onPressed: provider.canRedo ? provider.redo : null,
                icon: const Icon(Icons.redo_rounded, size: 19),
                tooltip: 'Redo',
                visualDensity: VisualDensity.compact,
              ),
              if (hint != null) ...[
                const SizedBox(width: LetterboxTheme.s3),
                Icon(Icons.info_outline_rounded,
                    size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: LetterboxTheme.s1 + 2),
                Flexible(
                  child: Text(
                    hint,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// What the active tool does, in one line. Nothing for Browse — the default
  /// needs no explanation and a permanent hint would just be noise.
  static String? _hintFor(LetterboxTool tool) {
    switch (tool) {
      case LetterboxTool.browse:
        return null;
      case LetterboxTool.add:
        return 'Tap the map to add a letterbox';
      case LetterboxTool.remove:
        return 'Tap a letterbox to delete it';
      case LetterboxTool.lassoDelete:
        return 'Outline an area to delete or re-survey what is inside it';
      case LetterboxTool.measure:
        return 'Outline an area to count the letterboxes in it';
    }
  }
}

/// Count for the open suburb, split into houses and apartment boxes.
///
/// The split is the point: a block of flats is recorded as several boxes at one
/// entrance, so "1 200 letterboxes" can mean very different work depending on
/// how many of them are behind one door.
class _CountPill extends StatelessWidget {
  final LetterboxBreakdown breakdown;
  final bool dirty;
  final LetterboxSuburbStatus? status;
  final bool showHouses;
  final bool showApartments;
  final VoidCallback onToggleHouses;
  final VoidCallback onToggleApartments;

  const _CountPill({
    required this.breakdown,
    required this.dirty,
    required this.status,
    required this.showHouses,
    required this.showApartments,
    required this.onToggleHouses,
    required this.onToggleApartments,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colour = status == null ? scheme.outline : statusColour(status!);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: LetterboxTheme.s3, vertical: 5),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(LetterboxTheme.radiusSmall),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(color: colour, shape: BoxShape.circle),
              ),
              const SizedBox(width: LetterboxTheme.s2),
              Text(
                '${formatCount(breakdown.total)} letterboxes',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
        if (breakdown.total > 0) ...[
          const SizedBox(width: LetterboxTheme.s2),
          _SplitChip(
            icon: Icons.home_outlined,
            label: formatCount(breakdown.houses),
            tooltip: '${breakdown.houses} freestanding house(s) — '
                'tap to ${showHouses ? 'hide' : 'show'} on the map',
            active: showHouses,
            onTap: onToggleHouses,
          ),
          const SizedBox(width: LetterboxTheme.s1 + 2),
          _SplitChip(
            icon: Icons.apartment_rounded,
            label: formatCount(breakdown.apartmentBoxes),
            tooltip: '${breakdown.apartmentBoxes} box(es) across '
                '${breakdown.apartmentBlocks} apartment block(s) — '
                'tap to ${showApartments ? 'hide' : 'show'} on the map',
            active: showApartments,
            accent: LetterboxTheme.apartment,
            onTap: onToggleApartments,
          ),
        ],
        if (dirty) ...[
          const SizedBox(width: LetterboxTheme.s2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(LetterboxTheme.radiusSmall),
            ),
            child: Text(
              'Unsaved',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A count that doubles as a visibility toggle.
///
/// Isolating houses or blocks is a planning move — a round that only covers
/// freestanding houses looks completely different from one that only covers
/// blocks — so the number and the switch are the same control.
class _SplitChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final bool active;
  final Color? accent;
  final VoidCallback onTap;

  const _SplitChip({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = accent ?? scheme.primary;
    final fg = active ? tint : scheme.onSurfaceVariant;

    return Tooltip(
      message: tooltip,
      child: Material(
        color:
            active ? tint.withValues(alpha: 0.12) : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(LetterboxTheme.radiusSmall),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LetterboxTheme.radiusSmall),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(active ? icon : Icons.visibility_off_outlined,
                    size: 14, color: fg),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Live count for a drawn test area.
///
/// This is the question the whole index exists to answer — "how many
/// letterboxes are in here?" — so the number is the largest thing on screen,
/// and the panel is explicit about the two things that would make it
/// misleading: unverified suburbs, and unsaved edits.
class _MeasurePanel extends StatelessWidget {
  final LetterboxProvider provider;

  const _MeasurePanel({required this.provider});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = provider.measureResult;
    final points = provider.measurePoints.length;

    return _FloatingPanel(
      padding: const EdgeInsets.fromLTRB(LetterboxTheme.s4, LetterboxTheme.s3,
          LetterboxTheme.s3, LetterboxTheme.s3),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.straighten, size: 16, color: scheme.primary),
                const SizedBox(width: LetterboxTheme.s2),
                Text(
                  'TEST AREA',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: LetterboxTheme.s2 + 2),
            if (points < 3)
              Text(
                'Tap ${3 - points} more point(s) on the map to close an area.',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              )
            else if (provider.isMeasuring)
              Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: LetterboxTheme.s3),
                  Text('Counting…',
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                ],
              )
            else if (result != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    formatCount(result.count),
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w700,
                      height: 1,
                      letterSpacing: -1.2,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: LetterboxTheme.s2),
                  Text(
                    'letterboxes',
                    style:
                        TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: LetterboxTheme.s1),
              Text(
                result.suburbIds.isEmpty
                    ? 'Does not overlap any curated suburb'
                    : 'Across ${result.suburbIds.length} suburb(s)',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              if (result.count > 0) ...[
                const SizedBox(height: LetterboxTheme.s3),
                Row(
                  children: [
                    Expanded(
                      child: _SplitStat(
                        icon: Icons.home_outlined,
                        value: formatCount(result.breakdown.houses),
                        label: 'freestanding',
                      ),
                    ),
                    const SizedBox(width: LetterboxTheme.s2),
                    Expanded(
                      child: _SplitStat(
                        icon: Icons.apartment_rounded,
                        value: formatCount(result.breakdown.apartmentBoxes),
                        label: '${result.breakdown.apartmentBlocks} block(s)',
                      ),
                    ),
                  ],
                ),
              ],
              if (!result.isTrusted)
                _Caveat(
                  icon: Icons.warning_amber_rounded,
                  tone: scheme.errorContainer,
                  onTone: scheme.onErrorContainer,
                  text: 'Not quotable yet — '
                      '${result.unverifiedSuburbs.length} suburb(s) here are '
                      'uncurated, so this is a guess from GPS drops.',
                ),
              if (provider.isDirty)
                _Caveat(
                  icon: Icons.info_outline_rounded,
                  tone: scheme.surfaceContainerHigh,
                  onTone: scheme.onSurfaceVariant,
                  text: 'Counts saved letterboxes — your unsaved edits are '
                      'not included.',
                ),
            ],
            const SizedBox(height: LetterboxTheme.s2),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: points == 0 ? null : provider.undoMeasurePoint,
                  child: const Text('Undo point'),
                ),
                TextButton(
                  onPressed: points == 0 ? null : provider.clearMeasure,
                  child: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A short qualifier under a headline number.
class _Caveat extends StatelessWidget {
  final IconData icon;
  final Color tone;
  final Color onTone;
  final String text;

  const _Caveat({
    required this.icon,
    required this.tone,
    required this.onTone,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: LetterboxTheme.s2 + 2),
      child: Container(
        padding: const EdgeInsets.all(LetterboxTheme.s2 + 2),
        decoration: BoxDecoration(
          color: tone,
          borderRadius: BorderRadius.circular(LetterboxTheme.radiusSmall),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 15, color: onTone),
            const SizedBox(width: LetterboxTheme.s2),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 11.5, height: 1.35, color: onTone),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One half of the houses-versus-flats split in the test-area panel.
class _SplitStat extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _SplitStat({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: LetterboxTheme.s3, vertical: LetterboxTheme.s2 + 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(LetterboxTheme.radiusSmall),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 5),
              Text(
                value,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 1),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Shown while the letterbox markers are switched off, so an empty-looking map
/// is never mistaken for an empty suburb.
class _HiddenNotice extends StatelessWidget {
  final int count;
  final VoidCallback onShow;

  const _HiddenNotice({required this.count, required this.onShow});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _FloatingPanel(
      padding: const EdgeInsets.fromLTRB(LetterboxTheme.s3, LetterboxTheme.s2,
          LetterboxTheme.s2, LetterboxTheme.s2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.visibility_off_outlined,
              size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: LetterboxTheme.s2),
          Text(
            '${formatCount(count)} letterboxes hidden',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: LetterboxTheme.s2),
          TextButton(
            onPressed: onShow,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding:
                  const EdgeInsets.symmetric(horizontal: LetterboxTheme.s2 + 2),
            ),
            child: const Text('Show'),
          ),
        ],
      ),
    );
  }
}
