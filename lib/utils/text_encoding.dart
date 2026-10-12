// utils/text_encoding.dart
//
// GPX/KML files are UTF-8, but they used to be read with
// `String.fromCharCodes(bytes)` — one char per byte, i.e. Latin-1. Every
// non-ASCII character came out as two or three junk characters, and the
// Track Editor then saved that junk back, XML-escaping the control
// characters: an en dash "–" (E2 80 93) became "â&#x80;&#x93;" in files
// already in the cloud. [decodeTextBytes] reads files properly and
// [repairMojibake] undoes the damage in text written before the fix.
import 'dart:convert';

/// Decode a text file's bytes as UTF-8 (dropping a BOM), with any
/// mis-decoded text from before the fix repaired. Bytes that are not valid
/// UTF-8 — a genuinely Latin-1 file — fall back to Latin-1.
String decodeTextBytes(List<int> bytes) {
  var b = bytes;
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
    b = b.sublist(3);
  }
  String text;
  try {
    text = utf8.decode(b);
  } on FormatException {
    text = latin1.decode(b);
  }
  return repairMojibake(text);
}

/// A UTF-8 lead byte read as Latin-1 (Â–ô), followed by continuation bytes
/// read as Latin-1 (U+0080–U+00BF) either raw or as the `&#xNN;` the XML
/// writer escaped the control characters to.
final _mojibake = RegExp(
  r'[Â-ô](?:[\u0080-¿]|&#x[89aAbB][0-9a-fA-F];)+',
);

/// [text] with UTF-8 that was mis-read as Latin-1 turned back into the
/// characters it was ("â&#x80;&#x93;" → "–", "Ã©" → "é"). A run that does
/// not decode as UTF-8 is left exactly as it was.
String repairMojibake(String text) {
  if (!_mojibake.hasMatch(text)) return text;
  return text.replaceAllMapped(_mojibake, (m) {
    final run = m[0]!;
    final bytes = <int>[];
    for (var i = 0; i < run.length;) {
      if (run.startsWith('&#x', i)) {
        final end = run.indexOf(';', i);
        bytes.add(int.parse(run.substring(i + 3, end), radix: 16));
        i = end + 1;
      } else {
        bytes.add(run.codeUnitAt(i));
        i++;
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return run;
    }
  });
}
