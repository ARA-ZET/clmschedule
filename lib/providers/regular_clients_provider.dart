import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/regular_client.dart';
import '../services/regular_client_service.dart';

final regularClientServiceRiverpod =
    riverpod.Provider<RegularClientService>((ref) => RegularClientService());

/// Every regular client, live, sorted by name. Shared by the library screen
/// and the Job List add/edit dialog's suggestion.
final regularClientsRiverpod =
    riverpod.StreamProvider<List<RegularClient>>((ref) {
  return ref.watch(regularClientServiceRiverpod).streamAll();
});
