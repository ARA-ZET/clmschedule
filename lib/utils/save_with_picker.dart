// utils/save_with_picker.dart
//
// "Save As" for files that still have to be fetched (Zoho/Xero invoice PDFs),
// with a clear message for every outcome.
//
// Order matters. Chrome only opens the Save dialog within ~5 s of the click,
// so the dialog opens first and the file is fetched while the user picks a
// folder. Fetching first meant a slow Zoho/Xero response made Chrome refuse
// the dialog, and the file silently went to Downloads instead.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/sync_status.dart';
import '../widgets/app_toast.dart';
import '../widgets/save_check_dialog.dart' show openSaveCheckGuide;
import 'root_navigator.dart';
import 'save_file.dart' if (dart.library.io) 'save_file_stub.dart';
import 'web_file_download.dart';

enum SaveOutcome {
  /// Written to the location the user picked.
  saved,

  /// Handed to the browser's ordinary download (or the native fallback).
  downloaded,

  /// The user closed the Save dialog; nothing was written.
  cancelled,
}

class SaveResult {
  final SaveOutcome outcome;

  /// What to tell the user. Empty when the platform's own UI (the native
  /// share sheet) already shows the outcome.
  final String message;

  /// The file did not go where the user asked — it fell back to Downloads.
  final bool isWarning;

  /// False when the file was handed to the browser's ordinary download: the
  /// browser never tells the page whether it then saved or blocked it, so
  /// the message must not claim success (and is not shown in green).
  final bool confirmed;

  /// Chrome closed the Save dialog by itself, which this computer can fix
  /// (see save_check_dialog.dart) — the toast offers "How to fix".
  final bool chromeClosedDialog;

  const SaveResult(
    this.outcome,
    this.message, {
    this.isWarning = false,
    this.confirmed = true,
    this.chromeClosedDialog = false,
  });

  SnackBar? get snackBar {
    if (message.isEmpty) return null;
    final canGuide =
        chromeClosedDialog && rootNavigatorKey.currentContext != null;
    return SnackBar(
      content: Text(message),
      backgroundColor: switch (outcome) {
        SaveOutcome.cancelled => null,
        _ when isWarning => Colors.orange,
        _ when !confirmed => null,
        _ => Colors.green,
      },
      duration: Duration(seconds: isWarning ? 10 : 4),
      action: canGuide
          ? const SnackBarAction(
              label: 'How to fix', onPressed: openSaveCheckGuide)
          : null,
    );
  }
}

/// Stands in for the browser's Save dialog in tests.
@visibleForTesting
Future<SavePick> Function(String suggestedName)? debugSavePicker;

/// The fetch failed after the Save dialog had already created an empty file
/// that the browser would not let us remove.
class LeftoverSaveFileException implements Exception {
  final Object cause;
  final String fileName;

  const LeftoverSaveFileException(this.cause, this.fileName);

  @override
  String toString() =>
      '$cause (an empty "$fileName" was left in the folder you chose — '
      'you can delete it)';
}

