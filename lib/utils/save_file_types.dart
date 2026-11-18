// utils/save_file_types.dart
//
// Platform-neutral types shared by the web Save-As picker (save_file.dart)
// and its native stub (save_file_stub.dart).
import 'dart:typed_data';

/// A file the user has just named in the browser's Save dialog.
///
/// Chrome creates the file — empty — the moment the dialog is accepted, so a
/// target that is never written must be [discard]ed or a 0-byte file is left
/// behind in the user's folder.
abstract class SaveTarget {
  /// The name the user actually chose (they can edit the suggestion). The
  /// folder is never exposed to the page.
  String get fileName;

  /// Write [bytes] and commit the file. Throws when the browser or disk
  /// refuses; the partial write is abandoned first.
  Future<void> write(Uint8List bytes, String mimeType);

  /// Best-effort removal of the empty file the dialog created. Returns false
  /// when the browser cannot remove it.
  Future<bool> discard();
}

enum SavePickStatus {
  /// The user chose a location — see [SavePick.target].
  picked,

  /// The user closed the dialog.
  cancelled,

  /// Chrome closed the dialog itself, or never showed it, and reported it
  /// with the same AbortError as a real Cancel. [SavePick.error] says why.
  closedByBrowser,

  /// No Save-As dialog on this browser/platform (Firefox, Safari, native).
  unavailable,

  /// The dialog could not open — see [SavePick.error].
  failed,
}

class SavePick {
  final SavePickStatus status;
  final SaveTarget? target;
  final Object? error;

  const SavePick(this.status, {this.target, this.error});
}

/// Nobody can see the Save dialog and press Cancel this fast: on Windows the
/// dialog alone takes longer than this to appear.
const quickestHumanCancel = Duration(milliseconds: 600);

/// Why an AbortError from the Save dialog was Chrome's doing rather than the
/// user's Cancel, or null when it was the user.
///
/// Chrome answers "The user aborted a request." for its own refusals too
/// (checked in Chromium's source, 2026-11-11):
/// * the tab is not fully visible when the dialog is due to open, or stops
///   being visible while it is open — minimised, another tab or app in
///   front, or, on Windows, the Chrome window entirely covered by another
///   window (Chrome re-checks this every 16 ms);
/// * the browser window is smaller than 400×300;
/// * file dialogs are turned off by policy (AllowFileSelectionDialogs);
/// * Windows could not create its Save dialog.
///
/// The common Windows case: Windows remembers the Save dialog's size per
/// program, and once it was maximised it opens full screen, covers Chrome,
/// and Chrome closes it at once (confirmed on an office PC, 2026-11-11).
///
/// [pageWasHidden]: the page was hidden at any point while the dialog was
/// up. [elapsed]: from asking for the dialog to the AbortError.
String? browserClosedSaveDialog({
  required Duration elapsed,
  required bool pageWasHidden,
}) {
  if (pageWasHidden) return chromeClosedCoveredReason;
  if (elapsed < quickestHumanCancel) return chromeDidNotShowReason;
  return null;
}

/// [browserClosedSaveDialog]: the page went hidden while the dialog was up.
const chromeClosedCoveredReason = 'Chrome closed the Save dialog because this '
    'window was covered or hidden — usually the Save dialog opening full '
    'screen';

/// [browserClosedSaveDialog]: refused too fast for anyone to have seen it.
const chromeDidNotShowReason = "Chrome didn't show the Save dialog";

/// Plain-language reason for a Save-As / file-write failure, from the
/// browser's DOMException name ("NotAllowedError: …").
String describeSaveError(Object error) {
  final text = error.toString();
  // A second click while the first dialog is still open.
  if (text.contains('already active')) return 'a Save dialog is already open';
  final name = RegExp(r'^(\w+Error)\b').firstMatch(text)?.group(1);
  return switch (name) {
    'SecurityError' when text.contains('gesture') =>
      'the browser only opens the Save dialog straight after a click',
    'SecurityError' => 'Chrome blocked that location for security reasons',
    'NotAllowedError' when text.contains('file picker') =>
      "this page isn't allowed to show a Save dialog",
    // The dialog worked but the site may not write: Chrome's "File editing"
    // site permission is set to Block (or blocked by company policy).
    'NotAllowedError' => 'Chrome\'s "File editing" permission is blocked for '
        'this site — allow it in Site settings',
    // Windows locks a file that is open (e.g. in Acrobat or Edge); Windows
    // Security's "Controlled folder access" also lands here.
    'NoModificationAllowedError' => 'the file is open in another program '
        '(such as a PDF viewer), or the folder is protected or read-only',
    'TypeMismatchError' => 'that name is already used by a folder',
    'QuotaExceededError' => 'the disk is full',
    'InvalidStateError' => 'the file was changed or moved while saving',
    'NotFoundError' => 'that folder is no longer available',
    'AbortError' => 'the browser stopped the save part-way',
    _ => text.replaceFirst(RegExp(r'^(Exception|Error): '), ''),
  };
}
