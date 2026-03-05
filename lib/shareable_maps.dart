/// Export file for shareable maps functionality
/// Makes importing easier - use: import 'package:clmschedule/shareable_maps.dart';
library;

// Adapters
export 'shareable_maps/adapters/map_data_adapter.dart';
export 'shareable_maps/adapters/standalone_adapter.dart';
export 'shareable_maps/adapters/work_area_adapter.dart';
export 'shareable_maps/adapters/schedule_job_adapter.dart';
export 'shareable_maps/adapters/job_list_area_adapter.dart';

// Models
export 'shareable_maps/models/shareable_map.dart';
export 'shareable_maps/models/map_layer.dart';
export 'shareable_maps/models/map_polyline.dart';
export 'shareable_maps/models/map_point.dart';
export 'models/custom_polygon.dart'; // Re-export for convenience

// Providers
export 'shareable_maps/providers/shareable_map_provider.dart';

// Widgets
export 'shareable_maps/widgets/shareable_map_editor.dart';
export 'shareable_maps/widgets/map_layers_sidebar.dart';
export 'shareable_maps/widgets/map_drawing_toolbar.dart';

// Services (for KML/GPX import)
export 'services/kml_parser_service.dart';
