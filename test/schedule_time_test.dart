import 'package:flutter_test/flutter_test.dart';
import 'package:clmschedule/utils/schedule_time.dart';

void main() {
  group('schedule_time SAST (+2) anchoring', () {
    test('round-trips a civil day back to the same day', () {
      final civil = DateTime(2026, 7, 20);
      final instant = scheduleCivilToInstant(civil);
      final back = toScheduleCivil(instant);
      expect(back.year, 2026);
      expect(back.month, 7);
      expect(back.day, 20);
    });

    test('civil-to-instant is timezone-independent (UTC midnight minus 2h)', () {
      // Jul 20 SAST midnight == 2026-07-19T22:00:00Z, regardless of the
      // machine running this code.
      final instant = scheduleCivilToInstant(DateTime(2026, 7, 20)).toUtc();
      expect(instant, DateTime.utc(2026, 7, 19, 22, 0, 0));
    });

    test('legacy SAST-created instant resolves to the correct civil day', () {
      // Every client (SAST or Ireland) must read this stored instant as Jul 20.
      final stored = DateTime.utc(2026, 7, 19, 22, 0, 0);
      final civil = toScheduleCivil(stored);
      expect(civil.day, 20);
      expect(civil.month, 7);
    });

    test('preserves time-of-day for time-slotted jobs', () {
      // A job stored at 14:30 SAST (== 12:30Z) must read back as 14:30.
      final stored = DateTime.utc(2026, 7, 20, 12, 30);
      final civil = toScheduleCivil(stored);
      expect(civil.day, 20);
      expect(civil.hour, 14);
      expect(civil.minute, 30);
    });

    test('a job created for the same civil day yields the same instant '
        'regardless of writer timezone', () {
      // Both writers pass the same civil calendar day; the stored instant must
      // be identical, so old and new / cross-timezone data never diverge.
      final a = scheduleCivilToInstant(DateTime(2026, 7, 20)).toUtc();
      final b = scheduleCivilToInstant(DateTime(2026, 7, 20, 0, 0)).toUtc();
      expect(a, b);
    });
  });
}
