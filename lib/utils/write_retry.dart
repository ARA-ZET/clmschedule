// utils/write_retry.dart
//
// Which failed Firestore writes are worth trying again. On a slow or
// dropped connection a transaction fails with one of these; giving up then
// silently dropped the edit (payroll) — the user saw it on screen, it never
// reached the server.
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// How many times a web [TypeError] is retried. FlutterFire web turns a
/// runTransaction timeout into "type 'minified:xx' is not a subtype of type
/// 'minified:yy'", so it is retried like a timeout — but not forever, in
/// case it is a genuine bug.
const int maxMaskedWebTimeoutAttempts = 8;

/// True for a write failure caused by the connection or by contention, which
/// a retry (the mutation re-applied to freshly read data) can fix. [attempt]
/// is 1 for the first try.
bool isRetryableWriteError(Object e, {required int attempt}) {
  if (e is TimeoutException) return true;
  if (kIsWeb && e is TypeError) return attempt <= maxMaskedWebTimeoutAttempts;
  if (e is FirebaseException) {
    return const {
      'unavailable',
      'aborted',
      'deadline-exceeded',
      'resource-exhausted',
      'internal',
      'unknown',
      'failed-precondition',
      'cancelled',
    }.contains(e.code);
  }
  return false;
}

/// Wait before retry number [attempt] (1-based): 0.5 s doubling to 15 s.
Duration writeRetryDelay(int attempt) => Duration(
    milliseconds: (500 * (1 << (attempt - 1).clamp(0, 5))).clamp(500, 15000));
