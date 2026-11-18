// Non-web: there is no browser storage quota to watch.
String? runStorageCheck(String level) => null;
String? storageBootReport() => null;
Future<({int usage, int quota})?> storageEstimate() async => null;
String? readStorageIncident() => null;
void clearStorageIncident() {}
void fixStorageAndReload() {}
String browserUserAgent() => '';
