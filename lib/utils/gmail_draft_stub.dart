// utils/gmail_draft_stub.dart
import 'gmail_draft.dart';

bool get gmailDraftsAvailable => false;

void prepareGmailDrafts() {}

Future<void> ensureGmailAccess() async =>
    throw const GmailDraftException('Gmail drafts need the web app.');

Future<Uri> createGmailDraft({
  required List<String> to,
  required String subject,
  required String text,
  required String html,
  List<GmailAttachment> attachments = const [],
}) async =>
    throw const GmailDraftException('Gmail drafts need the web app.');
