import 'package:clmschedule/utils/digit_grouping.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue _v(String text, int cursor) => TextEditingValue(
    text: text, selection: TextSelection.collapsed(offset: cursor));

void main() {
  final f = GroupedDigitsFormatter();

  test('typing at the end appends and regroups', () {
    final r = f.formatEditUpdate(_v('0821', 4), _v('08212', 5));
    expect(r.text, '0821 2');
    expect(r.selection.baseOffset, 6);
  });

  test('typing mid-number keeps cursor after the typed digit', () {
    // '0821 2345', cursor after '08' -> type '9'
    final r = f.formatEditUpdate(_v('0821 2345', 2), _v('08921 2345', 3));
    expect(r.text, '0892 1234 5');
    expect(r.selection.baseOffset, 3);
  });

  test('backspace right after a space deletes the digit before it', () {
    final r = f.formatEditUpdate(_v('0821 2345', 5), _v('08212345', 4));
    expect(r.text, '0822 345');
    expect(r.selection.baseOffset, 3);
  });

  test('forward-delete on a space deletes the digit after it', () {
    final r = f.formatEditUpdate(_v('0821 2345', 4), _v('08212345', 4));
    expect(r.text, '0821 345');
    expect(r.selection.baseOffset, 4);
  });

  test('backspace mid-number keeps cursor in place', () {
    final r = f.formatEditUpdate(_v('0821 2345', 7), _v('0821 245', 6));
    expect(r.text, '0821 245');
    expect(r.selection.baseOffset, 6);
  });
}
