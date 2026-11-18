import 'dart:typed_data';

import 'package:clmschedule/models/distribution_report.dart';
import 'package:clmschedule/models/distribution_report_draft.dart';
import 'package:clmschedule/models/distribution_report_template.dart';
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/job_invoice_link.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/models/xero_invoice.dart';
import 'package:clmschedule/models/xero_org.dart';
import 'package:clmschedule/providers/company_provider.dart';
import 'package:clmschedule/providers/xero_items_provider.dart';
import 'package:clmschedule/providers/xero_tax_rates_provider.dart';
import 'package:clmschedule/models/company.dart';
import 'package:clmschedule/services/xero_accounting_service.dart';
import 'package:clmschedule/providers/distribution_report_template_provider.dart';
import 'package:clmschedule/providers/distributor_provider.dart';
import 'package:clmschedule/providers/job_list_provider.dart';
import 'package:clmschedule/providers/job_type_provider.dart';
import 'package:clmschedule/services/distribution_report_draft_service.dart';
import 'package:clmschedule/services/job_list_service.dart';
import 'package:clmschedule/track_editor/models/te_promoter_day.dart';
import 'package:clmschedule/track_editor/providers/te_report_provider.dart';
import 'package:clmschedule/track_editor/services/te_folder_photos.dart';
import 'package:clmschedule/widgets/distribution_report_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;

/// Lays the report page out at phone and desktop sizes with no Firebase.
///
/// Flutter fails a test on any RenderFlex overflow, so these catch text and
/// rows that do not fit — the layout faults a dialog-to-page move invites.

JobListItem _job(String id, String client, String type, DateTime date,
        {String invoiceNumber = '', String invoiceStatus = 'AUTHORISED'}) =>
    JobListItem(
      // Linked the way linkAccountingInvoiceTxn links a Xero invoice —
      // Chand is billed through Xero.
      invoiceProviderId: invoiceNumber.isEmpty ? '' : 'xero',
      accountingInvoiceId: invoiceNumber.isEmpty ? '' : 'xi-$id',
      accountingInvoiceNumber: invoiceNumber,
      accountingInvoiceStatus: invoiceNumber.isEmpty ? '' : invoiceStatus,
      id: id,
      invoice: '',
      amount: 0,
      client: client,
      jobStatusId: 'done',
      jobTypeId: type,
      area: '',
      quantity: 5000,
      manDays: 2,
      date: date,
      collectionAddress: '',
      collectionDate: date,
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: 'nikita@chand.co.za',
      whoToInvoice: '',
    );

DistributionReport _report(JobListItem job,
        {required String code,
        required int count,
        required int photos,
        required List<String> names}) =>
    DistributionReport(
      jobId: job.id,
      client: job.client,
      jobDate: job.date,
      quantityOrdered: job.quantity,
      mapLink: 'https://maps.communitylifemedia.co.za/map/$code',
      shareCode: code,
      areas: const ['Claremont'],
      recipients: const ['nikita@chand.co.za'],
      hasInvoice: true,
      invoiceNumber: 'INV-1042',
      folders: [
        DistributionReportFolder(
          path: 'Distribution/2026/Oct 2026/${job.client}',
          waypointCount: count,
          photoCount: photos,
          workerNames: names,
          earliestStart: DateTime.utc(2026, 10, 22, 7),
          dateSource: DistributionDateSource.trackTimes,
        ),
      ],
    );

