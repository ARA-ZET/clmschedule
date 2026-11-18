// Time-slot job-list jobs (collections, window cleaning…) are appointments.
// The booked time is kept apart from Start — which route calculation turns
// into the arrival estimate — and shown first in Details.
import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/dropsheet_task.dart';
import 'package:clmschedule/providers/dropsheet_provider.dart';

DropsheetTask _task({String details = '', String start = '', String? booked}) =>
    DropsheetTask(
      id: 't',
      type: DropsheetTaskType.collection,
      details: details,
      startTime: start,
      typeData: {
        if (booked != null) DropsheetTask.kAppointmentTimeKey: booked,
      },
    );

void main() {
  group('appointment label', () {
    DropsheetTask booked(String job,
            {String time = '10:00', String address = '28 Yeoville Rd'}) =>
        DropsheetTask(
          id: 't',
          type: DropsheetTaskType.collection,
          job: job,
          location: address,
          typeData: {
            DropsheetTask.kAppointmentTimeKey: time,
            'address': address,
          },
        );

    test('type @time: client, address', () {
      expect(booked('Collection: Max Second load').displayJob,
          'Collection @10:00: Max Second load, 28 Yeoville Rd');
    });

    test('a label the user reworded still gets the time', () {
      expect(booked('Collection: Ri, Newlands', address: '9 Sans Souci Road')
              .displayJob,
          'Collection @10:00: Ri, Newlands, 9 Sans Souci Road');
    });

    test('a stale time is replaced and the address not repeated', () {
      expect(
          booked('Collection @09:00: Max Second load, 28 Yeoville Rd',
                  time: '11:30')
              .displayJob,
          'Collection @11:30: Max Second load, 28 Yeoville Rd');
    });

    test('a label without a colon', () {
      expect(booked('Window cleaning', address: '').displayJob,
          'Window cleaning @10:00');
    });

    test('no booking: the label as stored', () {
      expect(
          const DropsheetTask(
                  id: 't',
                  type: DropsheetTaskType.collection,
                  job: 'Collection: Max Second load')
              .displayJob,
          'Collection: Max Second load');
    });
  });

  test('Details are just the notes; Start can hold the route ETA', () {
    final t = _task(details: 'Take collection tools', start: '09:42',
        booked: '10:00');
    expect(t.detailsText, 'Take collection tools');
    expect(t.appointmentTime, '10:00');
  });

  test('early and late show against the booking', () {
    DropsheetTask timed(Map<String, dynamic> extra) => DropsheetTask(
          id: 't',
          type: DropsheetTaskType.collection,
          typeData: {DropsheetTask.kAppointmentTimeKey: '10:00', ...extra},
        );
    expect(timed({DropsheetTask.kAppointmentWaitKey: 18}).bookingTimingNote,
        '18 min early for the 10:00 booking — wait');
    expect(timed({DropsheetTask.kAppointmentLateKey: 12}).bookingTimingNote,
        '12 min late for the 10:00 booking');
    expect(timed({}).bookingTimingNote, isNull);
  });

  test('Arrive keeps its target in Start; the return shows in Details', () {
    const arrive = DropsheetTask(
      id: 'r',
      type: DropsheetTaskType.arrive,
      startTime: '17:30',
      isMandatory: true,
      typeData: {'eta': '12:10'},
    );
    expect(arrive.startTime, '17:30');
    expect(arrive.detailsText, 'Back ~12:10');
    expect(arrive.copyWith(typeData: {'eta': '17:30'}).detailsText, '');
  });

  group('Start when the job-list task is rebuilt', () {
    test('a new task starts at its appointment', () {
      expect(DropsheetProvider.startTimeForTest(null, '10:00'), '10:00');
    });

    test('a rebooked slot replaces the old one in Start', () {
      final t = _task(start: '10:00', booked: '10:00');
      expect(DropsheetProvider.startTimeForTest(t, '11:30'), '11:30');
    });

    test('an empty Start takes the appointment', () {
      expect(DropsheetProvider.startTimeForTest(_task(), '10:00'), '10:00');
    });

    test('a route ETA (or own time) in Start is kept', () {
      final t = _task(start: '09:42', booked: '10:00');
      expect(DropsheetProvider.startTimeForTest(t, '10:00'), '09:42');
    });
  });
}
