// utils/friendly_error.dart
//
// Plain-language wording for Firebase errors, for screens used by people who
// should not have to read "[cloud_firestore/permission-denied] Missing or
// insufficient permissions". The raw error is still worth keeping for whoever
// debugs it — show it behind a "Technical details" toggle, not as the message.
import 'package:firebase_core/firebase_core.dart';

import '../services/storage_health.dart';

/// The Firebase error code of [error] ('permission-denied', 'unavailable', …),
/// or null when it is not a Firebase error.
String? firebaseErrorCode(Object error) {
  if (error is FirebaseException) return error.code;
  // Errors re-wrapped as strings (e.g. 'Failed to …: $error') keep the
  // "[plugin/code]" prefix.
  final match = RegExp(r'\[[\w_-]+/([\w-]+)\]').firstMatch(error.toString());
  return match?.group(1);
}

/// True for errors that usually clear by themselves within seconds — a
/// connection drop, a sign-in token being refreshed, rules being deployed —
/// so a listener is worth re-opening rather than giving up on.
bool isTransientFirebaseError(Object error) {
  const transient = {
    'permission-denied',
    'unauthenticated',
    'unavailable',
    'deadline-exceeded',
    'aborted',
    'internal',
    'cancelled',
    'resource-exhausted',
    'network-request-failed',
  };
  return transient.contains(firebaseErrorCode(error));
}

/// A short sentence for a non-technical user saying what went wrong with
/// [action] (e.g. "load the Job List", "save your changes") and what to do.
String friendlyFirebaseError(Object error, {required String action}) {
  if (StorageHealth.isStorageFullError(error)) {
    StorageHealth.instance.noteError(error);
    return "This browser's storage for CLM Schedule is full, so we couldn't "
        '$action. Press "Fix now" in the red bar at the top of the page.';
  }
  switch (firebaseErrorCode(error)) {
    case 'permission-denied':
    case 'unauthenticated':
      return "We couldn't confirm your sign-in, so we couldn't $action. "
          'This usually fixes itself in a few seconds. If it keeps '
          'happening, sign out and sign back in.';
    case 'unavailable':
    case 'network-request-failed':
      return "We couldn't reach the server to $action. "
          'Check your internet connection.';
    case 'deadline-exceeded':
      return 'The server took too long to respond, so we couldn\'t $action. '
          'Check your internet connection and try again.';
    case 'resource-exhausted':
      return "The server is busy, so we couldn't $action. "
          'Wait a minute and try again.';
    case 'failed-precondition':
      return "The server isn't ready yet, so we couldn't $action. "
          'Try again in a few minutes.';
    case 'not-found':
      return "We couldn't $action because it no longer exists — "
          'someone may have moved or deleted it.';
    default:
      return "Something went wrong and we couldn't $action. Try again — if "
          'it keeps happening, let an admin know.';
  }
}
