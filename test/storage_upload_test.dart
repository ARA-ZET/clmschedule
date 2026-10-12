import 'dart:convert';
import 'dart:typed_data';

import 'package:clmschedule/services/storage_upload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StorageUpload.buildMultipartBody', () {
    final payload = Uint8List.fromList([0x1f, 0x8b, 0x00, 0xff, 0x0d, 0x0a]);

    Uint8List build({Map<String, dynamic>? metadata}) =>
        StorageUpload.buildMultipartBody(
          metadata: metadata ??
              {
                'name': 'erfAreas/region_C0160011.json.gz',
                'contentType': 'application/gzip',
                'cacheControl': 'public, max-age=86400',
                'metadata': {'areaId': 'region_C0160011'},
              },
          bytes: payload,
          boundary: 'BOUND',
          contentType: 'application/gzip',
        );

    test('lays out the two parts in the order the API expects', () {
      final text = latin1.decode(build());

      expect(
        text,
        startsWith('--BOUND\r\n'
            'Content-Type: application/json; charset=utf-8\r\n\r\n'),
      );
      expect(
          text,
          contains('\r\n--BOUND\r\n'
              'Content-Type: application/gzip\r\n\r\n'));
      expect(text, endsWith('\r\n--BOUND--'));
    });

    test('carries the metadata as JSON in the first part', () {
      final text = latin1.decode(build());
      final json = text.substring(
        text.indexOf('{'),
        text.indexOf('}\r\n--BOUND') + 1,
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      expect(decoded['name'], 'erfAreas/region_C0160011.json.gz');
      expect(decoded['contentType'], 'application/gzip');
      expect(decoded['cacheControl'], 'public, max-age=86400');
      expect(decoded['metadata'], {'areaId': 'region_C0160011'});
    });

    test('embeds the payload bytes unaltered', () {
      final body = build();
      // Locate the payload by the tail that must follow it.
      final tail = utf8.encode('\r\n--BOUND--');
      final start = body.length - tail.length - payload.length;

      expect(body.sublist(start, start + payload.length), payload,
          reason: 'binary content must survive byte-for-byte');
      expect(body.sublist(body.length - tail.length), tail);
    });

    test('produces a body length equal to head + payload + tail', () {
      final body = build();
      final tail = utf8.encode('\r\n--BOUND--');
      final headEnd = body.length - tail.length - payload.length;

      expect(headEnd, greaterThan(0));
      expect(body.length, headEnd + payload.length + tail.length);
    });

    test('handles an empty payload', () {
      final body = StorageUpload.buildMultipartBody(
        metadata: const {'name': 'a', 'contentType': 'text/plain'},
        bytes: Uint8List(0),
        boundary: 'B',
        contentType: 'text/plain',
      );
      expect(latin1.decode(body), endsWith('\r\n\r\n\r\n--B--'));
    });
  });

  // These guard the request envelope rather than the body. The body above was
  // correct all along; what shipped broken was the POST around it, and a
  // broken POST here returns HTTP 200 with a normal-looking metadata response
  // — the stored object simply holds the JSON metadata instead of the file.
  // Verified against the live bucket: with `?uploadType=multipart` and no
  // `X-Goog-Upload-Protocol` header, a PNG upload stored 99 bytes of
  // `application/json`; with the header and no query parameter it stored the
  // image, content type and cacheControl intact.
  group('StorageUpload.buildUploadRequest', () {
    ({Uri uri, Map<String, String> headers}) build({
      required bool useMultipart,
      String path = 'mapThumbnails/09-2026_abc.png',
      String contentType = 'image/png',
    }) =>
        StorageUpload.buildUploadRequest(
          bucket: 'clmschedule.firebasestorage.app',
          path: path,
          contentType: contentType,
          useMultipart: useMultipart,
          boundary: 'BOUND',
        );

    test('a multipart upload declares the multipart upload protocol', () {
      final request = build(useMultipart: true);

      expect(request.headers['X-Goog-Upload-Protocol'], 'multipart',
          reason: 'without this the endpoint stores only the metadata part');
      expect(
          request.headers['Content-Type'], 'multipart/related; boundary=BOUND');
    });

    test('never sends uploadType — the v0 endpoint ignores it', () {
      for (final useMultipart in [true, false]) {
        expect(build(useMultipart: useMultipart).uri.queryParameters,
            isNot(contains('uploadType')));
      }
    });

    test('a plain media upload sends the file type and no protocol header', () {
      final request = build(useMultipart: false, contentType: 'image/png');

      expect(request.headers['Content-Type'], 'image/png');
      expect(request.headers, isNot(contains('X-Goog-Upload-Protocol')));
    });

    test('addresses the object by name, percent-encoding the path', () {
      final request = build(
        useMultipart: true,
        path: 'Distribution/2026/Apr 2026/track one.gpx',
      );

      expect(request.uri.queryParameters['name'],
          'Distribution/2026/Apr 2026/track one.gpx');
      expect(request.uri.query, contains('Distribution%2F2026%2F'));
      expect(request.uri.query, isNot(contains(' ')));
    });

    test('posts to the bucket object endpoint', () {
      final uri = build(useMultipart: true).uri;

      expect(uri.host, 'firebasestorage.googleapis.com');
      expect(uri.path, '/v0/b/clmschedule.firebasestorage.app/o');
    });
  });
}
