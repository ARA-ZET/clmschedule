import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/track_upload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final distributors = [
    Distributor(id: 'd1', name: 'Thabo Mokoena', index: 0),
    Distributor(id: 'd2', name: 'Sipho  Ndlovu', index: 1),
    Distributor(id: 'd3', name: 'Anne-Marie', index: 2),
  ];
  final oct14 = DateTime(2026, 10, 14);
  final oct15 = DateTime(2026, 10, 15);

  TrackUpload ping(String name, {String? id, String date = '2026-10-14'}) =>
      TrackUpload(distributorId: id, distributorName: name, date: date);

  test('day id is yyyy-MM-dd', () {
    expect(trackUploadDayId(DateTime(2026, 3, 7)), '2026-03-07');
  });

  test('normalises case, spacing and punctuation', () {
    expect(normalizePersonName('  Anne-Marie  '), 'anne marie');
    expect(normalizePersonName('SIPHO   ndlovu'), 'sipho ndlovu');
  });

  test('matches by id first, even when the name differs', () {
    final idx = TrackUploadIndex.build([ping('Old Name', id: 'd1')], distributors);
    expect(idx.isUploaded('d1', oct14), isTrue);
    expect(idx.unmatchedOn(oct14), isEmpty);
  });

  test('falls back to a normalised name match', () {
    final idx = TrackUploadIndex.build(
        [ping('sipho ndlovu'), ping('anne marie')], distributors);
    expect(idx.isUploaded('d2', oct14), isTrue);
    expect(idx.isUploaded('d3', oct14), isTrue);
  });

  test('unknown id with unknown name is no match, deduped and sorted', () {
    final idx = TrackUploadIndex.build([
      ping('Peter K', id: 'gone'),
      ping('peter k '),
      ping('Bongani'),
    ], distributors);
    expect(idx.unmatchedOn(oct14), ['Bongani', 'Peter K']);
  });

  test('uploads are kept per day', () {
    final idx = TrackUploadIndex.build(
        [ping('Thabo Mokoena', date: '2026-10-15')], distributors);
    expect(idx.isUploaded('d1', oct14), isFalse);
    expect(idx.isUploaded('d1', oct15), isTrue);
    expect(idx.uploadedOn(oct15).keys, ['d1']);
  });

  test('keeps the latest upload time for a distributor', () {
    final idx = TrackUploadIndex.build([
      TrackUpload(
          distributorId: 'd1',
          distributorName: 'x',
          date: '2026-10-14',
          uploadedAt: DateTime(2026, 10, 14, 9)),
      TrackUpload(
          distributorName: 'Thabo Mokoena',
          date: '2026-10-14',
          uploadedAt: DateTime(2026, 10, 14, 17)),
    ], distributors);
    expect(idx.uploadedOn(oct14)['d1'], DateTime(2026, 10, 14, 17));
  });
}
