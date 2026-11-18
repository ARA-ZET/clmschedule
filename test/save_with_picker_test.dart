import 'dart:async';
import 'dart:typed_data';

import 'package:clmschedule/utils/save_file_types.dart';
import 'package:clmschedule/utils/save_with_picker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for a file the user picked in Chrome's Save dialog.
class _FakeTarget implements SaveTarget {
  _FakeTarget({this.writeError, this.canDiscard = true});

  final Object? writeError;
  final bool canDiscard;
  Uint8List? written;
  int discards = 0;

  @override
  String get fileName => 'Chosen name.pdf';

  @override
  Future<void> write(Uint8List bytes, String mimeType) async {
    if (writeError != null) throw writeError!;
    written = bytes;
  }

  @override
  Future<bool> discard() async {
    discards++;
    return canDiscard;
  }
}

/// A browser DOMException as Dart sees it: toString() is "Name: message".
class _DomError {
  _DomError(this.text);
  final String text;
  @override
  String toString() => text;
}

void main() {
  final pdf = Uint8List.fromList([1, 2, 3]);
  late List<Uint8List> fellBack;

  Future<void> fallback(Uint8List bytes, String name) async =>
      fellBack.add(bytes);

  setUp(() => fellBack = []);
  tearDown(() => debugSavePicker = null);

  test('opens the Save dialog before the PDF has loaded', () async {
    final loading = Completer<Uint8List>();
    var dialogOpenedWhileLoading = false;
    final target = _FakeTarget();
    debugSavePicker = (_) async {
      dialogOpenedWhileLoading = !loading.isCompleted;
      loading.complete(pdf);
      return SavePick(SavePickStatus.picked, target: target);
    };

    final result = await saveWithPicker(
      fileName: 'Client - INV-1.pdf',
      load: () => loading.future,
      nativeFallback: fallback,
    );

    expect(dialogOpenedWhileLoading, isTrue);
    expect(result.outcome, SaveOutcome.saved);
    expect(result.message, contains('Chosen name.pdf'));
    expect(result.isWarning, isFalse);
    expect(target.written, pdf);
    expect(fellBack, isEmpty);
  });

  test('cancel saves nothing and swallows a load failure', () async {
    debugSavePicker = (_) async => const SavePick(SavePickStatus.cancelled);

    // A load error with nobody awaiting it would fail the test as an
    // unhandled async error.
    final result = await saveWithPicker(
      fileName: 'x.pdf',
      load: () => Future.error(StateError('Zoho down')),
      nativeFallback: fallback,
    );

    expect(result.outcome, SaveOutcome.cancelled);
    expect(result.message, contains('cancelled'));
    expect(fellBack, isEmpty);
  });

  test('a failed write is not mistaken for a cancel: it falls back and says why',
      () async {
    final target = _FakeTarget(
      writeError: _DomError('AbortError: The operation was aborted.'),
    );
    debugSavePicker =
        (_) async => SavePick(SavePickStatus.picked, target: target);

    final result = await saveWithPicker(
      fileName: 'x.pdf',
      load: () async => pdf,
      nativeFallback: fallback,
    );

    expect(result.outcome, SaveOutcome.downloaded);
    expect(result.isWarning, isTrue);
    expect(result.message, contains("Couldn't save to the folder you chose"));
    expect(result.message, contains('stopped the save'));
    expect(target.discards, 1, reason: 'the empty file must be removed');
    expect(fellBack, [pdf]);
  });

  test('a Save dialog that will not open falls back with the reason', () async {
    debugSavePicker = (_) async => SavePick(
          SavePickStatus.failed,
          error: _DomError('SecurityError: Must be handling a user gesture'),
        );

    final result = await saveWithPicker(
      fileName: 'x.pdf',
      load: () async => pdf,
      nativeFallback: fallback,
    );

    expect(result.outcome, SaveOutcome.downloaded);
    expect(result.isWarning, isTrue);
    expect(result.message, contains("Couldn't open the Save dialog"));
    expect(result.message, contains('straight after a click'));
    expect(fellBack, [pdf]);
  });

  test('no Save dialog on this browser: plain download, not a warning',
      () async {
    debugSavePicker = (_) async => const SavePick(SavePickStatus.unavailable);

    final result = await saveWithPicker(
      fileName: 'x.pdf',
      load: () async => pdf,
      nativeFallback: fallback,
    );

    expect(result.outcome, SaveOutcome.downloaded);
    expect(result.isWarning, isFalse);
    expect(fellBack, [pdf]);
  });

  test('a load failure after picking removes the empty file and rethrows',
      () async {
    final target = _FakeTarget();
    debugSavePicker =
        (_) async => SavePick(SavePickStatus.picked, target: target);
    final error = StateError('Zoho down');

    await expectLater(
      saveWithPicker(
        fileName: 'x.pdf',
        load: () => Future.error(error),
        nativeFallback: fallback,
      ),
      throwsA(same(error)),
    );
    expect(target.discards, 1);
    expect(fellBack, isEmpty);
  });

  test('a load failure that leaves an empty file says so', () async {
    final target = _FakeTarget(canDiscard: false);
    debugSavePicker =
        (_) async => SavePick(SavePickStatus.picked, target: target);

    await expectLater(
      saveWithPicker(
        fileName: 'x.pdf',
        load: () => Future.error(StateError('Zoho down')),
        nativeFallback: fallback,
      ),
      throwsA(isA<LeftoverSaveFileException>().having(
        (e) => e.toString(),
        'message',
        allOf(contains('Zoho down'), contains('Chosen name.pdf')),
      )),
    );
  });

  test('a download that cannot start is a failure, not a "downloaded"',
      () async {
    // No native fallback: the file goes through the plain download helper,
    // which fails here (no path_provider plugin in tests). It used to
    // swallow that and the toast said the file had downloaded.
    debugSavePicker = (_) async => const SavePick(SavePickStatus.unavailable);

    await expectLater(
      saveWithPicker(fileName: 'x.pdf', load: () async => pdf),
      throwsA(anything),
    );
  });

  test('Chrome could not create the chosen file: says so, not "open"',
      () async {
    // Windows keeps a PDF that is open in Acrobat/Edge locked; Chrome then
    // rejects the Save dialog itself with NoModificationAllowedError.
    debugSavePicker = (_) async => SavePick(
          SavePickStatus.failed,
          error: _DomError('NoModificationAllowedError: An attempt was made '
              'to write to a file or directory which could not be modified'),
        );

    final result = await saveWithPicker(
      fileName: 'x.pdf',
      load: () async => pdf,
      nativeFallback: fallback,
    );

    expect(result.isWarning, isTrue);
    expect(result.message, contains("Couldn't save to the folder you chose"));
    expect(result.message, contains('PDF viewer'));
    expect(fellBack, [pdf]);
  });

  test('"File editing" blocked for the site points at the setting', () async {
    final target = _FakeTarget(
      writeError: _DomError('NotAllowedError: The request is not allowed by '
          'the user agent or the platform in the current context.'),
    );
    debugSavePicker =
        (_) async => SavePick(SavePickStatus.picked, target: target);

    final result = await saveWithPicker(
      fileName: 'x.pdf',
      load: () async => pdf,
      nativeFallback: fallback,
    );

    expect(result.message, contains('"File editing"'));
    expect(result.message, contains('Site settings'));
  });

  test('Chrome closing the dialog itself still gets the user the file',
      () async {
    debugSavePicker = (_) async => SavePick(
          SavePickStatus.closedByBrowser,
          error: browserClosedSaveDialog(
              elapsed: const Duration(seconds: 2), pageWasHidden: true),
        );

    final result = await saveWithPicker(
      fileName: 'x.pdf',
      load: () async => pdf,
      nativeFallback: fallback,
    );

    expect(result.outcome, SaveOutcome.downloaded,
        reason: 'not reported as the user cancelling');
    expect(result.isWarning, isTrue);
    expect(result.chromeClosedDialog, isTrue,
        reason: 'the toast offers "How to fix"');
    expect(result.message, contains('covered or hidden'));
    expect(fellBack, [pdf]);
  });

  group('AbortError: Chrome or the user?', () {
    test('page hidden while the dialog was up: Chrome', () {
      expect(
          browserClosedSaveDialog(
              elapsed: const Duration(seconds: 5), pageWasHidden: true),
          chromeClosedCoveredReason);
    });

    test('too fast for a person: Chrome never showed it', () {
      expect(
          browserClosedSaveDialog(
              elapsed: const Duration(milliseconds: 40), pageWasHidden: false),
          "Chrome didn't show the Save dialog");
    });

    test('visible page, after a human pause: the user cancelled', () {
      expect(
          browserClosedSaveDialog(
              elapsed: const Duration(milliseconds: 1500),
              pageWasHidden: false),
          isNull);
    });
  });

  group('Check saving files', () {
    test('Cancel in the Save dialog is a pass', () async {
      debugSavePicker = (_) async => const SavePick(SavePickStatus.cancelled);
      final result = await checkSaveDialog();
      expect(result.outcome, SaveCheckOutcome.works);
    });

    test('picking a place passes and removes the empty test file', () async {
      final target = _FakeTarget();
      debugSavePicker =
          (_) async => SavePick(SavePickStatus.picked, target: target);
      final result = await checkSaveDialog();
      expect(result.outcome, SaveCheckOutcome.works);
      expect(result.detail, isNull);
      expect(target.discards, 1);
      expect(target.written, isNull, reason: 'the test never writes a file');
    });

    test('an empty test file that cannot be removed is mentioned', () async {
      final target = _FakeTarget(canDiscard: false);
      debugSavePicker =
          (_) async => SavePick(SavePickStatus.picked, target: target);
      final result = await checkSaveDialog();
      expect(result.outcome, SaveCheckOutcome.works);
      expect(result.detail, contains('you can delete it'));
    });

    test('a full-screen Save dialog is told apart from "never shown"',
        () async {
      debugSavePicker = (_) async => const SavePick(
          SavePickStatus.closedByBrowser,
          error: chromeClosedCoveredReason);
      expect((await checkSaveDialog()).outcome,
          SaveCheckOutcome.coveredByDialog);

      debugSavePicker = (_) async => const SavePick(
          SavePickStatus.closedByBrowser,
          error: chromeDidNotShowReason);
      expect((await checkSaveDialog()).outcome, SaveCheckOutcome.notShown);
    });

    test('no Save dialog in this browser, or one that fails, is reported',
        () async {
      debugSavePicker = (_) async => const SavePick(
          SavePickStatus.unavailable,
          error: 'only Chrome and Edge have one');
      expect((await checkSaveDialog()).outcome, SaveCheckOutcome.unavailable);

      debugSavePicker = (_) async => SavePick(SavePickStatus.failed,
          error: _DomError('SecurityError: Must be handling a user gesture'));
      final failed = await checkSaveDialog();
      expect(failed.outcome, SaveCheckOutcome.failed);
      expect(failed.detail, contains('straight after a click'));
    });
  });

  test('a second Save dialog while one is open is explained', () {
    expect(
      describeSaveError(_DomError(
          "NotAllowedError: Failed to execute 'showSaveFilePicker' on "
          "'Window': File picker already active.")),
      'a Save dialog is already open',
    );
  });

  test('toast colours: green saved, orange fallback, neutral cancel', () {
    expect(
        const SaveResult(SaveOutcome.downloaded, 'x', confirmed: false)
            .snackBar!
            .backgroundColor,
        isNull,
        reason: 'an unconfirmed browser download is never shown as success');
    expect(const SaveResult(SaveOutcome.saved, 'ok').snackBar!.backgroundColor,
        isNotNull);
    expect(
        const SaveResult(SaveOutcome.downloaded, 'x', isWarning: true)
            .snackBar!
            .duration,
        const Duration(seconds: 10));
    expect(
        const SaveResult(SaveOutcome.cancelled, 'x').snackBar!.backgroundColor,
        isNull);
    expect(const SaveResult(SaveOutcome.downloaded, '').snackBar, isNull);
  });
}
