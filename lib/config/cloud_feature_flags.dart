/// Feature flags for opting parts of the app into Cloud Function
/// implementations of operations that previously ran client-side.
///
/// Toggle these here (or via `--dart-define` at build time) to A/B test
/// the cloud-offload variants without disturbing existing call sites.
class CloudFeatureFlags {
  /// When true, [DropsheetRoutePlanner.optimizeSection] delegates to
  /// the `optimizeDropsheetRoute` Cloud Function. The cloud variant
  /// uses a shared org-wide route cache and parallelises Directions
  /// API lookups, eliminating client-side network fan-out and main
  /// thread jank during route optimisation.
  ///
  /// Override at build time:
  ///   flutter run --dart-define=USE_CLOUD_ROUTE_OPTIMIZER=true
  static const bool useCloudRouteOptimizer = bool.fromEnvironment(
    'USE_CLOUD_ROUTE_OPTIMIZER',
    defaultValue: true,
  );

  /// When true, [DistanceMatrixService] one-off lookups go through the
  /// `getRouteSegment` Cloud Function (shared org-wide cache).
  /// Currently only the route optimiser uses Distance Matrix in bulk,
  /// and it routes through the cloud optimiser when the flag above is
  /// on, so this is opt-in.
  static const bool useCloudDistanceMatrix = bool.fromEnvironment(
    'USE_CLOUD_DISTANCE_MATRIX',
    defaultValue: false,
  );
}
