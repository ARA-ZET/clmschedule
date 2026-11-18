import 'package:cloud_firestore/cloud_firestore.dart';

/// Progress on a distribution report, saved so leaving the page — another
/// tab, a reload, another computer — does not lose what was typed and picked.
///
/// One per Job List job, keyed by its id. Everything the report page lets
/// the user decide is here; everything it compiles (counts, dates, names
/// from file names) is not, because that is re-read fresh each time.
class DistributionReportDraft {
  final String jobId;

  final String? templateId;
  final String greeting;
  final String subject;

  // Flyers & Posters.
  final String heading;
  final String leafletName;
  final String suburb;
  final bool suburbTouched;
  final bool clickedIsPoster;
  final String? otherJobId;

  /// Folders the user **unticked**, rather than the ones ticked: a folder
  /// that appears after the draft was saved (more tracks uploaded) should be
  /// counted, not silently left out.
  final List<String> unselectedFolders;
  final List<String> otherUnselectedFolders;

  /// Null while the user has not overridden the invoice-derived default.
  final bool? includeInvoiceLine;
  final bool? writeBackQuantity;

  /// File-name spelling (lower-cased) → distributor id picked by hand.
  final Map<String, String> pickedDistributor;

  /// Person row key → ID typed on the page.
  final Map<String, String> typedIds;
  final List<String> removedPeople;

  /// Invoice id → attach it or not, where the user changed the default
  /// (unpaid invoices are attached, paid ones are not).
  final Map<String, bool> invoiceChoices;

  /// Invoices the personnel's names and IDs were added to, so the reminder
  /// does not come back once it is done.
  final List<String> invoicesWithPersonnel;

  // Flyer handout report.

  /// Promoter days (`distributorId|y-m-d`) **unticked**, like the folders,
  /// so a promoter whose track arrives later is included.
  final List<String> handoutUnselectedDays;

  /// Promoter day → "Where worked" typed in the check.
  final Map<String, String> handoutWhere;

  /// Promoter day → client map link typed in the check.
  final Map<String, String> handoutLinks;

  /// Storage paths of the photos chosen to go into the report. A folder
  /// photo is left out until chosen.
  final List<String> handoutChosenPhotos;

  /// Storage path → yyyy-MM-dd, for photos put on a date by hand.
  final Map<String, String> handoutPhotoDates;

  final DateTime? updatedAt;
  final String updatedBy;

  const DistributionReportDraft({
    required this.jobId,
    this.templateId,
    this.greeting = '',
    this.subject = '',
    this.heading = '',
    this.leafletName = '',
    this.suburb = '',
    this.suburbTouched = false,
    this.clickedIsPoster = false,
    this.otherJobId,
    this.unselectedFolders = const [],
    this.otherUnselectedFolders = const [],
    this.includeInvoiceLine,
    this.writeBackQuantity,
    this.pickedDistributor = const {},
    this.typedIds = const {},
    this.removedPeople = const [],
    this.invoiceChoices = const {},
    this.invoicesWithPersonnel = const [],
    this.handoutUnselectedDays = const [],
    this.handoutWhere = const {},
    this.handoutLinks = const {},
    this.handoutChosenPhotos = const [],
    this.handoutPhotoDates = const {},
    this.updatedAt,
    this.updatedBy = '',
  });

  factory DistributionReportDraft.fromMap(
      String jobId, Map<String, dynamic> map) {
    List<String> strings(Object? v) =>
        v is List ? v.whereType<String>().toList() : const [];
    Map<String, String> stringMap(Object? v) => v is Map
        ? {
            for (final e in v.entries)
              if (e.key is String && e.value is String)
                e.key as String: e.value as String,
          }
        : const {};
    String text(Object? v) => v is String ? v : '';

    final updated = map['updatedAt'];
    return DistributionReportDraft(
      jobId: jobId,
      templateId: map['templateId'] as String?,
      greeting: text(map['greeting']),
      subject: text(map['subject']),
      heading: text(map['heading']),
      leafletName: text(map['leafletName']),
      suburb: text(map['suburb']),
      suburbTouched: map['suburbTouched'] == true,
      clickedIsPoster: map['clickedIsPoster'] == true,
      otherJobId: map['otherJobId'] as String?,
      unselectedFolders: strings(map['unselectedFolders']),
      otherUnselectedFolders: strings(map['otherUnselectedFolders']),
      includeInvoiceLine: map['includeInvoiceLine'] as bool?,
      writeBackQuantity: map['writeBackQuantity'] as bool?,
      pickedDistributor: stringMap(map['pickedDistributor']),
      typedIds: stringMap(map['typedIds']),
      removedPeople: strings(map['removedPeople']),
      invoiceChoices: map['invoiceChoices'] is Map
          ? {
              for (final e in (map['invoiceChoices'] as Map).entries)
                if (e.key is String && e.value is bool)
                  e.key as String: e.value as bool,
            }
          : const {},
      invoicesWithPersonnel: strings(map['invoicesWithPersonnel']),
      handoutUnselectedDays: strings(map['handoutUnselectedDays']),
      handoutWhere: stringMap(map['handoutWhere']),
      handoutLinks: stringMap(map['handoutLinks']),
      handoutChosenPhotos: strings(map['handoutChosenPhotos']),
      handoutPhotoDates: stringMap(map['handoutPhotoDates']),
      updatedAt: updated is Timestamp ? updated.toDate() : null,
      updatedBy: text(map['updatedBy']),
    );
  }

  /// What the user decided, without the bookkeeping — compared between
  /// builds to tell whether there is anything new to save.
  Map<String, dynamic> toContentMap() => {
        'templateId': templateId,
        'greeting': greeting,
        'subject': subject,
        'heading': heading,
        'leafletName': leafletName,
        'suburb': suburb,
        'suburbTouched': suburbTouched,
        'clickedIsPoster': clickedIsPoster,
        'otherJobId': otherJobId,
        'unselectedFolders': [...unselectedFolders]..sort(),
        'otherUnselectedFolders': [...otherUnselectedFolders]..sort(),
        'includeInvoiceLine': includeInvoiceLine,
        'writeBackQuantity': writeBackQuantity,
        'pickedDistributor': pickedDistributor,
        'typedIds': typedIds,
        'removedPeople': [...removedPeople]..sort(),
        'invoiceChoices': invoiceChoices,
        'invoicesWithPersonnel': [...invoicesWithPersonnel]..sort(),
        'handoutUnselectedDays': [...handoutUnselectedDays]..sort(),
        'handoutWhere': _sorted(handoutWhere),
        'handoutLinks': _sorted(handoutLinks),
        'handoutChosenPhotos': [...handoutChosenPhotos]..sort(),
        'handoutPhotoDates': _sorted(handoutPhotoDates),
      };

  /// Keys in order, so the same choices always encode the same way.
  static Map<String, String> _sorted(Map<String, String> map) =>
      Map.fromEntries(
          map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
}
