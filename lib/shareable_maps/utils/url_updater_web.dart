// Web implementation: update the browser address bar URL.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Replace the current browser URL with [path] (e.g. '/map/x7Kp2mNq').
/// Uses `replaceState` so pressing Back doesn't cycle through share URLs.
void updateBrowserUrl(String path) {
  html.window.history.replaceState(null, '', path);
}

/// Reset the browser URL back to the app root.
void resetBrowserUrl() {
  html.window.history.replaceState(null, '', '/');
}

/// Open [path] (same-origin, e.g. '/admin/map?doc=..&month=..') in a NEW
/// browser tab, so several maps can be open at once. Resolves [path] against
/// the current origin so a relative path lands on the right host.
void openInNewTab(String path) {
  final url = Uri.base.resolve(path).toString();
  html.window.open(url, '_blank');
}
