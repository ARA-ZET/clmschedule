// utils/gmail_mime.dart
//
// The raw email the Gmail API takes for a draft: one message with a plain
// text part and an HTML part, so the recipient's mail client shows the
// formatted report (real table, links) and falls back to the text.
import 'dart:convert';
import 'dart:typed_data';

/// A file sent with the draft.
class GmailAttachment {
  final String name;
  final String mimeType;
  final Uint8List bytes;

  const GmailAttachment({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });
}

/// Gmail's limit for one email, attachments included. Checked against the
/// files' own size; base64 adds about a third on the wire, which Gmail's
/// figure already allows for.
const int kGmailAttachmentLimitBytes = 25 * 1024 * 1024;

/// RFC 2822 message for Gmail's upload endpoint.
///
/// Text and HTML are alternatives of one body; with [attachments] that body
/// and the files sit side by side in a `multipart/mixed` wrapper.
String buildGmailDraftMime({
  required List<String> to,
  required String subject,
  required String text,
  required String html,
  List<GmailAttachment> attachments = const [],
  String boundary = 'clm-report-boundary',
}) {
  final body = '$boundary-body';
  final lines = <String>[
    if (to.isNotEmpty) 'To: ${to.join(', ')}',
    // Encoded so "—" and other non-ASCII survive the header.
    'Subject: ${_encodedWord(subject)}',
    'MIME-Version: 1.0',
  ];

  final alternative = <String>[
    'Content-Type: multipart/alternative; boundary="$body"',
    '',
    '--$body',
    'Content-Type: text/plain; charset="UTF-8"',
    'Content-Transfer-Encoding: base64',
    '',
    _b64Lines(utf8.encode(text)),
    '--$body',
    'Content-Type: text/html; charset="UTF-8"',
    'Content-Transfer-Encoding: base64',
    '',
    _b64Lines(utf8.encode('<!doctype html><html><body>$html</body></html>')),
    '--$body--',
  ];

  if (attachments.isEmpty) {
    lines.addAll(alternative);
  } else {
    lines
      ..add('Content-Type: multipart/mixed; boundary="$boundary"')
      ..add('')
      ..add('--$boundary')
      ..addAll(alternative);
    for (final file in attachments) {
      lines.addAll([
        '--$boundary',
        'Content-Type: ${file.mimeType}; name="${_encodedWord(file.name)}"',
        // RFC 2231 for clients that read it; the plain name for the rest.
        'Content-Disposition: attachment; filename="${_asciiName(file.name)}"; '
            "filename*=UTF-8''${Uri.encodeComponent(file.name)}",
        'Content-Transfer-Encoding: base64',
        '',
        _b64Lines(file.bytes),
      ]);
    }
    lines.add('--$boundary--');
  }
  lines.add('');
  return lines.join('\r\n');
}

/// MIME bodies are wrapped at 76 characters.
String _b64Lines(List<int> bytes) {
  final encoded = base64.encode(bytes);
  final out = StringBuffer();
  for (var i = 0; i < encoded.length; i += 76) {
    if (i > 0) out.write('\r\n');
    out.write(encoded.substring(
        i, i + 76 > encoded.length ? encoded.length : i + 76));
  }
  return out.toString();
}

String _encodedWord(String s) => '=?UTF-8?B?${base64.encode(utf8.encode(s))}?=';

String _asciiName(String s) =>
    s.replaceAll(RegExp(r'[^\x20-\x7E]'), '_').replaceAll('"', "'");

/// The Gmail web page that opens a draft for editing, in the account that
/// owns it — not whichever account happens to be first in the browser.
///
/// Opened by its thread: Gmail still accepts the API's hex thread ids in
/// `#drafts/<id>`, but `?compose=` now takes Gmail's own internal token
/// and, given the API's message id, opens an empty compose window.
Uri gmailDraftUrl({required String threadId, required String account}) {
  final who = account.isEmpty ? '' : '?authuser=${Uri.encodeComponent(account)}';
  return Uri.parse('https://mail.google.com/mail/$who#drafts/$threadId');
}
