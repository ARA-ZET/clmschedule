// Web side of StorageHealth: talks to the storage check in web/index.html
// (window.clmStorageCheck / window.clmStorageBoot) and the browser's
// StorageManager.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

const _incidentKey = 'clm_storage_incident';
const _fixFlag = 'clm_storage_fix';
const _probeKey = 'clm_storage_probe';

/// JSON report from window.clmStorageCheck([level]); a bare probe when the
/// page is an older index.html without it.
String? runStorageCheck(String level) {
  try {
    final fn = web.window.getProperty<JSAny?>('clmStorageCheck'.toJS);
    if (fn == null || fn.isUndefinedOrNull) return _probeOnly();
    final result = (fn as JSFunction).callAsFunction(null, level.toJS);
    return (result as JSString?)?.toDart;
  } catch (_) {
    return _probeOnly();
  }
}

String _probeOnly() {
  try {
    final s = web.window.localStorage;
    s.setItem(_probeKey, 'x' * 32768);
    s.removeItem(_probeKey);
    return '{"available":true,"canWrite":true}';
  } catch (_) {
    try {
      web.window.localStorage.removeItem(_probeKey);
    } catch (_) {}
    return '{"available":true,"canWrite":false}';
  }
}

/// The report of the check that ran when this page loaded.
String? storageBootReport() {
  try {
    final r = web.window.getProperty<JSAny?>('clmStorageBoot'.toJS);
    if (r == null || r.isUndefinedOrNull) return null;
    return (r as JSString).toDart;
  } catch (_) {
    return null;
  }
}

/// Bytes this site uses and may use across IndexedDB, caches etc. The quota
/// shrinks with the computer's free disk space.
Future<({int usage, int quota})?> storageEstimate() async {
  try {
    final est = await web.window.navigator.storage.estimate().toDart;
    return (usage: est.usage, quota: est.quota);
  } catch (_) {
    return null;
  }
}

String? readStorageIncident() {
  try {
    return web.window.localStorage.getItem(_incidentKey);
  } catch (_) {
    return null;
  }
}

void clearStorageIncident() {
  try {
    web.window.localStorage.removeItem(_incidentKey);
  } catch (_) {}
}

/// Asks the next page load to clear localStorage hard (everything but the
/// sign-in token) before Firebase starts, then reloads.
void fixStorageAndReload() {
  try {
    web.window.sessionStorage.setItem(_fixFlag, '1');
  } catch (_) {}
  web.window.location.reload();
}

String browserUserAgent() => web.window.navigator.userAgent;
