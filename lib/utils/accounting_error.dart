// utils/accounting_error.dart
//
// Plain-language explanations for every way a Xero or Zoho Books action can
// fail, so staff see "Couldn't download the PDF — you're offline" instead of
// the Firebase SDK's bare "internal".
//
// Where the errors come from (the catalogue below follows this):
//
//  * The browser never reached the server (offline, Wi-Fi without internet,
//    connection dropped). The Firebase SDK reports this as code `internal`
//    with the message "internal" — indistinguishable from a server crash, so
//    the device's own offline flag decides which to say.
//  * Our server (functions/lib/xero_accounting.js, zoho_books.js) refused or
//    failed, with an HttpsError code and a developer-facing message.
//  * Xero / Zoho Books refused, passed through by the server as
//    `failed-precondition`, `invalid-argument`, `not-found`, … with the
//    provider's own wording ("Zoho Books: Invoice does not exist.").
//
// The raw text is never thrown away: it is [FriendlyError.detail], shown
// behind "Technical details" for whoever debugs it.
import 'package:cloud_functions/cloud_functions.dart';

import '../services/sync_status.dart';
import '../services/xero_accounting_service.dart';
import '../services/zoho_books_service.dart';
import 'friendly_error.dart';
import 'save_with_picker.dart'
    show DeviceOfflineException, LeftoverSaveFileException;

/// An error explained for the person at the desk.
class FriendlyError {
  /// What failed and why, in one line: "Couldn't download the PDF — you're
  /// offline."
  final String title;

  /// What to do about it.
  final String advice;

  /// The raw error, for an admin or developer.
  final String detail;

  const FriendlyError({
    required this.title,
    required this.advice,
    required this.detail,
  });

  /// Title and advice together, for a toast or a single line of text.
  String get message => '$title $advice';

  @override
  String toString() => message;
}

/// Explain [error] from a Xero or Zoho Books call made to [action] — a phrase
/// that completes "Couldn't …", e.g. "download the PDF", "record the
/// payment".
///
/// [offline] defaults to the device's network state; pass it in tests.
FriendlyError describeAccountingError(
  Object error, {
  required String action,
  bool? offline,
}) {
  // A failed fetch can leave an empty file behind in the Save dialog's
  // folder: explain the cause, then say so.
  if (error is LeftoverSaveFileException) {
    final inner =
        describeAccountingError(error.cause, action: action, offline: offline);
    return FriendlyError(
      title: inner.title,
      advice: '${inner.advice} An empty "${error.fileName}" was left in the '
          'folder you chose — you can delete it.',
      detail: inner.detail,
    );
  }

  final _Parts p = _parts(error);
  final provider = p.provider;
  final said = p.providerSaid;
  // Their words as a sentence: ' Zoho Books said: "Invoice is paid".'
  final quoted = said.isEmpty ? '' : ' $provider said: "$said".';
  String fail(String why) => "Couldn't $action — $why.";
  FriendlyError out(String title, String advice) =>
      FriendlyError(title: title, advice: advice, detail: p.detail);

  final isOffline = error is! DeviceOfflineException &&
      (offline ?? SyncStatus.instance.deviceOffline);
  const connectionCodes = {
    null,
    'internal',
    'unavailable',
    'deadline-exceeded',
    'unknown',
    'cancelled',
    'network-request-failed',
  };
  if (error is DeviceOfflineException ||
      (isOffline && connectionCodes.contains(p.code))) {
    return out(
      fail("you're offline"),
      'This needs the internet to reach $provider. Turn on Wi-Fi or mobile '
          'data, then try again.',
    );
  }

  switch (p.code) {
    // The SDK's "couldn't get a reply" — a dropped connection or a server
    // that crashed without saying why.
    case 'internal' when p.isGenericSdkMessage:
      return out(
        fail("the server couldn't be reached"),
        'Your internet connection may have dropped, or the server stopped '
            'unexpectedly. Check your connection and try again. If it keeps '
            "happening while you're online, let an admin know.",
      );

    case 'internal' when p.message.contains('did not return a PDF'):
      return out(
        fail("$provider didn't send a PDF back"),
        'Try again in a minute. If it keeps happening, open the invoice in '
            '$provider to check it.',
      );

    case 'internal' when p.message.contains('non-JSON'):
      return out(
        fail('$provider sent back an unreadable reply'),
        'This is usually a short outage at $provider. Try again in a few '
            'minutes.',
      );

    case 'internal':
      return out(
        fail('the server ran into a problem'),
        'Try again. If it keeps happening, let an admin know and pass on the '
            'technical details.',
      );

    case 'unavailable':
    case 'network-request-failed':
      return out(
        fail("$provider isn't responding"),
        '$provider may be down or having problems, or your connection is '
            'unstable. Wait a few minutes and try again.',
      );

    case 'deadline-exceeded':
      return out(
        fail('$provider took too long to answer'),
        'This happens on slow connections or when $provider is busy. Try '
            'again.',
      );

    case 'resource-exhausted':
      final wait = p.retryAfterSeconds;
      return out(
        fail('$provider has paused our requests'),
        '$provider limits how many requests this app can make each minute '
            'and each day. '
            '${wait != null ? 'Try again in ${_duration(wait)}.' : 'Wait a minute and try again. If it still fails, the daily limit is used up — try again tomorrow.'}',
      );

    case 'unauthenticated':
      return out(
        fail('your sign-in has expired'),
        'Sign out, sign back in with your staff account, then try again.',
      );

    case 'permission-denied' when p.message.contains('Anonymous'):
      return out(
        fail("you're not signed in with a staff account"),
        'Sign out, sign back in with your staff account, then try again.',
      );

    case 'permission-denied' when p.message.contains('not reachable'):
      return out(
        fail("this company's $provider organisation isn't available"),
        "The $provider login can't reach it. An admin should check the "
            "company's $provider settings.",
      );

    case 'permission-denied':
      return out(
        fail('$provider refused the app\'s login'),
        'The connection between this app and $provider has expired or been '
            'revoked. An admin needs to reconnect $provider — trying again '
            "won't help until then.",
      );

    case 'failed-precondition' when p.message.contains('not connected'):
      return out(
        fail("$provider isn't connected"),
        'An admin needs to reconnect $provider to the organisation — trying '
            "again won't help until then.",
      );

    case 'failed-precondition':
      return out(
        fail('$provider turned it down'),
        said.isEmpty
            ? 'Open the invoice in $provider to see why.'
            : quoted.trim(),
      );

    case 'invalid-argument':
      return out(
        fail('$provider rejected the details sent'),
        '${quoted.isEmpty ? '' : '${quoted.trim()} '}Check the details and '
            'try again. If it keeps happening, let an admin know.',
      );

    case 'not-found':
      return out(
        fail("$provider couldn't find it"),
        'It may have been deleted or voided in $provider. Reload the page, '
            'and if it has gone, unlink it from the job.$quoted',
      );

    case 'aborted':
      return out(
        fail("it's already being saved in $provider"),
        "Wait a moment, then try again — it won't be created twice.",
      );

    case 'cancelled':
      return out(fail('the request was cancelled'), 'Try again.');

    default:
      return out(
        fail('something unexpected went wrong'),
        'Try again. If it keeps happening, let an admin know and pass on the '
            'technical details.',
      );
  }
}

