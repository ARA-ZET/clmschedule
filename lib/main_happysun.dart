import 'main.dart' as app;

void main() {
  // Initialize flavor config for happysun flavor
  const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'happysun');
  assert(flavor == 'happysun', 'This entry point is for happysun flavor only');

  app.main();
}
