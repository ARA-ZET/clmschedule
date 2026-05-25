import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'browser_screenshot_stub.dart'
    if (dart.library.js_interop) 'browser_screenshot_web.dart' as implementation;

bool get isBrowserScreenshotSupported =>
    implementation.isBrowserScreenshotSupported;

bool get isDomScreenshotSupported => implementation.isDomScreenshotSupported;

Future<Uint8List> captureBrowserViewportArea(Rect viewportRect) {
  return implementation.captureBrowserViewportArea(viewportRect);
}

Future<Uint8List> captureDomViewportArea(Rect viewportRect) {
  return implementation.captureDomViewportArea(viewportRect);
}
