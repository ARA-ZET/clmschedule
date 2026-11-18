// shareable_maps/providers/map_letterbox_write_provider.dart
//
// The shareable map editor's writer for "Update letterbox index" — the same
// preview → replace → undo flow the track editor offers, run from a client
// map's polygon with the round's letter-box waypoints loaded on the map.
//
// A separate instance from the track editor's [teLetterboxWriteRiverpod]: that
// one is wired to the track editor's comparison cache, this one to the map
// editor's own counter, so the payloads a write replaces are the ones this
// editor recounts from — and each screen's session undo stays its own.
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../letterbox/services/letterbox_area_write_service.dart';
import '../../track_editor/providers/te_letterbox_write_provider.dart';
import 'shareable_map_provider.dart';

final mapLetterboxWriteRiverpod =
    riverpod.ChangeNotifierProvider<TELetterboxWriteProvider>((ref) {
  final counter = ref.read(shareableMapRiverpod).letterboxCounter;
  return TELetterboxWriteProvider(
    service: LetterboxAreaWriteService(counter: counter),
    counter: counter,
  );
});
