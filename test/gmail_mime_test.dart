import 'dart:convert';
import 'dart:typed_data';

import 'package:clmschedule/utils/gmail_mime.dart';
import 'package:flutter_test/flutter_test.dart';

/// The draft Gmail builds from this is the email the client receives, so
/// both bodies and the non-ASCII subject must survive the encoding.
void main() {
  String decodePart(String mime, String contentType) {
    final start = mime.indexOf('Content-Type: $contentType');
    final body = mime.substring(mime.indexOf('\r\n\r\n', start) + 4);
    final encoded = body.substring(0, body.indexOf('\r\n--')).replaceAll('\r\n', '');
    return utf8.decode(base64.decode(encoded));
  }

  test('carries the text and the HTML table, each intact', () {
    const html = '<p>Hi Nikita,</p><table><tr><td>Petros Muvimbi</td>'
        '<td>FN 186040</td></tr></table>';
    final text = 'Hi Nikita,\n\nPetros Muvimbi — ID / Passport: FN 186040\n'
        '${'Long line. ' * 40}';
    final mime = buildGmailDraftMime(
      to: ['nikita@chand.co.za', 'office@chand.co.za'],
      subject: 'Your flyers distribution report — Claremont',
      text: text,
      html: html,
    );

    expect(mime, contains('To: nikita@chand.co.za, office@chand.co.za'));
    expect(mime, contains('multipart/alternative'));
    expect(decodePart(mime, 'text/plain'), text);
    expect(decodePart(mime, 'text/html'), contains(html));
    // Wrapped for MIME.
    for (final line in mime.split('\r\n')) {
      expect(line.length, lessThanOrEqualTo(120));
    }

    final subject = RegExp(r'Subject: =\?UTF-8\?B\?(.+)\?=').firstMatch(mime)!;
    expect(utf8.decode(base64.decode(subject.group(1)!)),
        'Your flyers distribution report — Claremont');
  });

  test('no recipients means no To header, not an empty one', () {
    final mime = buildGmailDraftMime(
        to: const [], subject: 's', text: 't', html: 'h');
    expect(mime, isNot(contains('To:')));
  });

  test('the draft opens in the account that owns it', () {
    expect(
      gmailDraftUrl(threadId: '18c2f0a', account: 'office@gmail.com')
          .toString(),
      'https://mail.google.com/mail/?authuser=office%40gmail.com#drafts/18c2f0a',
    );
  });

  test('attachments travel whole, with their names, beside the body', () {
    final pdf = Uint8List.fromList(List.generate(5000, (i) => i % 256));
    final mime = buildGmailDraftMime(
      to: ['nikita@chand.co.za'],
      subject: 'Your flyers distribution report',
      text: 'Hi Nikita,',
      html: '<p>Hi Nikita,</p>',
      attachments: [
        GmailAttachment(
            name: 'Chand – INV-1042.pdf', mimeType: 'application/pdf', bytes: pdf),
      ],
    );

    expect(mime, contains('Content-Type: multipart/mixed'));
    expect(mime, contains('Content-Type: multipart/alternative'));
    expect(decodePart(mime, 'text/plain'), 'Hi Nikita,');
    // A non-ASCII name keeps its exact spelling for clients reading RFC 2231.
    expect(mime,
        contains("filename*=UTF-8''${Uri.encodeComponent('Chand – INV-1042.pdf')}"));

    final start = mime.indexOf('Content-Type: application/pdf');
    final body = mime.substring(mime.indexOf('\r\n\r\n', start) + 4);
    final encoded =
        body.substring(0, body.indexOf('\r\n--')).replaceAll('\r\n', '');
    expect(base64.decode(encoded), pdf);
  });

  test('without attachments the body is not wrapped in multipart/mixed', () {
    final mime = buildGmailDraftMime(
        to: const [], subject: 's', text: 't', html: 'h');
    expect(mime, isNot(contains('multipart/mixed')));
  });
}