/// The pieces of [error] the catalogue needs, whatever its type.
class _Parts {
  final String provider;
  final String? code;
  final String message;
  final int? retryAfterSeconds;
  final String detail;

  _Parts({
    required this.provider,
    required this.code,
    required this.message,
    required this.detail,
    this.retryAfterSeconds,
  });

  /// The SDK's own text when the request never got a reply.
  bool get isGenericSdkMessage {
    final m = message.trim().toLowerCase();
    return m.isEmpty || m == 'internal';
  }

  /// The provider's own words, without the server's "Xero: " prefix — only
  /// when the message came from Xero/Zoho rather than our plumbing.
  String get providerSaid {
    final m = RegExp(r'^(Zoho Books|Xero):\s*(.+)$', dotAll: true)
        .firstMatch(message.trim());
    if (m == null) return '';
    return m.group(2)!.trim().replaceFirst(RegExp(r'\.$'), '');
  }
}

_Parts _parts(Object error) {
  if (error is XeroException) {
    return _Parts(
      provider: 'Xero',
      code: error.status,
      message: error.message,
      retryAfterSeconds: error.retryAfterSeconds,
      detail: 'xero/${error.status ?? 'unknown'}: ${error.message}',
    );
  }
  if (error is ZohoBooksException) {
    return _Parts(
      provider: 'Zoho Books',
      code: error.status,
      message: error.message,
      detail: 'zoho/${error.status ?? 'unknown'}'
          '${error.zohoCode != null ? ' (Zoho code ${error.zohoCode})' : ''}'
          ': ${error.message}',
    );
  }
  if (error is FirebaseFunctionsException) {
    return _Parts(
      provider: 'the accounting system',
      code: error.code,
      message: error.message ?? '',
      detail: 'functions/${error.code}: ${error.message}',
    );
  }
  return _Parts(
    provider: 'the accounting system',
    code: firebaseErrorCode(error),
    message: error.toString(),
    detail: error.toString(),
  );
}

String _duration(int seconds) {
  if (seconds < 90) return '$seconds seconds';
  final minutes = (seconds / 60).round();
  if (minutes < 90) return '$minutes minutes';
  final hours = (minutes / 60).round();
  return hours == 1 ? 'about an hour' : 'about $hours hours';
}
