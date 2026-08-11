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
/// user types. Cursor is simply pinned to the end after each edit — precise
/// mid-string cursor tracking isn't worth the complexity for this field.
class GroupedDigitsFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final grouped = groupDigits(newValue.text);
    return TextEditingValue(
      text: grouped,
      selection: TextSelection.collapsed(offset: grouped.length),
    );
  }
}
