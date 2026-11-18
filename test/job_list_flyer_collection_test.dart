// "Needs flyer collection" on Community Life Media Job List jobs: a plain
// tick that is saved, read back, cleared, recorded in the job's history and
// covered by Undo.
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/services/job_list_undo.dart';
import 'package:flutter_test/flutter_test.dart';

JobListItem _item({bool needsFlyerCollection = false}) {
  final date = DateTime(2026, 11, 20);
  return JobListItem(
    id: 'jl-1',
    invoice: '',
    amount: 0,
    client: 'Timbuild',
    jobStatusId: 'standby',
    jobTypeId: 'flyers',
    area: '',
    quantity: 0,
    manDays: 8,
    date: date,
    collectionAddress: '',
    collectionDate: date,
    needsFlyerCollection: needsFlyerCollection,
    specialInstructions: '',
    quantityDistributed: 0,
    invoiceDetails: '',
    reportAddresses: '',
    whoToInvoice: '',
  );
}

void main() {
  test('is off unless ticked, and old jobs without the field read as off', () {
    expect(_item().needsFlyerCollection, isFalse);
    final old = Map<String, dynamic>.from(_item().toMap())
      ..remove('needsFlyerCollection');
    expect(JobListItem.fromMap('jl-1', old).needsFlyerCollection, isFalse);
  });

  test('a tick survives the save and read back', () {
    final map = _item(needsFlyerCollection: true).toMap();
    expect(map['needsFlyerCollection'], isTrue);
    expect(JobListItem.fromMap('jl-1', map).needsFlyerCollection, isTrue);
  });

  test('an untick is written too, so the update clears it on the server', () {
    // Job List edits are Firestore update() calls: a field left out of the
    // map would keep its old value, and the tick could never be removed.
    final map = _item().toMap();
    expect(map.containsKey('needsFlyerCollection'), isTrue);
    expect(map['needsFlyerCollection'], isFalse);
  });

  test('a change is recorded in the job history as Yes / No', () {
    final ticked = _item().copyWithTrackedChange(
      userId: 'u1',
      userDisplayName: 'Barrie',
      needsFlyerCollection: true,
    );
    expect(ticked.needsFlyerCollection, isTrue);
    final update = ticked.updates.last;
    expect(update.fieldName, 'needsFlyerCollection');
    expect(update.oldValueDisplay, 'No');
    expect(update.newValueDisplay, 'Yes');

    final same = ticked.copyWithTrackedChange(
      userId: 'u1',
      userDisplayName: 'Barrie',
      needsFlyerCollection: true,
    );
    expect(same.updates, hasLength(ticked.updates.length),
        reason: 'no change, nothing recorded');
  });

  test('Undo sees the tick as a change and can put it back', () {
    final before = _item();
    final after = _item(needsFlyerCollection: true);
    final keys = changedJobListFields(before, after);
    expect(keys, ['needsFlyerCollection']);
    expect(describeJobListEdit(after, keys), 'Timbuild: change flyer collection');
    expect(copyJobListFields(after, before, keys).needsFlyerCollection,
        isFalse);
  });
}
