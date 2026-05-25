import 'dart:typed_data';
import 'dart:ui' show Rect;

bool get isBrowserScreenshotSupported => false;

bool get isDomScreenshotSupported => false;

Future<Uint8List> captureBrowserViewportArea(Rect viewportRect) {
  throw UnsupportedError(
      'Browser screenshot capture is only available on web.');
}

Future<Uint8List> captureDomViewportArea(Rect viewportRect) {
  throw UnsupportedError(
      'DOM screenshot capture is only available on web.');
}
