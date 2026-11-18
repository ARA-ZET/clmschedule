// Marking or removing a day off shows on the grid at once — before
// Firestore's cache or the server has it — and is saved behind.
import 'package:clmschedule/providers/day_off_provider.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final day = DateTime(2026, 11, 12);

  test('marking shows at once and is saved', () async {
    final db = FakeFirebaseFirestore();
    final p = DayOffProvider(firestore: db)..initialize();
    var notified = 0;
    p.addListener(() => notified++);

    final save = p.markDayOff('d1', day);
    expect(p.isDayOff('d1', day), isTrue, reason: 'before the save');
    expect(notified, greaterThan(0));

    await save;
    await pumpEventQueue();
    final doc = await db.collection('distributorDaysOff').doc('d1').get();
    expect(doc.data()!['dates'], ['2026-11-12']);
    expect(p.isDayOff('d1', day), isTrue, reason: 'stream agrees');
    p.dispose();
  });

  test('removing shows at once and is saved', () async {
    final db = FakeFirebaseFirestore();
    await db
        .collection('distributorDaysOff')
        .doc('d1')
        .set({'dates': ['2026-11-12', '2026-11-13']});
    final p = DayOffProvider(firestore: db)..initialize();
    await pumpEventQueue();
    expect(p.isDayOff('d1', day), isTrue);

    final save = p.removeDayOff('d1', day);
    expect(p.isDayOff('d1', day), isFalse, reason: 'before the save');

    await save;
    await pumpEventQueue();
    final doc = await db.collection('distributorDaysOff').doc('d1').get();
    expect(doc.data()!['dates'], ['2026-11-13']);
    expect(p.isDayOff('d1', day), isFalse);
    expect(p.isDayOff('d1', DateTime(2026, 11, 13)), isTrue);
    p.dispose();
  });

  test('removing for a distributor with no days-off doc does not fail',
      () async {
    final db = FakeFirebaseFirestore();
    final p = DayOffProvider(firestore: db)..initialize();
    await p.removeDayOff('nobody', day);
    expect(p.isDayOff('nobody', day), isFalse);
    p.dispose();
  });
}
