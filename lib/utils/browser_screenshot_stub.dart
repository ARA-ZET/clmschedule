import 'dart:typed_data';
import 'dart:ui' show Rect;

bool get isBrowserScreenshotSupported => false;

Future<Uint8List> captureBrowserViewportArea(Rect viewportRect) {
  throw UnsupportedError(
      'Browser screenshot capture is only available on web.');
}
