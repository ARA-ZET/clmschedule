import 'dart:js_interop';

import 'package:web/web.dart' as web;

web.EventListener? _listener;

/// While [active], closing or reloading the tab asks for confirmation, so a
/// schedule write still saving (or retrying offline) is not dropped.
void setUnsavedChangesGuard(bool active) {
  if (active == (_listener != null)) return;
  if (active) {
    _listener = ((web.Event event) {
      event.preventDefault();
      (event as web.BeforeUnloadEvent).returnValue = '';
    }).toJS;
    web.window.addEventListener('beforeunload', _listener);
  } else {
    web.window.removeEventListener('beforeunload', _listener);
    _listener = null;
  }
}
