import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/xero_invoice.dart';
import '../../models/xero_org.dart';
import '../../providers/xero_tax_rates_provider.dart';
import '../zoho/zoho_table.dart';
import 'xero_item_picker.dart';

/// VAT-exclusive and VAT-inclusive amounts for one line, and for an invoice.
///
/// **Indicative, not authoritative.** Xero recalculates tax per line and rounds
/// as it goes, so the figures here can differ from the issued invoice by cents.
/// They are shown because working blind while quoting is worse — but the UI
/// says Xero confirms the total on save, and `linkAccountingInvoiceTxn` writes
/// back Xero's own split rather than this one.
class XeroLineTotals {
  final double exclVat;
  final double vat;
  final double inclVat;

  const XeroLineTotals({
    required this.exclVat,
    required this.vat,
    required this.inclVat,
  });

  static const zero =
      XeroLineTotals(exclVat: 0, vat: 0, inclVat: 0);

  /// Split one line's entered amount.
  ///
  /// Which way the arithmetic runs depends on [lineAmountType]:
  ///
  ///  - `exclusive` — the entered figure excludes VAT, so VAT is added on top.
  ///  - `inclusive` — the entered figure already contains VAT, so it is divided
  ///    out. Dividing by `1 + rate` is the whole difference; multiplying by the
  ///    rate here would overstate the VAT on every inclusive invoice.
  ///  - `noTax` — no VAT either way.
  ///
  /// A null [ratePercent] means the rate is unknown (not yet loaded, or a code
  /// this organisation does not have). VAT is then reported as zero rather than
  /// guessed at 15%, so an unknown rate reads as "no figure" instead of a wrong
  /// one.
  factory XeroLineTotals.forLine({
    required double amount,
    required XeroLineAmountType lineAmountType,
    required double? ratePercent,
  }) {
    if (lineAmountType == XeroLineAmountType.noTax ||
        ratePercent == null ||
        ratePercent <= 0) {
      return XeroLineTotals(exclVat: amount, vat: 0, inclVat: amount);
    }

    final rate = ratePercent / 100.0;

    if (lineAmountType == XeroLineAmountType.inclusive) {
      final excl = amount / (1 + rate);
      return XeroLineTotals(
        exclVat: excl,
        vat: amount - excl,
        inclVat: amount,
      );
    }

    final vat = amount * rate;
    return XeroLineTotals(exclVat: amount, vat: vat, inclVat: amount + vat);
  }

  /// Sum every line, resolving each line's own tax type.
  ///
  /// Per line rather than on the total, because lines can carry different tax
  /// types — an item may override the company default.
  factory XeroLineTotals.of(
    List<XeroLineItem> lines, {
    required XeroLineAmountType lineAmountType,
    required String defaultTaxType,
    required double? Function(String taxType) rateFor,
  }) {
    var excl = 0.0;
    var vat = 0.0;
    var incl = 0.0;

    for (final line in lines) {
      final taxType =
          line.taxType.isNotEmpty ? line.taxType : defaultTaxType;
      final totals = XeroLineTotals.forLine(
        amount: line.unitAmount * line.quantity,
        lineAmountType: lineAmountType,
        ratePercent: rateFor(taxType),
      );
      excl += totals.exclVat;
      vat += totals.vat;
      incl += totals.inclVat;
    }

    return XeroLineTotals(exclVat: excl, vat: vat, inclVat: incl);
  }
}

/// Editable invoice lines, laid out like Xero's own invoice grid.
///
/// The column set and order deliberately mirror Xero web — Item, Description,
/// Qty, Price, Account, Tax rate, Amount — so what you fill in here reads the
/// same as what you will see in the books afterwards.
///
/// Every line keeps its [XeroLineItem.lineItemId] through edits. That is not
/// cosmetic: Xero replaces the whole `LineItems` array on update, and a line
/// sent without its id is treated as new — the original is deleted and a
/// replacement created, losing its identity on the invoice.
class XeroLineItemsEditor extends riverpod.ConsumerWidget {
  final List<XeroLineItem> lineItems;
  final ValueChanged<List<XeroLineItem>> onChanged;

  /// Applied to newly added lines, and shown as the effective value on any
  /// line that does not override it.
  final String defaultAccountCode;
  final String defaultTaxType;

