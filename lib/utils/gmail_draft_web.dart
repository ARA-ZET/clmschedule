// utils/gmail_draft_web.dart
//
// Google Identity Services token client → Gmail API drafts.create. Only the
// gmail.compose scope is asked for, and only when a report is being sent;
// the app's own (Firebase) sign-in is untouched. Tokens live in memory for
// their hour, so one permission popup covers a session of reports.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../config/google_oauth_config.dart';
import 'gmail_draft.dart';
import 'gmail_mime.dart';

const String _scope = 'https://www.googleapis.com/auth/gmail.compose';
const String _gisScript = 'https://accounts.google.com/gsi/client';

bool get gmailDraftsAvailable => kGoogleOAuthWebClientId.isNotEmpty;

String? _token;
DateTime? _tokenExpires;
String _account = '';
Future<void>? _scriptLoad;

/// Load Google's sign-in script ahead of the click that needs it. Browsers
/// only let the permission popup open straight after a click; a script still
/// downloading at that moment would get it blocked.
void prepareGmailDrafts() {
  if (!gmailDraftsAvailable) return;
  _scriptLoad ??= _loadScript();
  _scriptLoad!.catchError((Object _) {});
}

/// Get Gmail permission now, showing Google's popup if needed. Call it
/// straight from the click, before anything slow (fetching attachments):
/// browsers block the popup once the click is a few seconds old.
Future<void> ensureGmailAccess() async {
  if (!gmailDraftsAvailable) {
    throw const GmailDraftException('Gmail drafts are not set up yet.');
  }
  await _accessToken();
}

Future<Uri> createGmailDraft({
  required List<String> to,
  required String subject,
  required String text,
  required String html,
  List<GmailAttachment> attachments = const [],
}) async {
  if (!gmailDraftsAvailable) {
    throw const GmailDraftException('Gmail drafts are not set up yet.');
  }
  final mime = utf8.encode(buildGmailDraftMime(
    to: to,
    subject: subject,
    text: text,
    html: html,
    attachments: attachments,
  ));

  var token = await _accessToken();
  var response = await _postDraft(token, mime);
  if (response.statusCode == 401) {
    // Revoked or expired early: ask again once.
    _token = null;
    token = await _accessToken();
    response = await _postDraft(token, mime);
  }
  if (response.statusCode != 200) {
    throw GmailDraftException(_apiError(response));
  }

  final message = (jsonDecode(response.body) as Map)['message'] as Map?;
  // A new draft starts its own thread, whose id is normally the message's.
  final threadId =
      (message?['threadId'] as String?) ?? (message?['id'] as String?);
  if (threadId == null) {
    throw const GmailDraftException('Gmail did not return the new draft.');
  }
  if (_account.isEmpty) _account = await _profileEmail(token);
  return gmailDraftUrl(threadId: threadId, account: _account);
}

/// The upload endpoint takes the message as-is, up to 35 MB — the JSON one
/// would need it base64url'd inside a much smaller request.
Future<http.Response> _postDraft(String token, List<int> mime) => http.post(
      Uri.parse('https://gmail.googleapis.com/upload/gmail/v1/users/me/drafts'
          '?uploadType=media'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'message/rfc822',
      },
      body: mime,
    );

/// The account the permission was given for, so the draft opens there.
Future<String> _profileEmail(String token) async {
  try {
    final r = await http.get(
      Uri.parse('https://gmail.googleapis.com/gmail/v1/users/me/profile'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (r.statusCode != 200) return '';
    return ((jsonDecode(r.body) as Map)['emailAddress'] as String?) ?? '';
  } catch (_) {
    return '';
  }
}

String _apiError(http.Response r) {
  try {
    final error = (jsonDecode(r.body) as Map)['error'] as Map?;
    final message = error?['message'] as String?;
    if (message != null && message.isNotEmpty) return message;
  } catch (_) {}
  return 'Gmail answered ${r.statusCode}.';
}

Future<String> _accessToken() async {
  final token = _token;
  final expires = _tokenExpires;
  if (token != null &&
      expires != null &&
      DateTime.now().isBefore(expires.subtract(const Duration(minutes: 2)))) {
    return token;
  }

  await (_scriptLoad ??= _loadScript());
  final done = Completer<String>();

  final config = JSObject()
    ..setProperty('client_id'.toJS, kGoogleOAuthWebClientId.toJS)
    ..setProperty('scope'.toJS, _scope.toJS)
    ..setProperty(
      'callback'.toJS,
      ((JSObject response) {
        final error = response.getProperty<JSString?>('error'.toJS)?.toDart;
        final access =
            response.getProperty<JSString?>('access_token'.toJS)?.toDart;
        if (error != null || access == null) {
          if (!done.isCompleted) {
            done.completeError(GmailDraftException(
              'Google did not give permission to create drafts'
              '${error == null ? '' : ' ($error)'}.',
              cancelled: error == 'access_denied',
            ));
          }
          return;
        }
        final seconds =
            num.tryParse('${response.getProperty<JSAny?>('expires_in'.toJS).dartify()}') ??
                3599;
        _token = access;
        _tokenExpires =
            DateTime.now().add(Duration(seconds: seconds.toInt()));
        if (!done.isCompleted) done.complete(access);
      }).toJS,
    )
    ..setProperty(
      'error_callback'.toJS,
      ((JSObject error) {
        final type = error.getProperty<JSString?>('type'.toJS)?.toDart ?? '';
        if (!done.isCompleted) {
          done.completeError(GmailDraftException(
            type == 'popup_closed'
                ? 'The Google permission window was closed.'
                : type == 'popup_failed_to_open'
                    ? 'The browser blocked Google\'s permission window.'
                    : 'Google sign-in failed ($type).',
            cancelled: type == 'popup_closed',
          ));
        }
      }).toJS,
    );

  final oauth2 = (web.window as JSObject)
      .getProperty<JSObject>('google'.toJS)
      .getProperty<JSObject>('accounts'.toJS)
      .getProperty<JSObject>('oauth2'.toJS);
  final client =
      oauth2.callMethod<JSObject>('initTokenClient'.toJS, config);
  client.callMethod<JSAny?>('requestAccessToken'.toJS);
  return done.future;
}

Future<void> _loadScript() {
  final done = Completer<void>();
  final script = web.document.createElement('script') as web.HTMLScriptElement
    ..src = _gisScript
    ..async = true;
  script.addEventListener(
      'load', ((web.Event _) => done.complete()).toJS);
  script.addEventListener(
      'error',
      ((web.Event _) {
        _scriptLoad = null;
        done.completeError(const GmailDraftException(
            'Could not load Google sign-in. Check the connection.'));
      }).toJS);
  web.document.head!.appendChild(script);
  return done.future;
}
