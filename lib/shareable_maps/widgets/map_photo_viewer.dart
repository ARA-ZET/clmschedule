// shareable_maps/widgets/map_photo_viewer.dart
//
// A waypoint's photo, full screen over the map: the thumbnail at once, the
// full photo when it has loaded, zoom in/out (or pinch / scroll), download
// and close — the same as the photos page's viewer.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/map_photos.dart';

Future<void> showMapPhotoViewer(BuildContext context, MapPhoto photo) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0xF20B0D12),
    builder: (_) => _MapPhotoViewer(photo: photo),
  );
}

class _MapPhotoViewer extends StatefulWidget {
  final MapPhoto photo;

  const _MapPhotoViewer({required this.photo});

  @override
  State<_MapPhotoViewer> createState() => _MapPhotoViewerState();
}

class _MapPhotoViewerState extends State<_MapPhotoViewer> {
  static const double _maxScale = 4;
  final _transform = TransformationController();
  Size _viewport = Size.zero;
  double _scale = 1;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
  }

  @override
  void dispose() {
    _transform
      ..removeListener(_onTransform)
      ..dispose();
    super.dispose();
  }

  void _onTransform() {
    final s = _transform.value.getMaxScaleOnAxis();
    if ((s - _scale).abs() > 0.001) setState(() => _scale = s);
  }

  /// Zoom by [factor] about the middle of the view, as the buttons do.
  void _zoom(double factor) {
    final current = _transform.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(1.0, _maxScale);
    if (target == 1.0) {
      _transform.value = Matrix4.identity();
      return;
    }
    final s = target / current;
    final c = _viewport.center(Offset.zero);
    _transform.value = Matrix4.translationValues(c.dx, c.dy, 0)
      ..multiply(Matrix4.diagonal3Values(s, s, 1))
      ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0))
      ..multiply(_transform.value);
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photo;
    final caption = [
      photo.who,
      if (photo.date.isNotEmpty) '${photo.date} ${photo.time}'.trim(),
    ].where((s) => s.isNotEmpty).join(' · ');

    Widget button(IconData icon, String tip, VoidCallback? onPressed) =>
        IconButton(
          tooltip: tip,
          onPressed: onPressed,
          icon: Icon(icon),
          color: Colors.white,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.12),
            fixedSize: const Size.square(44),
          ),
        );

    return Dialog.fullscreen(
      backgroundColor: const Color(0xFF0B0D12),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(photo.what.isEmpty ? 'Photo' : photo.what,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 15)),
                      if (caption.isNotEmpty)
                        Text(caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Color(0xFFB8C0CC), fontSize: 12)),
                    ],
                  ),
                ),
                button(Icons.remove, 'Zoom out',
                    _scale > 1.001 ? () => _zoom(1 / 1.5) : null),
                SizedBox(
                  width: 52,
                  child: Text('${(_scale * 100).round()}%',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Color(0xFFB8C0CC),
                          fontSize: 13,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ),
                button(Icons.add, 'Zoom in',
                    _scale < _maxScale - 0.001 ? () => _zoom(1.5) : null),
                const SizedBox(width: 6),
                button(Icons.download_outlined, 'Download', () {
                  launchUrl(Uri.parse(photo.downloadUrl),
                      mode: LaunchMode.externalApplication);
                }),
                const SizedBox(width: 6),
                button(Icons.close, 'Close', () => Navigator.of(context).pop()),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              _viewport = constraints.biggest;
              return InteractiveViewer(
                transformationController: _transform,
                minScale: 1,
                maxScale: _maxScale,
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: Image.network(
                    photo.fullUrl,
                    fit: BoxFit.contain,
                    // The thumbnail stands in until the full photo is ready,
                    // at the same size, so it only sharpens.
                    frameBuilder: (context, child, frame, _) => frame != null
                        ? child
                        : _withThumbnail(photo, 'Loading full size…'),
                    errorBuilder: (context, _, __) =>
                        _withThumbnail(photo, 'Full size could not load'),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _withThumbnail(MapPhoto photo, String note) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(photo.thumbUrl,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox.shrink()),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(note,
                style: const TextStyle(color: Color(0xFFD6DBE3), fontSize: 12)),
          ),
        ),
      ],
    );
  }
}
