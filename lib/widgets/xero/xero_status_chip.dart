import 'package:flutter/material.dart';

import '../../models/xero_invoice.dart';

/// Colour-coded invoice status, matching [ZohoStatusChip]'s treatment so the
/// two providers read alike.
///
/// One Xero-specific wrinkle: **Xero has no OVERDUE status.** An overdue
/// invoice is AUTHORISED with a past due date and money still owing, so
/// [isOverdue] is passed in separately and overrides the label. Rendering the
/// raw status alone would show a red-flag invoice as an unremarkable
/// "Awaiting payment".
class XeroStatusChip extends StatelessWidget {
  final XeroInvoiceStatus status;

  /// Derived, not a status — see [XeroInvoice.isOverdue].
  final bool isOverdue;

  final bool dense;

  const XeroStatusChip({
    super.key,
    required this.status,
    this.isOverdue = false,
    this.dense = false,
  });

  static const _overdueColor = Color(0xFFE03E3E);

  @override
  Widget build(BuildContext context) {
    final showOverdue = isOverdue && status == XeroInvoiceStatus.authorised;
    final color = showOverdue ? _overdueColor : status.color;

    final label = Text(
      showOverdue ? 'OVERDUE' : status.label.toUpperCase(),
      style: TextStyle(
        color: color,
        fontSize: dense ? 11 : 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
        decoration: status.isStruckThrough ? TextDecoration.lineThrough : null,
      ),
    );

    if (dense) return label;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: label,
    );
  }
}
