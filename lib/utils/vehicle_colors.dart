import 'package:flutter/material.dart';

import '../models/collection_job.dart';

/// Each van's colour, as the Collection Schedule and the main Schedule's
/// booking strips draw it. One table so the two screens never disagree.
final Map<VehicleType, Color> _vehicleColors = {
  VehicleType.hyundai: Colors.blue.shade700,
  // Dark green (user request 2026-11-18): green.shade700 washed out on the
  // grey header cards and the white grid.
  VehicleType.mahindra: Colors.green.shade900,
  VehicleType.nissan: Colors.orange.shade700,
};

Color vehicleColor(VehicleType vehicleType) => _vehicleColors[vehicleType]!;
