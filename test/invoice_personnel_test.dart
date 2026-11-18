import 'package:clmschedule/models/distribution_report_template.dart';
import 'package:clmschedule/utils/invoice_personnel.dart';
import 'package:flutter_test/flutter_test.dart';

/// What lands on Chand's invoice lines: who did the work, by legal name and
/// ID, added under the line's own description — which is never cut.
void main() {
  const francis =
      DistributionReportPerson(name: 'Francis Kabetsha', idNumber: 'MA 210093');
  const petros =
      DistributionReportPerson(name: 'Petros Muvimbi', idNumber: 'FN 186040');

  test('adds new lines under the existing description, keeping all of it', () {
    const existing = 'Flyer distribution — Claremont\nPrinted A5, 2 sides';
    expect(
      withPersonnelBlock(existing, [francis, petros]),
      'Flyer distribution — Claremont\n'
      'Printed A5, 2 sides\n'
      'Personnel:\n'
      'Francis Kabetsha — ID/Passport: MA 210093\n'
      'Petros Muvimbi — ID/Passport: FN 186040',
    );
  });

  test('running it again updates its own list and keeps everything else', () {
    final once = withPersonnelBlock('Claremont', [francis, petros]);
    // Text typed below the list after the first run.
    final edited = '$once\nPlease pay within 30 days';
    final twice = withPersonnelBlock(edited, [petros]);

    expect(twice, contains('Claremont'));
    expect(twice, contains('Please pay within 30 days'));
    expect(twice, isNot(contains('Francis Kabetsha')));
    expect('Personnel:'.allMatches(twice).length, 1);
    expect(
        twice, endsWith('Personnel:\nPetros Muvimbi — ID/Passport: FN 186040'));
  });

  test('a line that only resembles a name is not the list, and stays', () {
    // "Petros Muvimbi" outside a Personnel block is the user's own text.
    const existing = 'Supervisor on site: Petros Muvimbi';
    expect(withPersonnelBlock(existing, [petros]),
        startsWith('Supervisor on site: Petros Muvimbi\nPersonnel:'));
  });

  test('no people leaves the description exactly as it was', () {
    const existing = 'Claremont\nPersonnel:\nSomeone — ID/Passport: X';
    expect(withPersonnelBlock(existing, const []), existing);
  });

  test('an empty description gets just the list; no ID means name only', () {
    expect(
        withPersonnelBlock(
            '', const [DistributionReportPerson(name: 'Dickson Banda')]),
        'Personnel:\nDickson Banda');
  });

  test('poster lines get the poster team, other lines the leaflet team', () {
    List<DistributionReportPerson> forLine(String text,
            {List<DistributionReportPerson> leaflets = const [francis, petros],
            List<DistributionReportPerson> posters = const [petros]}) =>
        personnelForLine(lineText: text, leaflets: leaflets, posters: posters);

    expect(forLine('Poster placement — Claremont'), [petros]);
    expect(forLine('Flyer distribution — Claremont'), [francis, petros]);
    // One kind of job only: everyone on every line.
    expect(forLine('Flyer distribution', posters: const []), [francis, petros]);
    expect(forLine('Distribution', leaflets: const []), [petros]);
  });
}
