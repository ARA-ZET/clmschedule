import 'dart:typed_data';

import 'package:clmschedule/services/xero_accounting_service.dart';
import 'package:clmschedule/services/zoho_books_service.dart';
import 'package:clmschedule/utils/accounting_error.dart';
import 'package:clmschedule/utils/save_with_picker.dart';
import 'package:clmschedule/widgets/xero/xero_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  FriendlyError describe(Object e, {bool offline = false}) =>
      describeAccountingError(e, action: 'download the PDF', offline: offline);

  // What the Firebase SDK throws when the request never got a reply — the
  // bare "internal" in the bug report.
  const sdkNoReply = XeroException('internal', status: 'internal');

  group('no connection', () {
    test('offline: says so instead of "internal"', () {
      final f = describe(sdkNoReply, offline: true);
      expect(f.title, "Couldn't download the PDF — you're offline.");
      expect(f.advice, contains('Wi-Fi or mobile data'));
      expect(f.advice, contains('Xero'));
      expect(f.detail, 'xero/internal: internal', reason: 'raw kept');
    });

    test('online but no reply: connection dropped or server crashed', () {
      final f = describe(sdkNoReply);
      expect(f.title, contains("the server couldn't be reached"));
      expect(f.advice, contains('Check your connection'));
    });

    test('offline never hides a real answer from the provider', () {
      final f = describe(
        const ZohoBooksException('Zoho Books: Invoice does not exist.',
            status: 'not-found'),
        offline: true,
      );
      expect(f.title, contains("Zoho Books couldn't find it"));
    });

    test('timeout and unavailable', () {
      expect(
          describe(const XeroException('x', status: 'deadline-exceeded')).title,
          contains('took too long'));
      expect(describe(const XeroException('x', status: 'unavailable')).title,
          contains("Xero isn't responding"));
    });
  });

  group('provider answers', () {
    test('quotes the provider without the server prefix', () {
      final f = describe(const ZohoBooksException(
          'Zoho Books: You cannot void a paid invoice.',
          status: 'failed-precondition',
          zohoCode: 1001));
      expect(f.title, contains('Zoho Books turned it down'));
      expect(f.advice, 'Zoho Books said: "You cannot void a paid invoice".');
      expect(f.detail, contains('Zoho code 1001'));
    });

    test('Xero not connected: admin must reconnect', () {
      final f = describe(const XeroException(
          'Xero is not connected: the stored refresh token was rejected. '
          'Run the consent script (~/xero_connect.js) …',
          status: 'failed-precondition'));
      expect(f.title, contains("Xero isn't connected"));
      expect(f.advice, contains('admin'));
      expect(f.advice, isNot(contains('xero_connect.js')),
          reason: 'developer instructions stay in the technical details');
      expect(f.detail, contains('xero_connect.js'));
    });

    test('expired provider login vs not-staff account', () {
      expect(
          describe(const ZohoBooksException(
                  'Zoho token refresh failed: invalid_code.',
                  status: 'permission-denied'))
              .title,
          contains("refused the app's login"));
      expect(
          describe(const XeroException(
                  'Anonymous accounts cannot access Xero.',
                  status: 'permission-denied'))
              .title,
          contains('staff account'));
      expect(
          describe(const ZohoBooksException('Staff sign-in required.',
                  status: 'unauthenticated'))
              .title,
          contains('sign-in has expired'));
    });

    test('rate limit gives the wait Xero asked for', () {
      final f = describe(const XeroException('rate limited',
          status: 'resource-exhausted', retryAfterSeconds: 7200));
      expect(f.title, contains('paused our requests'));
      expect(f.advice, contains('Try again in about 2 hours.'));
      expect(
          describe(const XeroException('x',
                  status: 'resource-exhausted', retryAfterSeconds: 40))
              .advice,
          contains('40 seconds'));
    });

    test('provider sent something that is not a PDF', () {
      expect(
          describe(const XeroException('Xero did not return a PDF.',
                  status: 'internal'))
              .title,
          contains("Xero didn't send a PDF back"));
    });

    test('duplicate save in flight', () {
      expect(
          describe(const ZohoBooksException('already being saved',
                  status: 'aborted'))
              .advice,
          contains("won't be created twice"));
    });
  });

  test('a load failure that left an empty file says both', () {
    final f = describe(
      const LeftoverSaveFileException(sdkNoReply, 'CPA Security - INV-0427.pdf'),
      offline: true,
    );
    expect(f.title, contains("you're offline"));
    expect(f.advice, contains('CPA Security - INV-0427.pdf'));
  });

  test('known-offline before the Save dialog: offline message', () {
    final f = describe(const DeviceOfflineException());
    expect(f.title, "Couldn't download the PDF — you're offline.");
  });

  testWidgets('offline PDF download fails before opening the Save dialog',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final messenger =
        ScaffoldMessenger.of(tester.element(find.byType(Scaffold)));
    var loaded = false;

    await expectLater(
      savePdfWithFeedback(
        messenger,
        fileName: 'x',
        offline: true,
        load: () async {
          loaded = true;
          return Uint8List(0);
        },
      ),
      throwsA(isA<DeviceOfflineException>()),
    );
    expect(loaded, isFalse);
  });

  testWidgets('error banner: title, advice, collapsed technical details',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: XeroNotice.error(describe(sdkNoReply, offline: true)),
      ),
    ));

    expect(find.text("Couldn't download the PDF — you're offline."),
        findsOneWidget);
    expect(find.textContaining('Wi-Fi or mobile data'), findsOneWidget);
    expect(find.text('Technical details'), findsOneWidget);
    expect(find.text('xero/internal: internal'), findsNothing,
        reason: 'raw error hidden until expanded');

    await tester.tap(find.text('Technical details'));
    await tester.pumpAndSettle();
    expect(find.text('xero/internal: internal'), findsOneWidget);
  });

  test('anything unrecognised still reads as a sentence', () {
    final f = describe(StateError('boom'));
    expect(f.title, contains('something unexpected went wrong'));
    expect(f.detail, contains('boom'));
    expect(f.message, startsWith("Couldn't download the PDF"));
  });
}
