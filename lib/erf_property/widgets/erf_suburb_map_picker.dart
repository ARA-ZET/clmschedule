import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/csg_region.dart';
import '../models/csg_township.dart';
import '../providers/erf_property_provider.dart';
import '../../shareable_maps/providers/map_gesture_provider.dart';
import '../../shareable_maps/widgets/map_overlay.dart';

/// Pick a suburb to download by tapping its boundary on a map.
///
/// Boundaries come from the CSG "Allotment Township" layer, so what you see
/// is the same shape the parcels are filtered by. This is the right way to
/// scope a Cape Town download: the cadastral minor region there is the whole
/// metro, so picking the suburb polygon is the only way to get one suburb's
/// properties rather than 120 000.
class ErfSuburbMapPicker extends riverpod.ConsumerStatefulWidget {
  const ErfSuburbMapPicker({super.key, this.initialCamera});

  final LatLng? initialCamera;

  /// Cape Town, where the operations are.
  static const LatLng defaultCentre = LatLng(-33.925, 18.424);

  @override
  riverpod.ConsumerState<ErfSuburbMapPicker> createState() =>
      _ErfSuburbMapPickerState();
}

class _ErfSuburbMapPickerState
    extends riverpod.ConsumerState<ErfSuburbMapPicker> {
  GoogleMapController? _controller;
  CsgTownship? _selected;
  int? _parcelCount;
  bool _isCounting = false;
  String? _countError;
  LatLngBounds? _lastLoadedBounds;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _onCameraIdle() async {
    final controller = _controller;
    if (controller == null) return;

    final visible = await controller.getVisibleRegion();
    if (!mounted) return;

    // Skip a reload when the view has barely moved — each pan otherwise
    // fires a fresh query at the register.
    if (_lastLoadedBounds != null && _covers(_lastLoadedBounds!, visible)) {
      return;
    }

    final zoom = await controller.getZoomLevel();
    if (!mounted) return;

    // Below this the view spans provinces and would ask for thousands of
    // boundaries; the hint in the UI tells the user to zoom in.
    if (zoom < 11) {
      setState(() => _lastLoadedBounds = null);
      return;
    }

    _lastLoadedBounds = visible;
    await ref.read(erfPropertyRiverpod).loadTownships(
          ErfBounds(
            minLat: visible.southwest.latitude,
            minLng: visible.southwest.longitude,
            maxLat: visible.northeast.latitude,
            maxLng: visible.northeast.longitude,
          ),
        );
  }

  /// Whether [outer] already contains [inner], so the data on screen is
  /// still valid.
  static bool _covers(LatLngBounds outer, LatLngBounds inner) {
    return outer.southwest.latitude <= inner.southwest.latitude &&
        outer.southwest.longitude <= inner.southwest.longitude &&
        outer.northeast.latitude >= inner.northeast.latitude &&
        outer.northeast.longitude >= inner.northeast.longitude;
  }

  Future<void> _select(CsgTownship township) async {
    setState(() {
      _selected = township;
      _parcelCount = null;
      _countError = null;
      _isCounting = true;
    });

    try {
      final provider = ref.read(erfPropertyRiverpod);

      // The map only ever holds the parts of a suburb that intersect the
      // current view. Re-fetch the whole boundary by code before counting,
      // or an off-screen part is quietly left out of the download.
      final complete = await provider.completeTownship(township);
      final count = await provider.countTownshipParcels(complete);

      if (!mounted) return;
      setState(() {
        _selected = complete;
        _parcelCount = count;
        _isCounting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCounting = false;
        _countError = '$e';
      });
    }
  }

  Set<Polygon> _buildPolygons(List<CsgTownship> townships) {
    final scheme = Theme.of(context).colorScheme;
    final polygons = <Polygon>{};

    for (final township in townships) {
      final isSelected =
          _selected?.code == township.code && _selected?.name == township.name;

      for (var i = 0; i < township.rings.length; i++) {
        polygons.add(Polygon(
          polygonId: PolygonId('${township.code}_${township.name}_$i'),
          points: township.rings[i],
          strokeWidth: isSelected ? 4 : 1,
          strokeColor: isSelected ? scheme.primary : scheme.outline,
          fillColor: isSelected
              ? scheme.primary.withValues(alpha: 0.35)
              : scheme.primary.withValues(alpha: 0.06),
          consumeTapEvents: true,
          onTap: () {
            // A click on the hint or selection card lands here too.
            if (ref.read(mapGestureRiverpod).isHeld) return;
            _select(township);
          },
        ));
      }
    }

    return polygons;
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(erfPropertyRiverpod);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick a suburb'),
        actions: [
          if (provider.isLoadingTownships)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: widget.initialCamera ?? ErfSuburbMapPicker.defaultCentre,
              zoom: 13,
            ),
            onMapCreated: (controller) {
              _controller = controller;
              _onCameraIdle();
            },
            onCameraIdle: _onCameraIdle,
            polygons: _buildPolygons(provider.townships),
            myLocationButtonEnabled: false,
            mapToolbarEnabled: false,
            zoomControlsEnabled: false,
            webGestureHandling: ref.watch(mapGestureRiverpod).gestureHandling,
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: MapOverlay(child: _buildHint(theme, provider)),
          ),
          if (_selected != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: MapOverlay(child: _buildSelectionCard(theme)),
            ),
        ],
      ),
    );
  }

  Widget _buildHint(ThemeData theme, ErfPropertyProvider provider) {
    final String message;
    if (provider.isLoadingTownships) {
      message = 'Loading suburb boundaries…';
    } else if (_lastLoadedBounds == null) {
      message = 'Zoom in to load suburb boundaries';
    } else if (provider.townships.isEmpty) {
      message = 'No cadastral suburbs here — try panning or zooming out a bit';
    } else {
      message = 'Tap a suburb to select it '
          '(${provider.townships.length} in view)';
    }

    return Card(
      elevation: 2,
      color: theme.colorScheme.surface.withValues(alpha: 0.95),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.touch_app_outlined,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionCard(ThemeData theme) {
    final township = _selected!;
    final count = _parcelCount;

    // Roughly 40 seconds per 1000-parcel page against this register.
    final minutes =
        count == null ? null : ((count / 1000).ceil() * 40 / 60).ceil();

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.location_city_rounded,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(township.name,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      Text(
                        township.rings.length > 1
                            ? 'Code ${township.code} · '
                                '${township.rings.length} separate parts'
                            : 'Code ${township.code}',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _selected = null;
                    _parcelCount = null;
                  }),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_isCounting)
              Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text('Counting parcels…', style: theme.textTheme.bodySmall),
                ],
              )
            else if (_countError != null)
              Text(
                _countError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              )
            else if (count != null)
              Text(
                count == 0
                    ? 'No parcels found inside this boundary.'
                    : '${_thousands(count)} parcels · about '
                        '${minutes! <= 1 ? 'a minute' : '$minutes minutes'} '
                        'to download',
                style: theme.textTheme.bodyMedium,
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (count == null || count == 0)
                        ? null
                        : () => Navigator.pop(
                            context, ErfTownshipSelection(township, count)),
                    icon: const Icon(Icons.download),
                    label: const Text('Download this suburb'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _thousands(int value) => value.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+$)'),
        (m) => '${m[1]} ',
      );
}

/// What the picker hands back: the suburb and how many parcels it holds.
class ErfTownshipSelection {
  final CsgTownship township;
  final int parcelCount;

  const ErfTownshipSelection(this.township, this.parcelCount);
}
