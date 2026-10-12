// Report-mode folder picker: every folder path arrives at once and is grouped
// by month, so choosing one is instant and can't race a half-loaded listing.
import 'package:clmschedule/track_editor/widgets/te_folder_picker_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _paths = [
  'Distribution/2026/Aug 2026/Checkers Bellville',
  'Distribution/2026/Sep 2026/Pick n Pay Durbanville/Round 2',
  'Distribution/2026/Sep 2026/Pick n Pay Durbanville/Round 10',
  'Distribution/2026/Sep 2026/Pick n Pay Durbanville/proof',
  'Distribution/2026/Sep 2026/Checkers Bellville',
  'Distribution/2026/Sep 2026/_compiled',
  'Distribution/2025/Dec 2025/Spar Retreat',
  'Distribution/_proof/2026-9-1',
  'Letterbox/2026/Sep 2026/Other',
];

void main() {
  group('teFolderMonthGroups', () {
    test('groups by month, newest first, clients A–Z, rounds in order', () {
      final groups = teFolderMonthGroups(_paths);
      expect([for (final g in groups) g.label],
          ['Sep 2026', 'Aug 2026', 'Dec 2025']);

      final sep = groups.first;
      expect(sep.path, 'Distribution/2026/Sep 2026');
      expect([for (final f in sep.folders) f.name],
          ['Checkers Bellville', 'Pick n Pay Durbanville']);
      // Round 10 after Round 2; the report's own proof folder left out.
      expect([for (final c in sep.folders[1].children) c.name],
          ['Round 2', 'Round 10']);
    });

    test('leaves out system folders and other roots', () {
      final all = [
        for (final g in teFolderMonthGroups(_paths))
          for (final f in g.folders) f.path,
      ];
      expect(all.any((p) => p.contains('_')), isFalse);
      expect(all.any((p) => p.startsWith('Letterbox')), isFalse);
    });

    test('search matches a client in any month', () {
      final groups = teFolderMonthGroups(_paths, query: 'checkers');
      expect([for (final g in groups) g.label], ['Sep 2026', 'Aug 2026']);
      expect(groups.every((g) => g.folders.single.name == 'Checkers Bellville'),
          isTrue);
    });

    test('search on a round keeps only that round under its client', () {
      final groups = teFolderMonthGroups(_paths, query: 'round 10');
      expect(groups, hasLength(1));
      final client = groups.single.folders.single;
      expect(client.name, 'Pick n Pay Durbanville');
      expect([for (final c in client.children) c.name], ['Round 10']);
    });

    test('search on a month keeps the whole month', () {
      final groups = teFolderMonthGroups(_paths, query: 'dec 2025');
      expect(groups.single.folders.single.name, 'Spar Retreat');
    });
  });

  testWidgets('tapping a folder selects it at once and confirms it',
      (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showDialog<String>(
              context: context,
              builder: (_) => TEFolderPickerDialog(
                rootPath: 'Distribution',
                loadPaths: () async => _paths,
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Nothing chosen yet, so nothing can be confirmed by accident.
    final confirm = find.widgetWithText(FilledButton, 'Use this folder');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    // Newest month is open; search narrows to one client.
    expect(find.text('Checkers Bellville'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'pick n pay');
    await tester.pumpAndSettle();
    expect(find.text('Checkers Bellville'), findsNothing);

    await tester.tap(find.text('Round 10'));
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(
        result, 'Distribution/2026/Sep 2026/Pick n Pay Durbanville/Round 10');
  });
}