class _Templates extends ChangeNotifier
    implements DistributionReportTemplateProvider {
  @override
  List<DistributionReportTemplate> get available =>
      DistributionReportTemplate.builtIns;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Distributors extends ChangeNotifier implements DistributorProvider {
  @override
  List<Distributor> get distributors => [
        Distributor(
            id: 'd1',
            name: 'Petros',
            index: 0,
            fullName: 'Petros Muvimbi',
            idNumber: 'FN 186040'),
        Distributor(
            id: 'd2', name: 'Francis', index: 1, fullName: 'Francis Kabetsha'),
      ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _JobTypes extends ChangeNotifier implements JobTypeProvider {
  @override
  String getJobTypeLabel(String id) =>
      id == 'postering' ? 'Postering' : 'Flyer Distribution';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _JobList extends ChangeNotifier implements JobListProvider {
  _JobList(this.items);
  final List<JobListItem> items;
  @override
  List<JobListItem> get jobListItems => items;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _JobListService implements JobListService {
  _JobListService(this.items);
  final List<JobListItem> items;

  /// Each job re-link, as (jobId, invoiceNumber, subTotal).
  final linked = <(String, String, double)>[];

  @override
  Future<void> linkAccountingInvoiceTxn({
    required String jobId,
    required DateTime date,
    required String providerId,
    required String contactId,
    required String invoiceId,
    required String invoiceNumber,
    required String invoiceStatus,
    required double subTotal,
    required double total,
  }) async =>
      linked.add((jobId, invoiceNumber, subTotal));

  @override
  Future<JobListItem?> getJobListItemById(String id, [DateTime? date]) async =>
      [_leaflets, _posters].where((j) => j.id == id).firstOrNull;

  @override
  Future<List<JobListItem>> getJobListItemsForClients(
          Iterable<String> clients, Iterable<DateTime> months) async =>
      items;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Xero as Chand's invoice stands in it: one flyers line, a customer name
/// longer than the Job List's "Chand".
class FakeXero implements XeroAccountingService {
  FakeXero({XeroInvoiceStatus status = XeroInvoiceStatus.authorised})
      : invoice = XeroInvoice(
          invoiceId: 'xi-j1',
          invoiceNumber: 'INV-1042',
          contactId: 'c1',
          contactName: 'Chand Environmental Consultants',
          status: status,
          subTotal: 3500,
          total: 3500,
          lineItems: const [
            XeroLineItem(
              lineItemId: 'l1',
              description: 'Flyer distribution — Claremont',
              quantity: 5000,
              unitAmount: 0.7,
              accountCode: '200',
            ),
          ],
        );

  final updates = <Map<String, dynamic>>[];

  XeroInvoice invoice;

  @override
  Future<XeroInvoice> getInvoice(String invoiceId) async => invoice;

  @override
  Future<XeroInvoice> updateInvoice(
    String invoiceId,
    Map<String, dynamic> changes, {
    String? idempotencyKey,
  }) async {
    updates.add(changes);
    return invoice;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TaxRates extends ChangeNotifier implements XeroTaxRatesProvider {
  @override
  bool get hasLoaded => true;
  @override
  bool get isLoading => false;
  @override
  String? get error => null;
  @override
  List<XeroTaxRate> get rates => const [];
  @override
  XeroTaxRate? byType(String taxType) => null;
  @override
  double? percentFor(String taxType) => null;
  @override
  Future<void> ensureLoaded() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _XeroItems extends ChangeNotifier implements XeroItemsProvider {
  @override
  List<XeroItem> get items => const [];
  @override
  bool get hasLoaded => true;
  @override
  bool get isLoading => false;
  @override
  String? get error => null;
  @override
  XeroItem? byCode(String code) => null;
  @override
  Future<void> ensureLoaded() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Companies extends ChangeNotifier implements CompanyProvider {
  @override
  Company? getById(String id) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Drafts kept in memory, standing in for Firestore.
class FakeDrafts implements DistributionReportDraftService {
  final Map<String, Map<String, dynamic>> docs = {};
  int saves = 0;

  @override
  Future<DistributionReportDraft?> load(String jobId) async {
    final data = docs[jobId];
    return data == null ? null : DistributionReportDraft.fromMap(jobId, data);
  }

  @override
  Future<void> save(DistributionReportDraft draft) async {
    saves++;
    docs[draft.jobId] = draft.toContentMap();
  }

  @override
  Future<void> delete(String jobId) async => docs.remove(jobId);

  @override
  Stream<Set<String>> watchJobIds() => Stream.value(docs.keys.toSet());
}

final _leaflets = _job(
    'j1', 'Chand', 'flyerDistribution', DateTime.utc(2026, 10, 21, 22),
    invoiceNumber: 'INV-1042');
final _posters =
    _job('j2', 'Chand', 'postering', DateTime.utc(2026, 10, 21, 22));

Future<void> pumpPage(WidgetTester tester, Size size,
    {FakeDrafts? drafts,
    ReportJobEditor? editJob,
    FakeXero? xero,
    _JobListService? jobs,
    JobListItem? item,
    int Function()? posterPhotos,
    Future<void> Function(TEReportProvider report, List<String> folders)?
        scanHandouts}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    overrides: [
      distributionReportTemplateRiverpod.overrideWith((ref) => _Templates()),
      distributorRiverpod.overrideWith((ref) => _Distributors()),
      jobTypeRiverpod.overrideWith((ref) => _JobTypes()),
      jobListRiverpod.overrideWith((ref) => _JobList([_posters])),
      jobListServiceRiverpod
          .overrideWithValue(jobs ?? _JobListService([_posters])),
      xeroAccountingServiceRiverpod.overrideWithValue(xero ?? FakeXero()),
      xeroTaxRatesRiverpod.overrideWith((ref) => _TaxRates()),
      xeroItemsRiverpod.overrideWith((ref) => _XeroItems()),
      companyRiverpod.overrideWith((ref) => _Companies()),
      distributionReportDraftServiceRiverpod
          .overrideWithValue(drafts ?? FakeDrafts()),
    ],
    child: MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: DistributionReportPage(
        item: item ?? _leaflets,
        editJob: editJob,
        scanHandouts: scanHandouts ?? _fakeHandoutScan,
        compileJob: (job) async => job.id == 'j1'
            ? _report(job,
                code: 'LEAF1',
                count: 5000,
                photos: 0,
                names: ['Petros', 'Francis'])
            : _report(job,
                code: 'POST1',
                count: 41,
                photos: posterPhotos?.call() ?? 40,
                names: ['Petros']),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

TEPromoterDay _shift(String id, String name, DateTime date) => TEPromoterDay(
      distributor: Distributor(id: id, name: name, index: 0),
      date: date,
      tracks: const [],
      waypoints: const [],
      sourcePaths: const [],
    );

final Uint8List _png = im.encodePng(im.Image(width: 4, height: 4));

TEProofPhoto _folderPhoto(String name, [DateTime? at]) => TEProofPhoto(
    bytes: _png, fileName: name, storagePath: 'x/$name', takenAt: at);

/// Two promoters at the traffic lights on 22 October and one on the 23rd;
/// three photos on the 22nd and one with no date.
Future<void> _fakeHandoutScan(
    TEReportProvider report, List<String> folders) async {
  report.seedScanForTest([
    _shift('d1', 'Petros', DateTime(2026, 10, 22)),
    _shift('d2', 'Francis', DateTime(2026, 10, 22)),
    _shift('d1', 'Petros', DateTime(2026, 10, 23)),
  ], TEFolderPhotos(byDate: {
    DateTime(2026, 10, 22): [
      _folderPhoto('p1.jpg', DateTime(2026, 10, 22, 8)),
      _folderPhoto('p2.jpg', DateTime(2026, 10, 22, 9)),
      _folderPhoto('p3.jpg', DateTime(2026, 10, 22, 10)),
    ],
  }, undated: [
    _folderPhoto('IMG_4411.jpg'),
  ]));
}

Future<void> chooseTemplate(WidgetTester tester, String name) async {
  await tester.tap(find.text('Choose a report…'), warnIfMissed: false);
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

/// Choose the Flyers & Posters template and pair the poster job.
Future<void> chooseFlyersAndPosters(WidgetTester tester) async {
  await tester.tap(find.text('Choose a report…'), warnIfMissed: false);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Flyers & Posters report').last);
  await tester.pumpAndSettle();

  final picker = find.text('Choose a job');
  await tester.ensureVisible(picker);
  await tester.pumpAndSettle();
  await tester.tap(picker, warnIfMissed: false);
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining('Postering').last);
  await tester.pumpAndSettle();
}

/// Type into the setup field labelled [label], scrolling the (lazily
/// built) setup list to it first.
Future<void> enter(WidgetTester tester, String label, String text) async {
  final setup = find.byType(Scrollable).first;
  await tester.drag(setup, const Offset(0, 3000));
  await tester.pumpAndSettle();
  final field = find.widgetWithText(TextField, label);
  await tester.scrollUntilVisible(field, 200, scrollable: setup);
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

void main() {
  for (final (name, size) in [
    ('desktop', const Size(1440, 900)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets('lays out without overflow on $name, both templates',
        (tester) async {
      await pumpPage(tester, size);
      expect(find.text('Distribution report'), findsOneWidget);
      final phone = size.width < 600;

      await chooseFlyersAndPosters(tester);
      if (phone) {
        // The preview is a tab of its own on a phone.
        await tester.tap(find.text('Preview'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Petros Muvimbi'), findsWidgets);
      // Francis has no ID on file; the page says so rather than sending a gap.
      expect(find.textContaining('ID missing'), findsWidgets);
      expect(find.text('Type a heading'), findsOneWidget);
    });
  }

  testWidgets('the readiness list clears as the fields are filled',
      (tester) async {
    await pumpPage(tester, const Size(1440, 900));
    await chooseFlyersAndPosters(tester);
    expect(find.text('Type a heading'), findsOneWidget);

    await enter(tester, 'Greeting name', 'Nikita');
    await enter(tester, 'Heading', 'MyCiTi Phase 2A');
    await enter(tester, 'Leaflet name', 'Construction Update');

    expect(find.text('Type a heading'), findsNothing);
    expect(find.text('Ready to send'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.ancestor(
                of: find.text('Open Gmail'),
                matching: find.byWidgetPredicate((w) => w is FilledButton)))
            .onPressed,
        isNotNull);
  });

  testWidgets(
      'an invoice copied with an old date in its description is flagged',
      (tester) async {
    final xero = FakeXero();
    xero.invoice = xero.invoice.copyWith(lineItems: const [
      XeroLineItem(
        lineItemId: 'l1',
        description: 'Flyer distribution — Claremont, 15 September 2026',
        quantity: 5000,
        unitAmount: 0.7,
        accountCode: '200',
      ),
    ]);
    await pumpPage(tester, const Size(1440, 900), xero: xero);
    await chooseFlyersAndPosters(tester);
    expect(
        find.textContaining('INV-1042 says 15 September 2026, but the '
            'distribution was on 22 October 2026'),
        findsOneWidget);
  });

  testWidgets('an invoice dated the day of the distribution is not flagged',
      (tester) async {
    final ok = FakeXero();
    ok.invoice = ok.invoice.copyWith(lineItems: const [
      XeroLineItem(
        lineItemId: 'l1',
        description: 'Flyer distribution — Claremont, 22 October 2026',
        quantity: 5000,
        unitAmount: 0.7,
        accountCode: '200',
      ),
    ]);
    await pumpPage(tester, const Size(1440, 900), xero: ok);
    await chooseFlyersAndPosters(tester);
    expect(find.textContaining('INV-1042 says'), findsNothing);
  });

  testWidgets('progress survives leaving the page and coming back',
      (tester) async {
    final drafts = FakeDrafts();
    await pumpPage(tester, const Size(1440, 900), drafts: drafts);
    await chooseFlyersAndPosters(tester);
    await enter(tester, 'Greeting name', 'Nikita');
    await enter(tester, 'Heading', 'MyCiTi Phase 2A');
    // Past the save delay.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(drafts.docs['j1']?['heading'], 'MyCiTi Phase 2A');
    expect(drafts.docs['j1']?['otherJobId'], 'j2');
    expect(find.textContaining('Draft saved'), findsOneWidget);

    // Leave — as switching to another tab does — and come back.
    await tester.pumpWidget(const SizedBox());
    await pumpPage(tester, const Size(1440, 900), drafts: drafts);

    expect(find.text('MyCiTi Phase 2A'), findsWidgets);
    expect(find.text('Nikita'), findsWidgets);
    // The poster job is paired again and its figures recompiled.
    expect(find.textContaining('Postering'), findsWidgets);
    expect(find.text('Petros Muvimbi'), findsWidgets);
    // Restoring is not a change: nothing new is written.
    final before = drafts.saves;
    await tester.pump(const Duration(seconds: 2));
    expect(drafts.saves, before);
  });

  testWidgets(
      'every report has the same subject; an old generated one in a '
      'draft gives way to it', (tester) async {
    final drafts = FakeDrafts()
      ..docs['j1'] = {
        'greeting': 'Nikita',
        'subject': 'Distribution Report — Chand — 22 October 2026',
      };
    await pumpPage(tester, const Size(1440, 900), drafts: drafts);
    expect(find.text('Your flyers distribution report'), findsWidgets);
    expect(find.textContaining('Distribution Report —'), findsNothing);
    expect(find.text('Nikita'), findsWidgets);
  });

  testWidgets('a subject typed into a draft is kept', (tester) async {
    final drafts = FakeDrafts()
      ..docs['j1'] = {'subject': 'Claremont update for Nikita'};
    await pumpPage(tester, const Size(1440, 900), drafts: drafts);
    expect(find.text('Claremont update for Nikita'), findsWidgets);
  });

  test('invoice attachments are named "Client - Invoice number"', () {
    expect(
      reportInvoiceFileName(
          const JobInvoiceLink(
              providerId: 'zoho', invoiceId: 'z1', invoiceNumber: 'INV-1042'),
          _leaflets),
      'Chand - INV-1042.pdf',
    );
    // Once the invoice has loaded: the customer exactly as Xero names it.
    expect(
      reportInvoiceFileName(
          const JobInvoiceLink(
              providerId: 'xero', invoiceId: 'x1', invoiceNumber: 'INV-1042'),
          _leaflets,
          customerName: 'Chand Environmental Consultants'),
      'Chand Environmental Consultants - INV-1042.pdf',
    );
    // A split invoice is named for its own customer.
    expect(
      reportInvoiceFileName(
          const JobInvoiceLink(
              providerId: 'xero',
              invoiceId: 'x1',
              invoiceNumber: 'INV-0007',
              contactName: 'City of Cape Town'),
          _leaflets),
      'City of Cape Town - INV-0007.pdf',
    );
  });

  testWidgets(
      'the job\'s Xero invoice opens under the preview, named after '
      'the Xero customer, with a reminder to add the personnel',
      (tester) async {
    await pumpPage(tester, const Size(1440, 900));
    await chooseFlyersAndPosters(tester);
    expect(find.text('Save to Xero'), findsOneWidget);
    expect(find.text('Add personnel to lines'), findsOneWidget);
    expect(
        find.textContaining(
            'attached as Chand Environmental Consultants - INV-1042.pdf'),
        findsOneWidget);
    // One invoice between the leaflet and poster jobs.
    expect(find.textContaining('shared by the leaflet and poster jobs'),
        findsOneWidget);
    expect(
        find.textContaining('Add the personnel to INV-1042'), findsOneWidget);
  });

  testWidgets(
      'Add personnel fills the editor; Save to Xero saves the lines '
      'and brings the job\'s amount in line', (tester) async {
    final xero = FakeXero();
    final jobs = _JobListService([_posters]);
    await pumpPage(tester, const Size(1440, 900), xero: xero, jobs: jobs);
    await chooseFlyersAndPosters(tester);

    final add = find.text('Add personnel to lines');
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();

    // In the editor, where they can be seen and checked before saving.
    expect(
        find.byWidgetPredicate((w) =>
            w is EditableText &&
            w.controller.text.startsWith('Flyer distribution — Claremont\n'
                'Personnel:\nPetros Muvimbi — ID/Passport: FN 186040')),
        findsOneWidget);
    // Not saved yet: sending now would attach the old invoice.
    expect(find.text('Personnel added — save below'), findsOneWidget);
    expect(
        find.textContaining('Save INV-1042 — the personnel'), findsOneWidget);
    expect(xero.updates, isEmpty);

    final save = find.text('Save to Xero');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(xero.updates, hasLength(1));
    final lines = xero.updates.single['LineItems'] as List;
    final description = (lines.single as Map)['Description'] as String;
    // The existing description stays; the personnel are added under it.
    expect(
        description, startsWith('Flyer distribution — Claremont\nPersonnel:'));
    expect(description, contains('Petros Muvimbi — ID/Passport: FN 186040'));
    expect(jobs.linked, [('j1', 'INV-1042', 3500.0)]);
    expect(find.text('Personnel saved · Add again'), findsOneWidget);
    expect(find.textContaining('Add the personnel to INV-1042'), findsNothing);
  });

  testWidgets(
      'a job without an invoice offers to create one through the '
      'Edit Job dialog', (tester) async {
    final opened = <String>[];
    Future<bool> editJob(BuildContext context, JobListItem job) async {
      opened.add(job.id);
      return false;
    }

    await pumpPage(tester, const Size(1440, 900),
        editJob: editJob, item: _posters);
    final create = find.text('Create invoice');
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(opened, ['j2']);
  });

  testWidgets(
      'an empty poster folder blocks sending until photos are '
      'uploaded and checked again', (tester) async {
    var photos = 0;
    await pumpPage(tester, const Size(1440, 900), posterPhotos: () => photos);
    await chooseFlyersAndPosters(tester);
    // On the poster job, and as a blocking item in the readiness list.
    expect(find.textContaining('No photos in the poster folder'),
        findsNWidgets(2));

    photos = 41; // Uploaded in Cloud Files meanwhile.
    final again = find.text('Check again');
    await tester.ensureVisible(again);
    await tester.pumpAndSettle();
    await tester.tap(again);
    await tester.pumpAndSettle();

    expect(find.textContaining('No photos in the poster folder'), findsNothing);
    expect(find.text('41 photos on the photos page'), findsOneWidget);
  });

  /// The email preview contains [text].
  Finder previewWith(String text) => find.byWidgetPredicate((w) =>
      w is SelectableText &&
      (w.textSpan?.toPlainText() ?? w.data ?? '').contains(text));

  /// Whether the "Say …invoice is attached." switch is on.
  bool invoiceLineOn(WidgetTester tester) => tester
      .widget<Switch>(find.descendant(
        of: find
            .ancestor(
                of: find.text('Say "Your invoice is attached."'),
                matching: find.byType(Row))
            .first,
        matching: find.byType(Switch),
      ))
      .value;

  /// Choose the standard (non-Chand) template.
  Future<void> chooseStandard(WidgetTester tester) async {
    await tester.tap(find.text('Choose a report…'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Standard distribution report').last);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'standard report: unpaid in Xero means attached and said so, '
      'whatever the Job List\'s own status says', (tester) async {
    // The Job List says PAID (set by hand); Xero says it is not.
    final job = _job(
        'j1', 'Chand', 'flyerDistribution', DateTime.utc(2026, 10, 21, 22),
        invoiceNumber: 'INV-1042', invoiceStatus: 'PAID');
    await pumpPage(tester, const Size(1440, 900),
        item: job, xero: FakeXero(status: XeroInvoiceStatus.authorised));
    await chooseStandard(tester);

    expect(find.textContaining('INV-1042 is unpaid in Xero'), findsOneWidget);
    expect(find.text('Unpaid'), findsWidgets);
    expect(find.text('Paid'), findsNothing);
    // The email says so.
    expect(invoiceLineOn(tester), isTrue);
    expect(previewWith('Your invoice is attached.'), findsOneWidget);
    // The editor is open — Xero still accepts changes to an unpaid invoice.
    expect(find.text('Save to Xero'), findsOneWidget);
  });

  testWidgets(
      'standard report: paid in Xero means not attached, line off, '
      'even when the Job List still says unpaid', (tester) async {
    final job = _job(
        'j1', 'Chand', 'flyerDistribution', DateTime.utc(2026, 10, 21, 22),
        invoiceNumber: 'INV-1042', invoiceStatus: 'AUTHORISED');
    await pumpPage(tester, const Size(1440, 900),
        item: job, xero: FakeXero(status: XeroInvoiceStatus.paid));
    await chooseStandard(tester);

    expect(find.textContaining('INV-1042 is paid in Xero'), findsOneWidget);
    expect(find.text('Paid'), findsWidgets);
    expect(invoiceLineOn(tester), isFalse);
    expect(previewWith('Your invoice is attached.'), findsNothing);
    // Xero will not take changes to a paid invoice.
    expect(find.text('Save to Xero'), findsNothing);
    expect(find.textContaining('Xero will not accept changes'), findsOneWidget);
  });

  testWidgets('opening and leaving without changes saves nothing',
      (tester) async {
    final drafts = FakeDrafts();
    await pumpPage(tester, const Size(1440, 900), drafts: drafts);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
    expect(drafts.saves, 0);
  });

  group('flyer handout report', () {
    for (final (name, size) in [
      ('desktop', const Size(1440, 900)),
      ('phone', const Size(390, 844)),
    ]) {
      testWidgets('lays out without overflow on $name', (tester) async {
        await pumpPage(tester, size);
        await chooseTemplate(tester, 'Flyer handout report (PDF)');
        expect(find.text('Your flyer handout report'), findsWidgets);

        await tester.ensureVisible(find.text('Build PDF'));
        await tester.pumpAndSettle();
        expect(find.text('Francis'), findsOneWidget);
        expect(find.textContaining('with no date'), findsWidgets);

        if (size.width < 600) {
          await tester.tap(find.text('Preview').first);
          await tester.pumpAndSettle();
        }
        expect(find.text('Build the PDF — under Promoter days'), findsOneWidget);
        expect(
            find.textContaining(
                'handing out of your flyers on 22 and 23 October 2026',
                findRichText: true),
            findsWidgets);
      });
    }

    testWidgets('unticking a date leaves it out of the email and the draft',
        (tester) async {
      final drafts = FakeDrafts();
      await pumpPage(tester, const Size(1440, 900), drafts: drafts);
      await chooseTemplate(tester, 'Flyer handout report (PDF)');

      final fri = find.text('Fri 23 Oct 2026');
      await tester.ensureVisible(fri);
      await tester.pumpAndSettle();
      await tester.tap(fri);
      await tester.pumpAndSettle();
      expect(
          find.textContaining('handing out of your flyers on 22 October 2026',
              findRichText: true),
          findsWidgets);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(drafts.docs['j1']?['templateId'], '_flyer_handouts');
      expect(drafts.docs['j1']?['handoutUnselectedDays'], ['d1|2026-10-23']);

      // Back on the page later, the day is still unticked.
      await tester.pumpWidget(const SizedBox());
      await pumpPage(tester, const Size(1440, 900), drafts: drafts);
      expect(
          find.textContaining('handing out of your flyers on 22 October 2026',
              findRichText: true),
          findsWidgets);
    });

    testWidgets('nothing ticked blocks sending', (tester) async {
      await pumpPage(tester, const Size(1440, 900));
      await chooseTemplate(tester, 'Flyer handout report (PDF)');
      for (final day in ['Thu 22 Oct 2026', 'Fri 23 Oct 2026']) {
        await tester.ensureVisible(find.text(day));
        await tester.pumpAndSettle();
        await tester.tap(find.text(day));
        await tester.pumpAndSettle();
      }
      expect(find.text('Tick at least one promoter day'), findsOneWidget);
    });
  });

  group('choosing the photos', () {
    testWidgets('folder photos start left out; Choose puts the best in',
        (tester) async {
      final drafts = FakeDrafts();
      await pumpPage(tester, const Size(1440, 900), drafts: drafts);
      await chooseTemplate(tester, 'Flyer handout report (PDF)');

      final choose = find.widgetWithText(TextButton, 'Choose').first;
      await tester.ensureVisible(choose);
      await tester.pumpAndSettle();
      expect(find.text('0 of 3 photos chosen'), findsOneWidget);
      expect(find.textContaining('No photos chosen — 3 photos'), findsOneWidget);

      await tester.tap(choose);
      await tester.pumpAndSettle();
      expect(find.text('Photos for Thu 22 Oct 2026'), findsOneWidget);
      await tester.tap(find.byTooltip('p2.jpg'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 photo chosen · about'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.text('1 of 3 photos chosen'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(drafts.docs['j1']?['handoutChosenPhotos'], ['x/p2.jpg']);
    });

    testWidgets('Build PDF asks for the photos first; Back stops it',
        (tester) async {
      await pumpPage(tester, const Size(1440, 900));
      await chooseTemplate(tester, 'Flyer handout report (PDF)');
      final build = find.text('Build PDF');
      await tester.ensureVisible(build);
      await tester.pumpAndSettle();
      await tester.tap(build);
      await tester.pumpAndSettle();

      expect(find.text('Choose the photos for the report'), findsOneWidget);
      // Both dates' photos and the undated one are offered.
      expect(find.textContaining('No date — 1 photo'), findsOneWidget);
      await tester.tap(find.text('Choose all'));
      await tester.pumpAndSettle();
      expect(find.textContaining('3 photos chosen · about'), findsOneWidget);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Choose the photos for the report'), findsNothing);
      expect(find.text('Build PDF'), findsOneWidget);
      expect(find.text('3 of 3 photos chosen'), findsOneWidget);
    });
  });
}