  final XeroLineAmountType lineAmountType;

  /// Supply to make the "Amounts are" selector editable. Null renders it as a
  /// label, for callers where the job type settles it.
  final ValueChanged<XeroLineAmountType>? onLineAmountTypeChanged;

  final bool enabled;

  /// Bumped by the caller whenever it replaces [lineItems] wholesale.
  ///
  /// Folded into each row's key. Without it a reseeded line keeps the same
  /// `new-0` key, so Flutter reuses the row's State and its controllers go on
  /// showing the previous text — the model changes and the screen does not.
  final int seedGeneration;

  const XeroLineItemsEditor({
    super.key,
    required this.lineItems,
    required this.onChanged,
    required this.lineAmountType,
    this.defaultAccountCode = '',
    this.defaultTaxType = '',
    this.onLineAmountTypeChanged,
    this.enabled = true,
    this.seedGeneration = 0,
  });

  /// Column widths, desktop-first.
  ///
  /// Description is deliberately **not** a column: it sits on its own full-width
  /// row beneath the figures, because these lines carry real sentences — which
  /// suburbs were covered, what was excluded — and a 200px cell turns writing
  /// one into scrolling through a keyhole. Item takes the leftover width here.
  static const _minItem = 160.0;
  static const _wQty = 62.0;
  static const _wPrice = 96.0;
  static const _wAccount = 88.0;
  // Narrower than it was: "15%" needs far less room than "OUTPUT3" did.
  static const _wTax = 78.0;
  // Wide enough for six figures. Money is also scaled to fit rather than
  // ellipsised — "R 12,3…" on an invoice is worse than slightly smaller text.
  static const _wAmount = 116.0;
  static const _wDelete = 40.0;

  static const _fixedWidth = _wQty +
      _wPrice +
      _wAccount +
      _wTax +
      _wAmount + // excl VAT
      _wAmount + // incl VAT
      _wDelete;

  /// The grid's outer border. Counted in the width maths below, not just
  /// drawn: a bordered Container lays its child out inside the border, so the
  /// columns have this much less room than the box itself.
  static const _borderWidth = 1.0;

  static const _minWidth = _minItem + _fixedWidth + (_borderWidth * 2);

  void _update(int index, XeroLineItem line) {
    final next = List<XeroLineItem>.of(lineItems);
    next[index] = line;
    onChanged(next);
  }

  void _remove(int index) {
    onChanged(List<XeroLineItem>.of(lineItems)..removeAt(index));
  }

  void _add() {
    onChanged([
      ...lineItems,
      XeroLineItem(
        description: '',
        quantity: 1,
        unitAmount: 0,
        accountCode: defaultAccountCode,
        taxType: defaultTaxType,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final taxRates = ref.watch(xeroTaxRatesRiverpod);

    // Loaded here rather than by each call site, so the percentages appear
    // wherever this editor is used. `ensureLoaded` is idempotent; the guard
    // just avoids scheduling a callback on every rebuild.
    if (!taxRates.hasLoaded && !taxRates.isLoading) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => taxRates.ensureLoaded());
    }

    // Resolves a line's tax type to a percentage. Null when the rates have not
    // loaded or the code is unknown to this organisation.
    double? rateFor(String taxType) => taxRates.percentFor(taxType);

    final totals = XeroLineTotals.of(
      lineItems,
      lineAmountType: lineAmountType,
      defaultTaxType: defaultTaxType,
      rateFor: rateFor,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildAmountsAre(),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            // Below the minimum the grid scrolls sideways rather than crushing
            // seven columns into an unusable width.
            final width = constraints.maxWidth < _minWidth
                ? _minWidth
                : constraints.maxWidth;

            // Subtract the border, or the columns sum to the full box width
            // and overflow the content area by exactly 2px — which lands on
            // the last cell in the row, the delete button.
            final itemWidth = width - (_borderWidth * 2) - _fixedWidth;

            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: ZohoPalette.border,
                      width: _borderWidth,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Column(
                    children: [
                      _buildHeader(itemWidth),
                      for (var i = 0; i < lineItems.length; i++)
                        _LineRow(
                          key: ValueKey(lineItems[i].lineItemId.isNotEmpty
                              ? lineItems[i].lineItemId
                              : 'new-$i-$seedGeneration'),
                          line: lineItems[i],
                          itemWidth: itemWidth,
                          defaultAccountCode: defaultAccountCode,
                          defaultTaxType: defaultTaxType,
                          enabled: enabled,
                          rateFor: rateFor,
                          lineAmountType: lineAmountType,
                          onChanged: (l) => _update(i, l),
                          onRemove:
                              lineItems.length > 1 ? () => _remove(i) : null,
                        ),
                      _buildAddRow(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        _buildTotals(currency, totals, taxRates),
      ],
    );
  }

  Widget _buildAmountsAre() {
    const options = {
      XeroLineAmountType.exclusive: 'Tax exclusive',
      XeroLineAmountType.inclusive: 'Tax inclusive',
      XeroLineAmountType.noTax: 'No tax',
    };

    // Wraps rather than overflowing where the editor is narrow — a phone, or
    // embedded under the distribution report's preview.
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text(
          'Amounts are',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: ZohoPalette.textPrimary,
          ),
        ),
        if (onLineAmountTypeChanged == null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: ZohoPalette.headerBackground,
              border: Border.all(color: ZohoPalette.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              options[lineAmountType] ?? '',
              style:
                  const TextStyle(fontSize: 12, color: ZohoPalette.textPrimary),
            ),
          )
        else
          ZohoFilterDropdown<XeroLineAmountType>(
            value: lineAmountType,
            icon: Icons.percent,
            options: options,
            onChanged: enabled ? onLineAmountTypeChanged : null,
          ),
      ],
    );
  }

