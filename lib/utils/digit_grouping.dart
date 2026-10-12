import 'package:flutter/services.dart';

/// Strips everything but digits — the form actually stored/saved.
String stripDigitGrouping(String value) =>
    value.replaceAll(RegExp(r'[^0-9]'), '');

/// Groups digits in 4s separated by a single space, e.g. `854736924` ->
/// `8547 3692 4`, for on-screen readability of account/phone numbers.
String groupDigits(String value) {
  final digits = stripDigitGrouping(value);
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && i % 4 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Live-formats an account/phone number field into 4-digit groups as the
/// user types, keeping the cursor next to the same digit so mid-number edits
/// land where the user put the cursor.
class GroupedDigitsFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = newValue.text;
    final sel = newValue.selection;
    var cursor =
        sel.isValid ? sel.extentOffset.clamp(0, text.length) : text.length;

    // Deleting only a group separator would be undone by re-grouping, so the
    // keypress would do nothing — remove the neighbouring digit instead
    // (before it for backspace, after it for forward-delete).
    final removedOnlySeparator = text.length < oldValue.text.length &&
        stripDigitGrouping(text) == stripDigitGrouping(oldValue.text);
    if (removedOnlySeparator) {
      final oldCursor = oldValue.selection.isValid
          ? oldValue.selection.extentOffset
          : oldValue.text.length;
      if (oldCursor > cursor && cursor > 0) {
        text = text.substring(0, cursor - 1) + text.substring(cursor);
        cursor -= 1;
      } else if (oldCursor == cursor && cursor < text.length) {
        text = text.substring(0, cursor) + text.substring(cursor + 1);
      }
    }

    final digitsBeforeCursor =
        stripDigitGrouping(text.substring(0, cursor)).length;
    final grouped = groupDigits(text);
    var offset = 0;
    var seen = 0;
    while (offset < grouped.length && seen < digitsBeforeCursor) {
      if (grouped[offset] != ' ') seen++;
      offset++;
    }
    return TextEditingValue(
      text: grouped,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}
