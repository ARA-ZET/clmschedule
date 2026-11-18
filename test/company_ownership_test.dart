import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/company.dart';
import 'package:clmschedule/models/custom_job_type.dart';

/// Company ownership replaces an inference that was previously spread across
/// ~96 call sites. These lock in the two things that make that safe: the
/// fallback derivation, and that an explicit assignment always beats it.

CustomJobType _type({
  String id = 'jt-1',
  String label = 'Job type',
  String companyId = '',
  bool createsInvoices = true,
  bool appearsOnCollectionSchedule = false,
  bool isHappySunService = false,
}) {
  return CustomJobType(
    id: id,
    label: label,
    companyId: companyId,
    createsInvoices: createsInvoices,
    appearsOnCollectionSchedule: appearsOnCollectionSchedule,
    isHappySunService: isHappySunService,
  );
}

void main() {
  group('Ownership derives from the legacy flags until assigned', () {
    test('collection-schedule types are Junk & Stuff', () {
      final t = _type(appearsOnCollectionSchedule: true);
      expect(t.resolvedCompanyId, Company.junkAndStuffId);
      expect(t.companyIsInferred, isTrue);
    });

    test('Happy Sun services are Happy Sun', () {
      final t = _type(isHappySunService: true);
      expect(t.resolvedCompanyId, Company.happySunId);
    });

    test('everything else is CLM by elimination', () {
      // CLM was never stored anywhere — it was the absence of both flags.
      expect(_type().resolvedCompanyId, Company.clmId);
    });

    test('an explicit companyId always wins over the derivation', () {
      // The whole point: a Junk & Stuff job type that does NOT appear on the
      // Collection Schedule becomes expressible.
      final t = _type(
        companyId: Company.junkAndStuffId,
        appearsOnCollectionSchedule: false,
      );
      expect(t.resolvedCompanyId, Company.junkAndStuffId);
      expect(t.companyIsInferred, isFalse);

      // And a collection-schedule job type can be owned by someone else.
      final reassigned = _type(
        companyId: Company.clmId,
        appearsOnCollectionSchedule: true,
      );
      expect(reassigned.resolvedCompanyId, Company.clmId);
    });
  });

  group('Job type serialisation', () {
    test('company and invoiceability survive a round-trip', () {
      final original = _type(
        companyId: Company.clmId,
        createsInvoices: false,
      );
      final restored = CustomJobType.fromMap({
        ...original.toMap(),
        'id': original.id,
        'label': original.label,
      });

      expect(restored.companyId, Company.clmId);
      expect(restored.createsInvoices, isFalse);
    });

    test('an unassigned job type writes no companyId key', () {
      // Keeps documents untouched since before companies existed byte-identical,
      // so they keep falling back to the derivation rather than being pinned.
      expect(_type().toMap().containsKey('companyId'), isFalse);
    });

    test('legacy documents default to invoiceable', () {
      final legacy = CustomJobType.fromMap({
        'id': 'old',
        'label': 'Flyer distribution',
        'appearsOnCollectionSchedule': false,
      });
      expect(legacy.createsInvoices, isTrue,
          reason: 'existing job types must not silently stop invoicing');
      expect(legacy.companyId, isEmpty);
      expect(legacy.resolvedCompanyId, Company.clmId);
    });
  });

  group('Accounting provider follows the company', () {
    test('the seed maps each business to its provider', () {
      Company byId(String id) => Company.seed.firstWhere((c) => c.id == id);

      expect(byId(Company.clmId).accountingProvider, AccountingProvider.xero);
      expect(byId(Company.junkAndStuffId).accountingProvider,
          AccountingProvider.zoho);
      // Its own Zoho organisation under the Junk & Stuff login (ZohoOrg).
      expect(
          byId(Company.happySunId).accountingProvider, AccountingProvider.zoho);
    });

    // Xero was implemented in Aug 2026; before that this asserted it was not.
    // The point of the guard is unchanged: the UI must not offer to invoice
    // through a provider with no code behind it.
    test('Zoho and Xero are implemented; Sage is not', () {
      expect(AccountingProvider.zoho.isImplemented, isTrue);
      expect(AccountingProvider.xero.isImplemented, isTrue);
      expect(AccountingProvider.none.isImplemented, isTrue);
      expect(AccountingProvider.sage.isImplemented, isFalse);
    });

    test('an unknown provider string degrades to none', () {
      expect(AccountingProvider.parse('quickbooks'), AccountingProvider.none);
      expect(AccountingProvider.parse(null), AccountingProvider.none);
    });
  });

  group('Company serialisation', () {
    test('round-trips including provider config', () {
      const original = Company(
        id: 'clm',
        name: 'Community Life Media',
        shortName: 'CLM',
        accountingProvider: AccountingProvider.xero,
        providerConfig: {'tenantId': 'abc-123'},
        order: 0,
        colorValue: 0xFF2B7DE9,
      );
      final restored = Company.fromMap({...original.toMap(), 'id': 'clm'});

      expect(restored.name, 'Community Life Media');
      expect(restored.shortName, 'CLM');
      expect(restored.accountingProvider, AccountingProvider.xero);
      expect(restored.providerConfig['tenantId'], 'abc-123');
      expect(restored.active, isTrue);
    });

    test('displayLabel prefers the short name', () {
      expect(
        const Company(id: 'x', name: 'Community Life Media', shortName: 'CLM')
            .displayLabel,
        'CLM',
      );
      expect(
        const Company(id: 'x', name: 'Community Life Media').displayLabel,
        'Community Life Media',
      );
    });
  });

  group('Which books a job type invoices through', () {
    // This gates the invoicing section in AddEditJobDialog. It is the one edit
    // in the Xero work that the live Junk & Stuff path also runs through, so
    // the first test here is a regression guard, not a feature.

    test('Junk & Stuff still invoices through Zoho, exactly as before', () {
      final t = _type(appearsOnCollectionSchedule: true);
      expect(t.resolvedCompanyId, Company.junkAndStuffId);

      expect(
        AccountingProvider.forJobType(
          fromCompany: AccountingProvider.zoho,
          createsInvoices: t.createsInvoices,
          appearsOnCollectionSchedule: t.appearsOnCollectionSchedule,
        ),
        AccountingProvider.zoho,
      );
    });

    test('CLM job types now invoice through Xero', () {
      final t = _type();
      expect(t.resolvedCompanyId, Company.clmId);

      expect(
        AccountingProvider.forJobType(
          fromCompany: AccountingProvider.xero,
          createsInvoices: true,
          appearsOnCollectionSchedule: false,
        ),
        AccountingProvider.xero,
      );
    });

    test('createsInvoices is absolute, whatever the company says', () {
      // Internal work — returning flyers — must never offer an invoice, even
      // though its company invoices through Xero.
      for (final company in [
        AccountingProvider.xero,
        AccountingProvider.zoho,
      ]) {
        expect(
          AccountingProvider.forJobType(
            fromCompany: company,
            createsInvoices: false,
            appearsOnCollectionSchedule: true,
          ),
          AccountingProvider.none,
          reason: 'createsInvoices: false overrides $company',
        );
      }
    });

    test('a company with no provider falls back to the legacy flag', () {
      // The safety net: before the company link existed, "is this invoiced?"
      // *was* appearsOnCollectionSchedule. A company document missing its
      // provider must not make Junk & Stuff's jobs uninvoiceable.
      expect(
        AccountingProvider.forJobType(
          fromCompany: AccountingProvider.none,
          createsInvoices: true,
          appearsOnCollectionSchedule: true,
        ),
        AccountingProvider.zoho,
      );

      // ...but it must not invent invoicing for a type that never had it.
      expect(
        AccountingProvider.forJobType(
          fromCompany: AccountingProvider.none,
          createsInvoices: true,
          appearsOnCollectionSchedule: false,
        ),
        AccountingProvider.none,
      );
    });

    test('an unimplemented provider is still reported honestly', () {
      // Sage resolves, so the UI can say "not supported" rather than silently
      // showing nothing and leaving the user wondering.
      expect(
        AccountingProvider.forJobType(
          fromCompany: AccountingProvider.sage,
          createsInvoices: true,
          appearsOnCollectionSchedule: false,
        ),
        AccountingProvider.sage,
      );
      expect(AccountingProvider.sage.isImplemented, isFalse);
    });
  });

  group('Job types bill as a catalogue item', () {
    test('the item code survives a Firestore round trip', () {
      const original = CustomJobType(
        id: 'jt-1',
        label: 'Distribution',
        accountingItemCode: 'DIST-1000',
      );
      final restored = CustomJobType.fromMap({
        'id': original.id,
        'label': original.label,
        ...original.toMap(),
      });
      expect(restored.accountingItemCode, 'DIST-1000');
    });

    test('an unset item code is not written at all', () {
      // Job types that bill as free text must stay byte-identical to how they
      // were stored before items existed, so nothing is rewritten needlessly.
      const free = CustomJobType(id: 'jt-2', label: 'Ad hoc');
      expect(free.toMap().containsKey('accountingItemCode'), isFalse);
      expect(
          CustomJobType.fromMap({'id': 'jt-2', 'label': 'Ad hoc'})
              .accountingItemCode,
          '');
    });

    test('copyWith carries it, so an edit elsewhere cannot drop it', () {
      const original = CustomJobType(
        id: 'jt-3',
        label: 'Distribution',
        accountingItemCode: 'DIST-1000',
      );
      expect(
          original.copyWith(label: 'Renamed').accountingItemCode, 'DIST-1000');
    });
  });

  group('The slim job form keys on the company, not the provider', () {
    // AddEditJobDialog hides Invoice, Amount, the distributed count, Invoice
    // Details, Report Addresses and Who to Invoice for the two businesses that
    // raise invoices from inside the app — the invoice carries all of it. The
    // gate is company identity, so these assert what that actually covers.

    /// Mirrors `_invoicedFromInsideTheApp` in the dialog.
    bool slimForm(CustomJobType t) =>
        t.resolvedCompanyId == Company.clmId ||
        t.resolvedCompanyId == Company.junkAndStuffId;

    test('CLM and Junk & Stuff both get the slim form', () {
      expect(_type().resolvedCompanyId, Company.clmId);
      expect(slimForm(_type()), isTrue);

      final js = _type(appearsOnCollectionSchedule: true);
      expect(js.resolvedCompanyId, Company.junkAndStuffId);
      expect(slimForm(js), isTrue);
    });

    test('Happy Sun keeps the full form', () {
      // Invoiced by hand, so nothing else is carrying these fields.
      final hs = _type(isHappySunService: true);
      expect(hs.resolvedCompanyId, Company.happySunId);
      expect(slimForm(hs), isFalse);
    });

    test('createsInvoices: false still gets the slim form', () {
      // The deliberate consequence of gating on company rather than provider:
      // internal work gets the slim form too, so it has nowhere to record an
      // amount or invoice number. Chosen for consistency over capability.
      final internal = _type(createsInvoices: false);
      expect(slimForm(internal), isTrue);
      expect(
        AccountingProvider.forJobType(
          fromCompany: AccountingProvider.xero,
          createsInvoices: internal.createsInvoices,
          appearsOnCollectionSchedule: false,
        ),
        AccountingProvider.none,
        reason: 'it raises no invoice, yet still gets the slim form',
      );
    });
  });

  group('Collection Date is hidden for Junk & Stuff', () {
    // AddEditJobDialog drops the Collection Date field on a Junk & Stuff job.
    // Safe only because of the sentinel fallback below — these pin the two
    // facts that make it so.

    // Mirrors `effectiveDate` in collection_schedule_provider.dart, which is
    // what decides where a job lands on the grid.
    DateTime effectiveDate(DateTime collectionDate, DateTime date) =>
        (collectionDate.year != 2000 &&
                collectionDate.month != 1 &&
                collectionDate.day != 1)
            ? collectionDate
            : date;

    test('an unset collection date falls back to the job date', () {
      // This is the whole reason hiding the field is safe. _buildJobListItem
      // writes `_selectedCollectionDate ?? DateTime(2000,1,1)`, and the grid
      // reads that sentinel as "use the job date". If the sentinel ever became
      // DateTime.now(), every new Junk & Stuff job would silently pin itself
      // to today on the Collection Schedule.
      final jobDate = DateTime(2026, 8, 26);
      final unset = DateTime(2000, 1, 1);

      expect(effectiveDate(unset, jobDate), jobDate);
    });

    test('a collection date set by dragging still wins', () {
      // Dropping a job on the Collection Schedule writes a real collectionDate
      // with a time component. Hiding the form field must not cost that.
      final jobDate = DateTime(2026, 8, 26);
      final dragged = DateTime(2026, 8, 28, 10, 30);

      expect(effectiveDate(dragged, jobDate), dragged);
      expect(effectiveDate(dragged, jobDate).hour, 10,
          reason: 'the time slot rides on collectionDate');
    });

    test('only Junk & Stuff loses the field', () {
      bool hidesCollectionDate(CustomJobType t) =>
          t.resolvedCompanyId == Company.junkAndStuffId;

      expect(hidesCollectionDate(_type(appearsOnCollectionSchedule: true)),
          isTrue);
      // CLM has the same redundancy — its jobs never reach the Collection
      // Schedule at all — but was deliberately left alone for now.
      expect(hidesCollectionDate(_type()), isFalse);
      expect(hidesCollectionDate(_type(isHappySunService: true)), isFalse);
    });
  });

  group('Allowed invoice items per job type', () {
    test('no list means no restriction', () {
      // The picker offers the whole catalogue, exactly as before this existed.
      expect(_type().allowedItemCodes, isEmpty);
    });

    test('the default is always offered, even if left off the list', () {
      // Otherwise setting a default could put it out of reach of its own
      // picker — the one item guaranteed to be wanted.
      const t = CustomJobType(
        id: 'jt-1',
        label: 'Distribution',
        accountingItemCode: '1',
        accountingItemCodes: ['2', '3'],
      );
      expect(t.allowedItemCodes, ['1', '2', '3']);
    });

    test('a default already on the list is not duplicated', () {
      const t = CustomJobType(
        id: 'jt-1',
        label: 'Distribution',
        accountingItemCode: '2',
        accountingItemCodes: ['2', '3'],
      );
      expect(t.allowedItemCodes, ['2', '3']);
    });

    test('the list survives a Firestore round trip, and is omitted when unset',
        () {
      const t = CustomJobType(
        id: 'jt-1',
        label: 'Distribution',
        accountingItemCodes: ['2', '3'],
      );
      final restored = CustomJobType.fromMap({
        'id': t.id,
        'label': t.label,
        ...t.toMap(),
      });
      expect(restored.accountingItemCodes, ['2', '3']);

      expect(
        const CustomJobType(id: 'x', label: 'y')
            .toMap()
            .containsKey('accountingItemCodes'),
        isFalse,
      );
    });

    test('copyWith carries the list', () {
      const t = CustomJobType(
        id: 'jt-1',
        label: 'D',
        accountingItemCodes: ['2'],
      );
      expect(t.copyWith(label: 'Renamed').accountingItemCodes, ['2']);
    });
  });

  group('An unresolved company silently disables invoicing', () {
    // This is the shape of a real bug: AddEditJobDialog read companyRiverpod
    // instead of watching it, so the first build saw an empty company list.
    // The resolution below then returned `none`, the invoicing section did not
    // render, and a CLM job saved with no invoice and no explanation.
    //
    // The fix was to watch the provider. These pin the logic that made the
    // silence possible, so it stays understood rather than rediscovered.

    test('no company resolves to none for a CLM-shaped job type', () {
      // What `providerForJobType` returns before the companies have loaded:
      // getById finds nothing, so `fromCompany` is none. A CLM job type has
      // appearsOnCollectionSchedule false, so the legacy fallback cannot save
      // it either — the result is "not invoiced".
      expect(
        AccountingProvider.forJobType(
          fromCompany: AccountingProvider.none,
          createsInvoices: true,
          appearsOnCollectionSchedule: false,
        ),
        AccountingProvider.none,
      );
    });

    test('a Junk & Stuff job type survives the same gap', () {
      // Why this never showed up on the Zoho path: the legacy flag still
      // resolves it, so an unloaded company list was invisible there.
      expect(
        AccountingProvider.forJobType(
          fromCompany: AccountingProvider.none,
          createsInvoices: true,
          appearsOnCollectionSchedule: true,
        ),
        AccountingProvider.zoho,
      );
    });

    test('once loaded, a CLM job type resolves to Xero', () {
      expect(
        AccountingProvider.forJobType(
          fromCompany: AccountingProvider.xero,
          createsInvoices: true,
          appearsOnCollectionSchedule: false,
        ),
        AccountingProvider.xero,
      );
    });
  });

  group('Junk & Stuff and Happy Sun jobs always sync to the Dropsheet', () {
    test('transport of goods (a collection-schedule type) syncs', () {
      expect(_type(appearsOnCollectionSchedule: true).syncsToDropsheet, isTrue);
    });

    test('window cleaning (a Happy Sun service) syncs', () {
      expect(_type(isHappySunService: true).syncsToDropsheet, isTrue);
    });

    test('an assigned Junk & Stuff type syncs without any flag', () {
      expect(_type(companyId: Company.junkAndStuffId).syncsToDropsheet, isTrue);
    });

    test('CLM distribution does not, unless flagged', () {
      expect(_type(companyId: Company.clmId).syncsToDropsheet, isFalse);
      expect(
          _type(companyId: Company.clmId)
              .copyWith(appearsOnDropsheet: true)
              .syncsToDropsheet,
          isTrue);
    });
  });
}
