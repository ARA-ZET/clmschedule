// utils/rich_clipboard_stub.dart
//
// Non-web: Flutter's clipboard only carries plain text.
import 'package:flutter/services.dart';

/// Copy [html] with [plainText] as its fallback. Returns whether the HTML
/// made it onto the clipboard — false here, so callers can say so.
Future<bool> copyRichText({
  required String html,
  required String plainText,
}) async {
  await Clipboard.setData(ClipboardData(text: plainText));
  return false;
}
