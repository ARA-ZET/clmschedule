import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' show Rect;

@JS('clmIsScreenCaptureSupported')
external JSBoolean? _isScreenCaptureSupportedJs();

@JS('clmIsDomCaptureSupported')
external JSBoolean? _isDomCaptureSupportedJs();

@JS('clmCaptureBrowserViewportArea')
external JSPromise<JSString> _captureScreenJs(
  JSNumber left,
  JSNumber top,
  JSNumber width,
  JSNumber height,
);

@JS('clmCaptureDomArea')
external JSPromise<JSString> _captureDomJs(
  JSNumber left,
  JSNumber top,
  JSNumber width,
  JSNumber height,
);

bool get isBrowserScreenshotSupported {
  try {
    return _isScreenCaptureSupportedJs()?.toDart ?? false;
  } catch (_) {
    return false;
  }
}

bool get isDomScreenshotSupported {
  try {
    return _isDomCaptureSupportedJs()?.toDart ?? false;
  } catch (_) {
    return false;
  }
}

Future<Uint8List> captureBrowserViewportArea(Rect viewportRect) async {
  final dataUrl = (await _captureScreenJs(
    viewportRect.left.toJS,
    viewportRect.top.toJS,
    viewportRect.width.toJS,
    viewportRect.height.toJS,
  ).toDart)
      .toDart;
  return _decodeDataUrl(dataUrl);
}

Future<Uint8List> captureDomViewportArea(Rect viewportRect) async {
  final dataUrl = (await _captureDomJs(
    viewportRect.left.toJS,
    viewportRect.top.toJS,
    viewportRect.width.toJS,
    viewportRect.height.toJS,
  ).toDart)
      .toDart;
  return _decodeDataUrl(dataUrl);
}

Uint8List _decodeDataUrl(String dataUrl) {
  final commaIndex = dataUrl.indexOf(',');
  if (commaIndex == -1) {
    throw StateError('Browser capture could not create a PNG image.');
  }
  return Uint8List.fromList(base64Decode(dataUrl.substring(commaIndex + 1)));
}
