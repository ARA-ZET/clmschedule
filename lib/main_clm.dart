import 'main.dart' as app;

void main() {
  // Initialize flavor config for clm flavor
  const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'clm');
  assert(flavor == 'clm', 'This entry point is for clm flavor only');
  app.main();
}
