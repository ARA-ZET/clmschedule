import 'xero_invoice.dart';
import 'zoho_invoice.dart';

/// The provider-neutral view of an invoice that message templates render.
///
/// Templates are shared across both sets of books — the wording you send a
/// customer does not depend on which ledger raised the invoice — but the two
/// invoice models have neither a common supertype nor matching field names
/// (`customerName`/`contactName`, `balance`/`amountDue`). Rather than teach
/// every template call site about both, each provider flattens into this once
/// at the boundary.
///
/// Only what a template can actually say is carried here. It is deliberately
/// not a general-purpose invoice: nothing renders line items, so none are kept.
class InvoiceMessageSubject {
  final String clientName;
  final String invoiceNumber;
  final double total;
  final double amountDue;
  final DateTime? date;
  final DateTime? dueDate;

  /// Settled in full. Drives the `paid` template category.
  final bool isPaid;

  /// Past its due date with money still owing.
  ///
  /// A field rather than something derived here, because the two providers
  /// disagree about where it comes from: Zoho has an explicit `overdue`
  /// status, Xero has none and computes it from the due date and the balance.
  final bool isOverdue;

  /// Customer-facing payment link, or empty when the invoice has none.
  ///
  /// Zoho carries this on the invoice itself (`invoice_url`). Xero does not —
  /// its `OnlineInvoiceUrl` needs a separate API call, so [fromXero] takes it
  /// as an argument and callers that have not fetched one simply leave it out.
  final String payLink;

  const InvoiceMessageSubject({
    required this.clientName,
    required this.invoiceNumber,
    required this.total,
    required this.amountDue,
    this.date,
    this.dueDate,
    this.isPaid = false,
    this.isOverdue = false,
    this.payLink = '',
  });

  /// Junk & Stuff's books.
  ///
  /// The paid test keeps Zoho's original behaviour, which treats a zero
  /// balance as settled whatever the status says — including for a void
  /// invoice. That is odd, but it is what the templates have always done and
  /// this seam is not the place to change which wording an invoice gets.
  factory InvoiceMessageSubject.fromZoho(ZohoInvoice invoice) {
    final isOverdue = invoice.status == ZohoInvoiceStatus.overdue;
    return InvoiceMessageSubject(
      clientName: invoice.customerName,
      invoiceNumber: invoice.invoiceNumber,
      total: invoice.total,
      amountDue: invoice.balance,
      date: invoice.date,
      dueDate: invoice.dueDate,
      isPaid: invoice.status == ZohoInvoiceStatus.paid ||
          (!isOverdue && invoice.balance <= 0),
      isOverdue: isOverdue,
      payLink: invoice.invoiceUrl,
    );
  }

  /// Community Life Media's books.
  ///
  /// Paid keys on the status alone, unlike the Zoho flattening. Xero moves an
  /// invoice to PAID itself the moment the balance clears, so a zero
  /// `AmountDue` adds nothing — and reading one as settled would misfile every
  /// DRAFT, which also reports zero.
  factory InvoiceMessageSubject.fromXero(
    XeroInvoice invoice, {
    String payLink = '',
  }) {
    return InvoiceMessageSubject(
      clientName: invoice.contactName,
      invoiceNumber: invoice.invoiceNumber,
      total: invoice.total,
      amountDue: invoice.amountDue,
      date: invoice.date,
      dueDate: invoice.dueDate,
      isPaid: invoice.status == XeroInvoiceStatus.paid,
      isOverdue: invoice.isOverdue,
      payLink: payLink,
    );
  }
}
