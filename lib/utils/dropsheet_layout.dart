import '../models/dropsheet_day.dart';
import 'shared_drop_points.dart' show stopNumbersFor;

/// One layout for a driver's dropsheet, on screen (driver_section_widget /
/// dropsheet_task_row) and on the printed PDF (dropsheet_pdf), so the two
/// read the same: same columns, same names, same proportions, same numbers.

/// The table's columns, left to right.
enum DropsheetColumn {
  number('#'),
  job('Job'),
  details('Details'),
  start('Start'),
  location('Location'),
  contact('Contact'),
  tel('Tel');

  const DropsheetColumn(this.title);
  final String title;

  /// Share of the flexible width; null for the fixed-width columns.
  int? get flex => switch (this) {
        DropsheetColumn.job => 2,
        DropsheetColumn.details => 3,
        DropsheetColumn.location => 3,
        DropsheetColumn.contact => 2,
        DropsheetColumn.tel => 2,
        DropsheetColumn.number || DropsheetColumn.start => null,
      };

  /// Width on the printed A4 sheet (≈782pt across): points when fixed,
  /// else a flex share of what is left. Contact and Tel only need a name
  /// and a phone number, so they are fixed narrow and the spare width
  /// goes to Job — whose label carries the client, booked time and address
  /// — so it fits on one line more often.
  ({double? points, double? flex}) get printWidth => switch (this) {
        DropsheetColumn.number => (points: 24, flex: null),
        DropsheetColumn.start => (points: 40, flex: null),
        DropsheetColumn.contact => (points: 92, flex: null),
        // Fits "+27 83 266 1680" on one line.
        DropsheetColumn.tel => (points: 84, flex: null),
        DropsheetColumn.job => (points: null, flex: 4),
        DropsheetColumn.details => (points: null, flex: 2),
        DropsheetColumn.location => (points: null, flex: 2),
      };
}

/// The stop numbers a section's rows show: the day planner map's pin numbers
/// (see [stopNumbersFor]). The fixed Inspect / Pack / Leave / Arrive rows
/// and anything without a location have none.
Map<String, int> dropsheetRowNumbers(DropsheetDriverSection section) =>
    stopNumbersFor(section);

/// Label of the "Leave and start pickups" divider row.
const String kPickupDividerLabel = 'Leave and start pickups';
