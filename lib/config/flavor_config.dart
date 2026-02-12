/// Flavor configuration for the CLM Schedule app.
///
/// Flavors:
/// - clm: Full featured app with all capabilities (4 tabs)
/// - happysun: Ultra-simplified app for solar projects only (1 tab: Happy Sun)
///            Job List Provider filters to only window cleaning & solar panel jobs
library;

enum Flavor {
  clm,
  happysun,
}

class FlavorConfig {
  final Flavor flavor;
  final String appName;
  final bool enableHappySun;
  final bool enableCollectionSchedule;

  FlavorConfig._({
    required this.flavor,
    required this.appName,
    required this.enableHappySun,
    required this.enableCollectionSchedule,
  });

  static FlavorConfig? _instance;

  static FlavorConfig get instance {
    _instance ??= _fromEnvironment();
    return _instance!;
  }

  static FlavorConfig _fromEnvironment() {
    const flavorString = String.fromEnvironment('FLAVOR', defaultValue: 'clm');

    switch (flavorString) {
      case 'happysun':
        return FlavorConfig._(
          flavor: Flavor.happysun,
          appName: 'Happy Sun',
          enableHappySun: true,
          enableCollectionSchedule: false,
        );
      case 'clm':
      default:
        return FlavorConfig._(
          flavor: Flavor.clm,
          appName: 'CLM Schedule',
          enableHappySun: true,
          enableCollectionSchedule: true,
        );
    }
  }

  bool get isCLM => flavor == Flavor.clm;
  bool get isHappySun => flavor == Flavor.happysun;

  @override
  String toString() => 'FlavorConfig(flavor: $flavor, appName: $appName)';
}
