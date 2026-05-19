// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' show Rect;

@JS('clmCaptureBrowserViewportArea')
external JSPromise<JSString> _captureBrowserViewportAreaJs(
  JSNumber left,
  JSNumber top,
  JSNumber width,
  JSNumber height,
);

bool _captureHelperInjected = false;

bool get isBrowserScreenshotSupported {
  final dynamic mediaDevices = html.window.navigator.mediaDevices;
  return mediaDevices != null;
}

Future<Uint8List> captureBrowserViewportArea(Rect viewportRect) async {
  final dynamic mediaDevices = html.window.navigator.mediaDevices;
  if (mediaDevices == null) {
    throw UnsupportedError('This browser does not support screen capture.');
  }

  _ensureCaptureHelper();
  final dataUrl = (await _captureBrowserViewportAreaJs(
    viewportRect.left.toJS,
    viewportRect.top.toJS,
    viewportRect.width.toJS,
    viewportRect.height.toJS,
  ).toDart)
      .toDart;

  final commaIndex = dataUrl.indexOf(',');
  if (commaIndex == -1) {
    throw StateError('Browser capture could not create a PNG image.');
  }

  return Uint8List.fromList(base64Decode(dataUrl.substring(commaIndex + 1)));
}

void _ensureCaptureHelper() {
  if (_captureHelperInjected) return;

  final target = html.document.head ?? html.document.body;
  if (target == null) {
    throw StateError('Browser document is not ready for screen capture.');
  }

  target.append(
    html.ScriptElement()
      ..id = 'clm-browser-capture-helper'
      ..type = 'text/javascript'
      ..text = r'''
(function () {
  if (window.clmCaptureBrowserViewportArea) return;

  window.clmCaptureBrowserViewportArea = async function (left, top, width, height) {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) {
      throw new Error('Screen capture is not supported by this browser.');
    }

    const stream = await navigator.mediaDevices.getDisplayMedia({
      video: {
        displaySurface: 'browser',
        preferCurrentTab: true,
        selfBrowserSurface: 'include',
        surfaceSwitching: 'exclude'
      },
      audio: false
    });

    const video = document.createElement('video');
    video.autoplay = true;
    video.muted = true;
    video.playsInline = true;
    video.srcObject = stream;
    video.style.position = 'fixed';
    video.style.left = '-10000px';
    video.style.top = '-10000px';
    video.style.width = '1px';
    video.style.height = '1px';
    video.style.opacity = '0';
    video.style.pointerEvents = 'none';
    document.body.appendChild(video);

    try {
      await new Promise(function (resolve, reject) {
        const timeout = window.setTimeout(function () {
          reject(new Error('Timed out waiting for browser capture.'));
        }, 10000);
        video.onloadedmetadata = function () {
          window.clearTimeout(timeout);
          resolve();
        };
        video.onerror = function () {
          window.clearTimeout(timeout);
          reject(new Error('Browser capture video failed.'));
        };
      });

      await video.play();
      await new Promise(function (resolve) {
        window.requestAnimationFrame(function () {
          window.requestAnimationFrame(resolve);
        });
      });
      await new Promise(function (resolve) {
        window.setTimeout(resolve, 150);
      });

      const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 1;
      const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 1;
      const cropLeft = Math.max(0, Math.min(left, viewportWidth));
      const cropTop = Math.max(0, Math.min(top, viewportHeight));
      const cropRight = Math.max(cropLeft + 1, Math.min(left + width, viewportWidth));
      const cropBottom = Math.max(cropTop + 1, Math.min(top + height, viewportHeight));
      const scaleX = video.videoWidth / viewportWidth;
      const scaleY = video.videoHeight / viewportHeight;
      const sourceLeft = Math.max(0, Math.min(Math.round(cropLeft * scaleX), video.videoWidth - 1));
      const sourceTop = Math.max(0, Math.min(Math.round(cropTop * scaleY), video.videoHeight - 1));
      const sourceWidth = Math.max(1, Math.min(Math.round((cropRight - cropLeft) * scaleX), video.videoWidth - sourceLeft));
      const sourceHeight = Math.max(1, Math.min(Math.round((cropBottom - cropTop) * scaleY), video.videoHeight - sourceTop));

      const canvas = document.createElement('canvas');
      canvas.width = sourceWidth;
      canvas.height = sourceHeight;
      const context = canvas.getContext('2d');
      context.imageSmoothingEnabled = true;
      context.drawImage(video, sourceLeft, sourceTop, sourceWidth, sourceHeight, 0, 0, sourceWidth, sourceHeight);
      return canvas.toDataURL('image/png');
    } finally {
      stream.getTracks().forEach(function (track) { track.stop(); });
      video.remove();
    }
  };
})();
''',
  );

  _captureHelperInjected = true;
}
