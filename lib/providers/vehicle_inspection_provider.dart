import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/vehicle_inspection.dart';
import '../services/vehicle_inspection_service.dart';

/// Live inspections for one schedule civil day — drives the status line on
/// the dropsheet's Inspect row.
final vehicleInspectionsForDayRiverpod = riverpod.StreamProvider.autoDispose
    .family<List<VehicleInspection>, DateTime>((ref, civilDate) {
  return VehicleInspectionService().streamForDate(civilDate);
});
