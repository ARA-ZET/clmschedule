import 'package:clmschedule/shareable_maps/utils/map_copy_description.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final oct = DateTime(2026, 10, 16);
  final nov = DateTime(2026, 11, 2);

  test('empty source is just the month', () {
    expect(copyDescription('', oct), 'October 2026');
  });

  test('month leads the source description', () {
    expect(copyDescription('Rondebosch flats', nov),
        'November 2026\nRondebosch flats');
  });

  test('a copy of a copy replaces the month, never stacks it', () {
    expect(copyDescription('October 2026\nRondebosch', nov),
        'November 2026\nRondebosch');
    expect(copyDescription('October 2026', nov), 'November 2026');
  });
}
