// utils/gmail_draft.dart
//
// Create a Gmail draft with an HTML body through the Gmail API. Web only;
// elsewhere [gmailDraftsAvailable] is false and callers use the plain-text
// compose link instead.
export 'gmail_draft_stub.dart'
    if (dart.library.js_interop) 'gmail_draft_web.dart';
export 'gmail_mime.dart' show GmailAttachment, kGmailAttachmentLimitBytes;

/// Why a draft was not created.
class GmailDraftException implements Exception {
  final String message;

  /// The user closed or refused Google's permission popup — not a fault.
  final bool cancelled;

  const GmailDraftException(this.message, {this.cancelled = false});

  @override
  String toString() => message;
}
