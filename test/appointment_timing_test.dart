// Booked appointments in route timing: wait when early, flag when late, and
// only fit other stops in before a booking while they still leave time to
// reach it.
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:clmschedule/services/appointment_timing.dart';

DateTime _at(int h, int m) => DateTime(2026, 10, 21, h, m);
const _here = LatLng(-33.90, 18.40);
const _near = LatLng(-33.901, 18.401); // ~150 m
const _far = LatLng(-34.05, 18.60); // ~25 km

NextStopOption _opt(int travelMin,
        {int service = 10, int? booked, LatLng position = _near}) =>
    (
      travelSeconds: travelMin * 60,
      serviceMinutes: service,
      appointmentMinutes: booked,
      position: position,
    );

void main() {
  test('hhmmToMinutes', () {
    expect(hhmmToMinutes('10:00'), 600);
    expect(hhmmToMinutes(' 07:45 '), 465);
    expect(hhmmToMinutes(''), isNull);
    expect(hhmmToMinutes('25:00'), isNull);
  });

  group('meetAppointment', () {
    test('early: work starts at the booked time', () {
      final m = meetAppointment(_at(9, 40), 600);
      expect(m.start, _at(10, 0));
      expect(m.waitMinutes, 20);
      expect(m.lateMinutes, 0);
    });
    test('late: work starts on arrival, flagged', () {
      final m = meetAppointment(_at(10, 12), 600);
      expect(m.start, _at(10, 12));
      expect(m.lateMinutes, 12);
    });
    test('no booking: arrival is the start', () {
      expect(meetAppointment(_at(9, 40), null).start, _at(9, 40));
    });
  });

  group('chooseNextStop', () {
    test('no bookings: nearest', () {
      expect(chooseNextStop([_opt(12), _opt(5), _opt(9)], _at(8, 0)), 1);
    });

    test('fits a nearby stop in before a booking it still makes', () {
      // 08:00; booking at 10:00 is 20 min away; a 5-min stop next door fits.
      final options = [
        _opt(20, booked: 600, position: _here),
        _opt(5, position: _near),
      ];
      expect(chooseNextStop(options, _at(8, 0)), 1);
    });

    test('goes to the booking when the other stop would make it late', () {
      // 09:30; booking at 10:00 is 20 min away. The other stop is 5 min
      // away but 25 km from the booking — can't get back in time.
      final options = [
        _opt(20, booked: 600, position: _here),
        _opt(5, service: 15, position: _far),
      ];
      expect(chooseNextStop(options, _at(9, 30)), 0);
    });

    test('goes to the booking once it is due', () {
      final options = [_opt(30, booked: 600), _opt(1)];
      expect(chooseNextStop(options, _at(9, 35)), 0);
    });

    test('earliest booking first when only bookings remain', () {
      final options = [_opt(5, booked: 660), _opt(25, booked: 600)];
      expect(chooseNextStop(options, _at(8, 0)), 1);
    });
  });

  group('fixed-order runs', () {
    TimedStop stop(int legMin, {int service = 10, int? booked}) =>
        (legSeconds: legMin * 60, serviceMinutes: service, appointment: booked);

    test('forward: a wait pushes later stops back', () {
      // Leave 08:00 → A 08:20 (booked 09:00: wait 40) → B 09:10+15 = 09:25.
      final t = timeRunForward([stop(20, booked: 540), stop(15)], 8 * 3600,
          returnLegSeconds: 10 * 60);
      expect(t.startSeconds.map(secondsToHHmm), ['09:00', '09:25']);
      expect(t.waitMinutes, [40, 0]);
      expect(secondsToHHmm(t.endSeconds), '09:45');
    });

    test('to arrive: without bookings ends exactly at the target', () {
      final t = timeRunToArrive([stop(20), stop(15)], 17 * 3600, 10 * 60);
      expect(secondsToHHmm(t.endSeconds), '17:00');
      expect(t.startSeconds.map(secondsToHHmm), ['16:15', '16:40']);
    });

    test('to arrive: starts earlier rather than miss a booking', () {
      // Latest plan reaches the 15:30 booking at 16:15 — start 45 min earlier.
      final t = timeRunToArrive(
          [stop(20, booked: 15 * 60 + 30), stop(15)], 17 * 3600, 10 * 60);
      expect(secondsToHHmm(t.startSeconds.first), '15:30');
      expect(t.lateMinutes, [0, 0]);
      expect(secondsToHHmm(t.endSeconds), '16:15');
    });

    test('to arrive: a booking after the latest plan means back later', () {
      // Booked 16:50; latest plan reaches it 16:15 → waits 35 min.
      final t = timeRunToArrive(
          [stop(20, booked: 16 * 60 + 50), stop(15)], 17 * 3600, 10 * 60);
      expect(secondsToHHmm(t.startSeconds.first), '16:50');
      expect(t.waitMinutes.first, 35);
      expect(secondsToHHmm(t.endSeconds), '17:35');
    });
  });

  test('estimateDriveSeconds is town-speed-ish', () {
    // ~25 km straight line → ~35 km road at 35 km/h ≈ 1 h.
    expect(estimateDriveSeconds(_here, _far) / 3600, closeTo(1.0, 0.3));
  });
}
