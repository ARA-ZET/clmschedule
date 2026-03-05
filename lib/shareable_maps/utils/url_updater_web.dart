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
