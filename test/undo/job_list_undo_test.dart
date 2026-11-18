import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/services/job_list_undo.dart';
import 'package:flutter_test/flutter_test.dart';

final _oct7 = DateTime(2026, 10, 7);

JobListItem _item({
  String client = 'Acme',
  double amount = 100,
  DateTime? date,
  String status = 'standby',
  String zohoInvoiceId = '',
  String folder = '',
}) =>
    JobListItem(
      id: 'j1',
      invoice: '',
      amount: amount,
      client: client,
      jobStatusId: status,
      jobTypeId: 'flyers',
      area: '',
      quantity: 0,
      manDays: 1,
      date: date ?? _oct7,
      collectionAddress: '',
      collectionDate: _oct7,
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
      storageFolderPath: folder,
      zohoInvoiceId: zohoInvoiceId,
    );

void main() {
  test('only the fields the user changed are part of the step', () {
    final keys = changedJobListFields(
        _item(), _item(date: DateTime(2026, 10, 9), status: 'done'));
    expect(keys, unorderedEquals(['date', 'jobStatusId']));
  });

  test('system-owned and invoice fields are never undoable', () {
    final keys = changedJobListFields(
        _item(), _item(zohoInvoiceId: 'inv-9', folder: 'Distribution/x'));
    expect(keys, isEmpty);
  });

  test('undo copies back only the step fields, keeping later changes', () {
    final before = _item(amount: 100);
    final after = _item(amount: 250);
    final keys = changedJobListFields(before, after);
    // Meanwhile someone linked an invoice and changed the status.
    final current = _item(amount: 250, status: 'done', zohoInvoiceId: 'inv-9');

    expect(jobListFieldsMatch(current, after, keys), isTrue);
    final reverted = copyJobListFields(current, before, keys);
    expect(reverted.amount, 100);
    expect(reverted.jobStatusId, 'done');
    expect(reverted.zohoInvoiceId, 'inv-9');
  });

  test('a field changed since makes the step a conflict', () {
    final before = _item(client: 'Acme');
    final after = _item(client: 'Acme Ltd');
    final keys = changedJobListFields(before, after);
    final current = _item(client: 'ACME Holdings');
    expect(jobListFieldsMatch(current, after, keys), isFalse);
  });

  test('labels name the change', () {
    expect(describeJobListEdit(_item(), ['date']), 'Acme: change date');
    expect(describeJobListEdit(_item(), ['amount', 'amountExclVat']),
        'Acme: change amount');
  });
}