  Widget _buildHeader(double itemWidth) {
    Widget cell(String label, double width, {bool right = false}) {
      return SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            label,
            textAlign: right ? TextAlign.right : TextAlign.left,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: ZohoPalette.textMuted,
            ),
          ),
        ),
      );
    }

    return Container(
      height: 36,
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        color: ZohoPalette.headerBackground,
        border: Border(bottom: BorderSide(color: ZohoPalette.border)),
      ),
      child: Row(
        children: [
          cell('ITEM', itemWidth),
          cell('QTY.', _wQty, right: true),
          cell('PRICE', _wPrice, right: true),
          cell('ACCOUNT', _wAccount),
          cell('TAX RATE', _wTax, right: true),
          cell('EXCL VAT', _wAmount, right: true),
          cell('INCL VAT', _wAmount, right: true),
          const SizedBox(width: _wDelete),
        ],
      ),
    );
  }

  Widget _buildAddRow() {
    return Container(
      height: 44,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: ZohoPalette.border)),
      ),
      child: TextButton.icon(
        onPressed: enabled ? _add : null,
        icon: const Icon(Icons.add, size: 16),
        label: const Text('Add row'),
        style: TextButton.styleFrom(
          foregroundColor: ZohoPalette.link,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildTotals(
    NumberFormat currency,
    XeroLineTotals totals,
    XeroTaxRatesProvider taxRates,
  ) {
    final noTax = lineAmountType == XeroLineAmountType.noTax;
    // Rates still loading, or none of the lines resolved to a known code.
    final vatUnknown = !noTax && totals.vat == 0 && totals.exclVat > 0;

    Widget line(String label, double value, {bool strong = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: strong ? 14 : 13,
                fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
                color: strong
                    ? ZohoPalette.textPrimary
                    : ZohoPalette.textMuted,
              ),
            ),
            const SizedBox(width: 16),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  currency.format(value),
                  style: TextStyle(
                    fontSize: strong ? 17 : 14,
                    fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
                    color: ZohoPalette.textPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            line('Subtotal (excl VAT)', totals.exclVat),
            if (!noTax) line('Total VAT', totals.vat),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Divider(height: 1, color: ZohoPalette.border),
            ),
            line(noTax ? 'Total' : 'Total (incl VAT)', totals.inclVat,
                strong: true),
            const SizedBox(height: 6),
            Text(
              vatUnknown
                  ? 'VAT rates have not loaded, so no VAT is shown. Xero still '
                      'applies them and confirms the total on save.'
                  : noTax
                      ? 'Xero issues the invoice number and confirms the total.'
                      : 'Indicative — Xero rounds VAT per line and confirms the '
                          'final total on save.',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                color: vatUnknown
                    ? Colors.orange.shade900
                    : ZohoPalette.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineRow extends StatefulWidget {
  final XeroLineItem line;
  final double itemWidth;
  final String defaultAccountCode;
  final String defaultTaxType;
  final bool enabled;
  final XeroLineAmountType lineAmountType;

  /// Resolves a tax type to its percentage. Supplied by the editor so the rate
  /// list is read once for the whole grid, not once per row.
  final double? Function(String taxType) rateFor;

  final ValueChanged<XeroLineItem> onChanged;
  final VoidCallback? onRemove;

  const _LineRow({
    super.key,
    required this.line,
    required this.itemWidth,
    required this.defaultAccountCode,
    required this.defaultTaxType,
    required this.enabled,
    required this.lineAmountType,
    required this.rateFor,
    required this.onChanged,
    this.onRemove,
  });

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  late final TextEditingController _description;
  late final TextEditingController _quantity;
  late final TextEditingController _unitAmount;

  static String _qty(double v) =>
      v.truncateToDouble() == v ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _description = TextEditingController(text: widget.line.description);
    _quantity = TextEditingController(text: _qty(widget.line.quantity));
    _unitAmount =
        TextEditingController(text: widget.line.unitAmount.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _description.dispose();
    _quantity.dispose();
    _unitAmount.dispose();
    super.dispose();
  }

  void _emit() {
    widget.onChanged(widget.line.copyWith(
      description: _description.text,
      quantity: double.tryParse(_quantity.text.trim()) ?? 0,
      unitAmount: double.tryParse(_unitAmount.text.trim()) ?? 0,
    ));
  }

  /// Choosing a catalogue item fills the line from it.
  ///
  /// The controllers are written to as well as the model, because they were
  /// seeded in initState and would otherwise keep showing the old text over
  /// the new values.
  void _applyItem(XeroItem? item) {
    if (item == null) {
      widget.onChanged(widget.line.copyWith(itemCode: ''));
      return;
    }

    _description.text = item.lineDescription;
    if (item.unitPrice > 0) {
      _unitAmount.text = item.unitPrice.toStringAsFixed(2);
    }

    widget.onChanged(widget.line.copyWith(
      itemCode: item.code,
      description: item.lineDescription,
      unitAmount: item.unitPrice > 0 ? item.unitPrice : widget.line.unitAmount,
      // An item's own account and tax rate override the company defaults —
      // that is the whole reason to keep a catalogue.
      accountCode: item.accountCode.isNotEmpty
          ? item.accountCode
          : widget.line.accountCode,
      taxType: item.taxType.isNotEmpty ? item.taxType : widget.line.taxType,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final amount = widget.line.unitAmount * widget.line.quantity;

    // What Xero will actually apply: the line's own value, or the company
    // default it inherits. Read-only, because these are configured once per
    // company and per item rather than argued with per line.
    final account = widget.line.accountCode.isNotEmpty
        ? widget.line.accountCode
        : widget.defaultAccountCode;
    final taxType = widget.line.taxType.isNotEmpty
        ? widget.line.taxType
        : widget.defaultTaxType;

    final ratePercent = widget.rateFor(taxType);
    final totals = XeroLineTotals.forLine(
      amount: amount,
      lineAmountType: widget.lineAmountType,
      ratePercent: ratePercent,
    );

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: ZohoPalette.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildFigureRow(currency, totals, account, taxType, ratePercent),
          _buildDescriptionRow(),
        ],
      ),
    );
  }

  /// Everything that fits on one line: what was sold, how much, for how much.
  Widget _buildFigureRow(
    NumberFormat currency,
    XeroLineTotals totals,
    String account,
    String taxType,
    double? ratePercent,
  ) {
    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      child: Row(
        children: [
          SizedBox(
            width: widget.itemWidth,
            child: XeroItemPicker(
              value: widget.line.itemCode,
              dense: true,
              enabled: widget.enabled,
              onChanged: _applyItem,
            ),
          ),
          _cell(
            width: XeroLineItemsEditor._wQty,
            child: _field(_quantity,
                keyboard: TextInputType.number, align: TextAlign.right),
          ),
          _cell(
            width: XeroLineItemsEditor._wPrice,
            child: _field(_unitAmount,
                keyboard: const TextInputType.numberWithOptions(decimal: true),
                align: TextAlign.right),
          ),
          _cell(
            width: XeroLineItemsEditor._wAccount,
            child: _readOnly(account),
          ),
          _cell(
            width: XeroLineItemsEditor._wTax,
            child: _taxRateCell(taxType, ratePercent),
          ),
          _cell(
            width: XeroLineItemsEditor._wAmount,
            child: _money(currency, totals.exclVat),
          ),
          _cell(
            width: XeroLineItemsEditor._wAmount,
            child: _money(currency, totals.inclVat, strong: true),
          ),
          SizedBox(
            width: XeroLineItemsEditor._wDelete,
            child: IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              color: ZohoPalette.textMuted,
              tooltip: widget.onRemove == null
                  ? 'An invoice needs at least one line'
                  : 'Remove line',
              onPressed: widget.enabled ? widget.onRemove : null,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  /// The description, on its own full-width row beneath the figures.
  ///
  /// Grows with the text rather than scrolling inside a fixed box — these lines
  /// routinely run to a couple of sentences, and the whole point of moving it
  /// out of the grid was to be able to see what you are writing.
  Widget _buildDescriptionRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: TextField(
        controller: _description,
        enabled: widget.enabled,
        // Unbounded, so the field grows a line at a time as you type; the two
        // minimum lines stop it collapsing to a single cramped row.
        maxLines: null,
        minLines: 2,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        onChanged: (_) => _emit(),
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: 'Description',
          labelStyle: const TextStyle(fontSize: 11),
          hintText: 'What this line is for — areas covered, quantities, '
              'anything the customer should see on the invoice',
          hintStyle:
              const TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
          isDense: true,
          filled: true,
          fillColor: ZohoPalette.pageBackground,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: ZohoPalette.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: ZohoPalette.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: ZohoPalette.link),
          ),
        ),
      ),
    );
  }

  Widget _cell({required double width, required Widget child}) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: child,
      ),
    );
  }

  Widget _field(
    TextEditingController controller, {
    TextInputType? keyboard,
    TextAlign align = TextAlign.left,
  }) {
    return TextField(
      controller: controller,
      enabled: widget.enabled,
      keyboardType: keyboard,
      textAlign: align,
      onChanged: (_) => _emit(),
      style: const TextStyle(fontSize: 13),
      decoration: const InputDecoration(
        border: InputBorder.none,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: 8),
      ),
    );
  }

  Widget _readOnly(String value) {
    return Tooltip(
      message: value.isEmpty
          ? 'Uses the organisation default'
          : 'Applied by Xero: $value',
      child: Text(
        value.isEmpty ? '—' : value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
      ),
    );
  }

  /// The VAT percentage, with the underlying Xero code in the tooltip.
  ///
  /// Falls back to the raw code when the rate list has not loaded or the code
  /// is unknown — showing "15%" for a rate nobody has confirmed would be an
  /// invention, and this is an accounting figure.
  Widget _taxRateCell(String taxType, double? ratePercent) {
    final known = ratePercent != null;
    final label = taxType.isEmpty
        ? '—'
        : known
            ? '${_trimZeros(ratePercent)}%'
            : taxType;

    return Tooltip(
      message: taxType.isEmpty
          ? 'Uses the organisation default'
          : known
              ? '$taxType — applied by Xero'
              : '$taxType — rate not loaded',
      child: Text(
        label,
        maxLines: 1,
        textAlign: TextAlign.right,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: known ? FontWeight.w600 : FontWeight.w400,
          color: ZohoPalette.textMuted,
        ),
      ),
    );
  }

  static String _trimZeros(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  /// Money that shrinks rather than overflowing.
  ///
  /// A six-figure invoice used to run past the column and paint the striped
  /// overflow banner over the row. Ellipsis would be worse than small text —
  /// a truncated amount on an invoice is actively misleading.
  Widget _money(NumberFormat currency, double value, {bool strong = false}) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Text(
        currency.format(value),
        maxLines: 1,
        style: TextStyle(
          fontSize: 13,
          fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
          color: strong ? ZohoPalette.textPrimary : ZohoPalette.textMuted,
        ),
      ),
    );
  }
}
