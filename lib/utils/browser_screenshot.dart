import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'browser_screenshot_stub.dart'
    if (dart.library.html) 'browser_screenshot_web.dart' as implementation;

bool get isBrowserScreenshotSupported =>
    implementation.isBrowserScreenshotSupported;

Future<Uint8List> captureBrowserViewportArea(Rect viewportRect) {
  return implementation.captureBrowserViewportArea(
    viewportRect,
  );
}
