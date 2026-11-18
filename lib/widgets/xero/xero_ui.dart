import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/xero_invoice.dart';
import '../../utils/accounting_error.dart';
import '../../utils/schedule_time.dart';
import '../job_list_status_views.dart' show TechnicalDetails;
import '../zoho/zoho_table.dart';

/// Small building blocks shared by the Xero invoice screens, so the create,
/// detail, edit and payment flows speak with one voice.

/// Money and dates in fixed-width digits, so totals line up in a column and a
/// figure does not shimmy as it is typed.
const xeroTabular = [FontFeature.tabularFigures()];

/// One currency format for every Xero screen.
final xeroCurrency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);

/// One date format for every Xero screen.
final xeroDate = DateFormat('d MMM y');

enum XeroNoticeTone {
  info(Color(0xFF2B7DE9), Icons.info_outline),
  success(Color(0xFF2E9E4F), Icons.check_circle_outline),
  warning(Color(0xFFB86E00), Icons.warning_amber_rounded),
  error(Color(0xFFE03E3E), Icons.error_outline);

  const XeroNoticeTone(this.color, this.icon);
  final Color color;
  final IconData icon;
}

/// A tinted, bordered message with an optional action — the one shape every
/// warning, error and confirmation takes on these screens, replacing loose
/// orange and red text that was easy to miss.
class XeroNotice extends StatelessWidget {
  final XeroNoticeTone tone;

  /// Bold first line, when the notice has one.
  final String? title;
  final String message;

  /// Raw error text, collapsed under "Technical details" with a copy button.
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  const XeroNotice({
    super.key,
    required this.tone,
    required this.message,
    this.title,
    this.detail,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  });

  /// A failed Xero/Zoho action: what went wrong, what to do, and the raw
  /// error for whoever debugs it.
  XeroNotice.error(
    FriendlyError error, {
    super.key,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  })  : tone = XeroNoticeTone.error,
        title = error.title,
        message = error.advice,
        detail = error.detail;

  @override
  Widget build(BuildContext context) {
    final color = tone.color;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(tone.icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1, right: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(
                      title!,
                      style: const TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          color: ZohoPalette.textPrimary),
                    ),
                    const SizedBox(height: 2),
                  ],
                  Text(
                    message,
                    style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: ZohoPalette.textPrimary),
                  ),
                  if (detail != null && detail!.isNotEmpty)
                    // Its own Material: the expander's ListTile would
                    // otherwise paint under this tinted box.
                    Material(
                      type: MaterialType.transparency,
                      child: TechnicalDetails(detail: detail!),
                    ),
                ],
              ),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: color,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(actionLabel!),
            ),
          if (onDismiss != null)
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              color: ZohoPalette.textMuted,
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}

/// Small uppercase heading for a group of fields in a dialog.
class XeroSectionLabel extends StatelessWidget {
  final String text;

  const XeroSectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: ZohoPalette.textMuted,
        ),
      ),
    );
  }
}

/// A tappable date that looks like the text fields beside it.
class XeroDateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final String? helperText;

  const XeroDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.firstDate,
    this.lastDate,
    this.helperText,
  });

  @override
  Widget build(BuildContext context) {
    final anchor = value ?? scheduleToday();
    final first = firstDate ?? DateTime(anchor.year - 2);
    final last = lastDate ?? DateTime(anchor.year + 2, 12, 31);

    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: anchor.isBefore(first)
              ? first
              : anchor.isAfter(last)
                  ? last
                  : anchor,
          firstDate: first,
          lastDate: last,
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 16),
        ),
        child: Text(
          value == null ? '—' : xeroDate.format(value!),
          style: const TextStyle(fontFeatures: xeroTabular),
        ),
      ),
    );
  }
}

/// Where an invoice stands, in a sentence — what someone opening it from the
/// Job List actually wants to know first.
///
/// Overdue is derived here as it is everywhere: Xero has no such status (see
/// [XeroInvoice.isOverdue]).
({XeroNoticeTone tone, IconData icon, String headline, String? detail})
    xeroStanding(XeroInvoice invoice) {
  final today = scheduleToday();
  final due = invoice.dueDate;
  final days = due == null
      ? null
      : DateTime(due.year, due.month, due.day).difference(today).inDays;
  String plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

  switch (invoice.status) {
    case XeroInvoiceStatus.voided:
    case XeroInvoiceStatus.deleted:
      return (
        tone: XeroNoticeTone.info,
        icon: Icons.block,
        headline:
            invoice.status == XeroInvoiceStatus.voided ? 'Void' : 'Deleted',
        detail: 'Kept in the books for the record. Nothing is owed on it.',
      );
    case XeroInvoiceStatus.paid:
      return (
        tone: XeroNoticeTone.success,
        icon: Icons.check_circle,
        headline: 'Paid in full',
        detail: '${xeroCurrency.format(invoice.total)} received.',
      );
    case XeroInvoiceStatus.draft:
      return (
        tone: XeroNoticeTone.info,
        icon: Icons.edit_note,
        headline: 'Draft',
        detail: 'Not yet approved in Xero, so the customer cannot pay it.',
      );
    case XeroInvoiceStatus.submitted:
      return (
        tone: XeroNoticeTone.warning,
        icon: Icons.hourglass_top,
        headline: 'Awaiting approval',
        detail: 'Approve it in Xero before sending it to the customer.',
      );
    case XeroInvoiceStatus.unknown:
      return (
        tone: XeroNoticeTone.info,
        icon: Icons.help_outline,
        headline: 'Status unknown',
        detail: null,
      );
    case XeroInvoiceStatus.authorised:
      final owing = xeroCurrency.format(invoice.amountDue);
      final partPaid = invoice.amountPaid > 0
          ? ' · ${xeroCurrency.format(invoice.amountPaid)} already paid'
          : '';
      if (invoice.isOverdue && days != null) {
        return (
          tone: XeroNoticeTone.error,
          icon: Icons.schedule,
          headline: 'Overdue by ${plural(-days, 'day')}',
          detail: '$owing owing$partPaid. Was due ${xeroDate.format(due!)}.',
        );
      }
      return (
        tone: invoice.amountPaid > 0
            ? XeroNoticeTone.warning
            : XeroNoticeTone.info,
        icon: Icons.schedule,
        headline: days == null
            ? (invoice.amountPaid > 0 ? 'Part-paid' : 'Awaiting payment')
            : days <= 0
                ? 'Due today'
                : 'Due in ${plural(days, 'day')}',
        detail: '$owing owing$partPaid'
            '${due == null ? '' : ' · due ${xeroDate.format(due)}'}.',
      );
  }
}

/// Two fields side by side, or stacked once there is too little room for a
/// date and its calendar icon to sit beside another field — a phone, mostly.
class XeroFieldPair extends StatelessWidget {
  final Widget first;
  final Widget second;
  final int firstFlex;
  final int secondFlex;

  const XeroFieldPair({
    super.key,
    required this.first,
    required this.second,
    this.firstFlex = 1,
    this.secondFlex = 1,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 380) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 12), second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: firstFlex, child: first),
          const SizedBox(width: 12),
          Expanded(flex: secondFlex, child: second),
        ],
      );
    });
  }
}

/// Dialog inset: the stock 40px a side leaves a phone-width form too little
/// room, so it tightens to the page gutter there.
EdgeInsets xeroDialogInset(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 600
        ? const EdgeInsets.symmetric(horizontal: 16, vertical: 24)
        : const EdgeInsets.symmetric(horizontal: 40, vertical: 24);
