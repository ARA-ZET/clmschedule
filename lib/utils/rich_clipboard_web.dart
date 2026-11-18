// utils/rich_clipboard_web.dart
//
// Web: one ClipboardItem carrying both text/html and text/plain. Gmail
// pastes the HTML; a plain-text field pastes the text.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

/// Copy [html] with [plainText] as its fallback. Returns whether the HTML
/// made it onto the clipboard; when the browser refuses (no permission, an
/// old browser), the plain text is copied instead and this returns false.
Future<bool> copyRichText({
  required String html,
  required String plainText,
}) async {
  try {
    web.Blob blob(String text, String type) =>
        web.Blob([text.toJS].toJS, web.BlobPropertyBag(type: type));

    final items = JSObject()
      ..setProperty('text/html'.toJS, blob(html, 'text/html'))
      ..setProperty('text/plain'.toJS, blob(plainText, 'text/plain'));
    await web.window.navigator.clipboard
        .write([web.ClipboardItem(items)].toJS)
        .toDart;
    return true;
  } catch (e) {
    debugPrint('copyRichText: HTML copy failed, falling back to text: $e');
    await Clipboard.setData(ClipboardData(text: plainText));
    return false;
  }
}
