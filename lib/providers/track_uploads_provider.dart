import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/track_upload.dart';
import '../services/track_upload_service.dart';

final trackUploadServiceRiverpod =
    riverpod.Provider<TrackUploadService>((ref) => TrackUploadService());

/// Track-upload pings for a yyyy-MM-dd range, live. Auto-disposed so
/// changing month drops the old listener.
///
/// Firestore ends a listener for good on an error (permission-denied while a
/// rules deploy is rolling out, index still building), and the grid would
/// then stay blank until a restart. So an error is logged, the last good data
/// is kept, and the listener is rebuilt after [_retryDelay].
final trackUploadsRiverpod = riverpod.StreamProvider.autoDispose
    .family<List<TrackUpload>, ({String from, String to})>((ref, range) {
  return ref
      .watch(trackUploadServiceRiverpod)
      .watchRange(range.from, range.to)
      .handleError((Object e) {
    debugPrint('[TrackUploads] ${range.from}..${range.to} failed: $e '
        '— retrying in ${_retryDelay.inSeconds}s');
    final retry = Timer(_retryDelay, ref.invalidateSelf);
    ref.onDispose(retry.cancel);
  });
});

const Duration _retryDelay = Duration(seconds: 30);