/// Let the user choose where [fileName] goes, then save what [load] returns.
///
/// Call this before awaiting anything else in the click handler (see the
/// file comment). Errors from [load] are rethrown so the caller can report
/// them as it already does; every save outcome is returned as a
/// [SaveResult] instead.
///
/// Where the Save dialog is unavailable (Firefox, Safari) or fails, the file
/// is downloaded the ordinary way and the result says so. On native
/// platforms [nativeFallback] is used when given (e.g. the share sheet).
Future<SaveResult> saveWithPicker({
  required String fileName,
  required Future<Uint8List> Function() load,
  String mimeType = 'application/pdf',
  String typeDescription = 'PDF document',
  Future<void> Function(Uint8List bytes, String fileName)? nativeFallback,
}) async {
  final dot = fileName.lastIndexOf('.');
  final extension = dot > 0 ? fileName.substring(dot) : '';

  // Start fetching now so the file is usually ready by the time the user
  // has picked a folder. The no-op handler keeps a failure from being
  // reported as unhandled while the dialog is open; it is still thrown
  // below, where `loading` is awaited.
  final loading = load();
  unawaited(loading.then((_) {}, onError: (Object _) {}));

  final pick = await (debugSavePicker?.call(fileName) ??
      pickSaveFile(
        suggestedName: fileName,
        mimeType: mimeType,
        typeDescription: typeDescription,
        extension: extension,
      ));

  Future<SaveResult> fallback({String? reason, String? noDialogBecause}) async =>
      _download(
        await loading,
        fileName,
        mimeType,
        nativeFallback,
        reason: reason,
        noDialogBecause: noDialogBecause,
      );

  switch (pick.status) {
    case SavePickStatus.cancelled:
      return const SaveResult(
          SaveOutcome.cancelled, 'Save cancelled — no file was saved.');
    case SavePickStatus.closedByBrowser:
      // Not the user's choice: still get them the file.
      final sent = await fallback(
          reason: pick.error?.toString() ?? chromeDidNotShowReason);
      return SaveResult(
        sent.outcome,
        sent.message,
        isWarning: sent.isWarning,
        confirmed: sent.confirmed,
        chromeClosedDialog: true,
      );
    case SavePickStatus.unavailable:
      return fallback(noDialogBecause: pick.error?.toString());
    case SavePickStatus.failed:
      final error = pick.error!;
      return fallback(
        reason: _failedBeforeDialog(error)
            ? "Couldn't open the Save dialog (${describeSaveError(error)})"
            // The user picked a place; Chrome then could not create the file
            // there — e.g. Windows has it locked open in a PDF viewer.
            : "Couldn't save to the folder you chose "
                '(${describeSaveError(error)})',
      );
    case SavePickStatus.picked:
      break;
  }

  final target = pick.target!;
  final Uint8List bytes;
  try {
    bytes = await loading;
  } catch (e, st) {
    if (await target.discard()) rethrow;
    Error.throwWithStackTrace(
        LeftoverSaveFileException(e, target.fileName), st);
  }

  try {
    await target.write(bytes, mimeType);
    return SaveResult(
      SaveOutcome.saved,
      'Saved "${target.fileName}" to the folder you chose',
    );
  } catch (e) {
    await target.discard();
    return fallback(
      reason: "Couldn't save to the folder you chose "
          '(${describeSaveError(e)})',
    );
  }
}

/// What [checkSaveDialog] found on this computer.
enum SaveCheckOutcome {
  /// The Save dialog opened and stayed open until the user closed it.
  works,

  /// Chrome closed it at once because the window counted as covered —
  /// on Windows, the Save dialog opening full screen.
  coveredByDialog,

  /// Chrome refused without showing it (window under 400×300, or file
  /// dialogs switched off by policy).
  notShown,

  /// This browser has no Save dialog; files always go to Downloads.
  unavailable,

  /// The Save dialog could not open; see [SaveCheckResult.detail].
  failed,
}

class SaveCheckResult {
  final SaveCheckOutcome outcome;

  /// Extra words for the user, if any.
  final String? detail;

  const SaveCheckResult(this.outcome, [this.detail]);
}

/// Suggested name for the test; never actually written.
const saveCheckFileName = 'CLM save test.pdf';

