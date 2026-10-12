/// Building Gmail compose URLs.
///
/// Gmail's compose URL **cannot carry an attachment** — there is no parameter
/// for one, and a browser cannot attach a local file to a page it merely
/// opened. Anything that must be attached is attached by hand, which is why
/// every caller also puts the body on the clipboard.
library;

/// Length past which the body is left out of the URL.
///
/// Well above what the supplied templates produce (~2 KB encoded) and well
/// below any browser's own ceiling. The point is not to find the exact limit
/// but to fail *visibly* — an over-long URL is truncated silently by Gmail,
/// and a half-sent report reads as a complete one.
const int kGmailComposeUrlLimit = 6000;

/// A compose URL plus whether the body actually fitted in it.
class GmailComposeUrl {
  final Uri uri;

  /// False when the body was left out and must be pasted by the user.
  final bool bodyIncluded;

  const GmailComposeUrl({required this.uri, required this.bodyIncluded});
}

/// Build a Gmail compose URL, dropping the body if it would make the URL
/// unreasonably long.
///
/// [to] entries are joined with commas, which is what Gmail expects for
/// multiple recipients. An empty list simply opens a draft with no recipient.
GmailComposeUrl buildGmailComposeUrl({
  required List<String> to,
  required String subject,
  required String body,
  int limit = kGmailComposeUrlLimit,
}) {
  Uri build({required bool withBody}) {
    return Uri.parse('https://mail.google.com/mail/').replace(
      queryParameters: <String, String>{
        'view': 'cm',
        'fs': '1',
        if (to.isNotEmpty) 'to': to.join(','),
        if (subject.isNotEmpty) 'su': subject,
        if (withBody && body.isNotEmpty) 'body': body,
      },
    );
  }

  final full = build(withBody: true);
  if (full.toString().length <= limit) {
    return GmailComposeUrl(uri: full, bodyIncluded: true);
  }
  return GmailComposeUrl(uri: build(withBody: false), bodyIncluded: false);
}
