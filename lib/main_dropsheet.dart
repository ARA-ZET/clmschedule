import 'main.dart' as app;

void main() {
  // Initialize flavor config for dropsheet flavor.
  // Run with: flutter run --dart-define=FLAVOR=dropsheet -t lib/main_dropsheet.dart
  const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'dropsheet');
  assert(flavor == 'dropsheet',
      'This entry point is for dropsheet flavor only');
  app.main();
}