/// Open the Save dialog once, the way an invoice download does, to see
/// whether Chrome keeps it open on this computer. Call straight from a click.
///
/// Nothing is saved: pressing Cancel is a pass, and if the user does pick a
/// place, the empty file Chrome creates there is removed again.
Future<SaveCheckResult> checkSaveDialog() async {
  final pick = await (debugSavePicker?.call(saveCheckFileName) ??
      pickSaveFile(suggestedName: saveCheckFileName));
  switch (pick.status) {
    case SavePickStatus.picked:
      final target = pick.target!;
      return SaveCheckResult(
        SaveCheckOutcome.works,
        await target.discard()
            ? null
            : 'An empty "${target.fileName}" was left in the folder you '
                'chose — you can delete it.',
      );
    case SavePickStatus.cancelled:
      return const SaveCheckResult(SaveCheckOutcome.works);
    case SavePickStatus.closedByBrowser:
      return SaveCheckResult(pick.error == chromeClosedCoveredReason
          ? SaveCheckOutcome.coveredByDialog
          : SaveCheckOutcome.notShown);
    case SavePickStatus.unavailable:
      return SaveCheckResult(
          SaveCheckOutcome.unavailable, pick.error?.toString());
    case SavePickStatus.failed:
      return SaveCheckResult(
          SaveCheckOutcome.failed, describeSaveError(pick.error!));
  }
}

/// Errors the Save dialog raises before it is shown. Anything else comes from
/// Chrome creating the chosen file after the user pressed Save.
bool _failedBeforeDialog(Object error) {
  final text = error.toString();
  return text.contains('gesture') || // SecurityError: too long after the click
      text.contains('file picker') || // NotAllowedError: "already active" etc.
      text.startsWith('TypeError');
}

/// Thrown before the Save dialog opens when the device has no network, so
/// nobody picks a folder for a file that cannot be fetched.
class DeviceOfflineException implements Exception {
  const DeviceOfflineException();

  @override
  String toString() => 'The device is offline (no Wi-Fi or mobile data).';
}

/// [saveWithPicker] for a PDF that has to be fetched, showing the outcome as
/// a toast. [fileName] has no extension. Capture [messenger] before the first
/// await. Throws [DeviceOfflineException] at once when the device is offline
/// ([offline] defaults to the device's network state).
Future<void> savePdfWithFeedback(
  ScaffoldMessengerState messenger, {
  required String fileName,
  required Future<Uint8List> Function() load,
  bool? offline,
}) async {
  if (offline ?? SyncStatus.instance.deviceOffline) {
    throw const DeviceOfflineException();
  }
  final result = await saveWithPicker(
    fileName: '$fileName.pdf',
    load: load,
    nativeFallback: (bytes, name) =>
        Printing.sharePdf(bytes: bytes, filename: name),
  );
  final toast = result.snackBar;
  if (toast != null) messenger.showToast(toast);
}

Future<SaveResult> _download(
  Uint8List bytes,
  String fileName,
  String mimeType,
  Future<void> Function(Uint8List bytes, String fileName)? nativeFallback, {
  String? reason,
  String? noDialogBecause,
}) async {
  if (!kIsWeb && nativeFallback != null) {
    await nativeFallback(bytes, fileName);
    // The share sheet shows its own outcome; only a reason needs saying.
    return reason == null
        ? const SaveResult(SaveOutcome.downloaded, '')
        : SaveResult(SaveOutcome.downloaded, '$reason.', isWarning: true);
  }

  // Throws when the download cannot even start, so that is reported as a
  // failure rather than as a download.
  final path = await triggerFileDownload(bytes, fileName, mimeType,
      rethrowErrors: true);

  // Native: the file was written and flushed — a real, checked save.
  if (path != null) {
    return SaveResult(
      SaveOutcome.downloaded,
      reason == null ? 'Saved to $path' : '$reason. Saved to $path instead.',
      isWarning: reason != null,
    );
  }

  // Web: handed to the browser, which may still block it without telling
  // the page — so say what to look for rather than claim it worked.
  const check = "If it doesn't appear in your downloads, allow downloads "
      'for this site, then try again.';
  final sent = 'Sent "$fileName" to your browser\'s downloads';
  return SaveResult(
    SaveOutcome.downloaded,
    reason != null
        ? '$reason. $sent instead. $check'
        : noDialogBecause != null
            ? 'No Save dialog here ($noDialogBecause). $sent. $check'
            : '$sent. $check',
    isWarning: reason != null,
    confirmed: false,
  );
}
