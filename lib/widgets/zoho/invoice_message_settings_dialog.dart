import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/invoice_message_template.dart';
import '../../models/zoho_invoice.dart';
import '../../providers/invoice_message_template_provider.dart';
import '../../providers/invoice_status_provider.dart';
import '../../providers/job_list_status_provider.dart';
import '../../providers/zoho_sync_settings_provider.dart';
import 'zoho_status_chip.dart';
import 'zoho_table.dart';

/// Manage the message templates offered when sharing an invoice, and the
/// banking details block that `{banking_details}` expands to.
class InvoiceMessageSettingsDialog extends riverpod.ConsumerStatefulWidget {
  const InvoiceMessageSettingsDialog({super.key});

  @override
  riverpod.ConsumerState<InvoiceMessageSettingsDialog> createState() =>
      _InvoiceMessageSettingsDialogState();
}

class _InvoiceMessageSettingsDialogState
    extends riverpod.ConsumerState<InvoiceMessageSettingsDialog> {
  late final TextEditingController _bankingController;
  bool _bankingDirty = false;

  @override
  void initState() {
    super.initState();
    _bankingController = TextEditingController(
      text: ref.read(invoiceMessageTemplateRiverpod).bankingDetails,
    );
  }

  @override
  void dispose() {
    _bankingController.dispose();
    super.dispose();
  }

  Future<void> _editTemplate({InvoiceMessageTemplate? existing}) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TemplateEditorDialog(existing: existing),
    );
  }

  Future<void> _confirmDelete(InvoiceMessageTemplate template) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete template?'),
        content: Text('"${template.name}" will be removed for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref
          .read(invoiceMessageTemplateRiverpod)
          .deleteTemplate(template.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _saveBanking() async {
    try {
      await ref
          .read(invoiceMessageTemplateRiverpod)
          .setBankingDetails(_bankingController.text.trim());
      if (mounted) {
        setState(() => _bankingDirty = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Banking details saved'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(invoiceMessageTemplateRiverpod);

    return AlertDialog(
      backgroundColor: ZohoPalette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      title: const Text(
        'Invoice message settings',
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ZohoPalette.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Message templates',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: ZohoPalette.textPrimary,
                      ),
                    ),
                  ),
                  ZohoNewButton(
                    label: 'New template',
                    onPressed: () => _editTemplate(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Tagged by invoice state so the right wording is offered when '
                'you share.',
                style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
              ),
              const SizedBox(height: 10),
              if (provider.isLoading && provider.templates.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (provider.templates.isEmpty)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    border: Border.all(color: ZohoPalette.border),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'No templates yet. Without one, sharing falls back to a '
                    'plain covering message.',
                    style:
                        TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
                  ),
                )
              else
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: ZohoPalette.border),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Column(
                    children: [
                      for (final t in provider.templates)
                        ListTile(
                          dense: true,
                          title: Text(t.name,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            t.body.replaceAll('\n', ' '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, color: ZohoPalette.textMuted),
                          ),
                          leading: _CategoryChip(category: t.category),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit, size: 16),
                                tooltip: 'Edit',
                                onPressed: () => _editTemplate(existing: t),
                              ),
                              IconButton(
                                icon:
                                    const Icon(Icons.delete_outline, size: 16),
                                color: Colors.red.shade400,
                                tooltip: 'Delete',
                                onPressed: () => _confirmDelete(t),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 22),
              const _SyncSettingsSection(),
              const SizedBox(height: 22),
              const Text(
                'Banking details',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: ZohoPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'What {banking_details} is replaced with. Check it carefully — '
                'this goes to customers exactly as typed.',
                style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _bankingController,
                maxLines: 5,
                style: const TextStyle(fontSize: 13),
                onChanged: (_) {
                  if (!_bankingDirty) setState(() => _bankingDirty = true);
                },
                decoration: InputDecoration(
                  hintText: 'Bank: …\nAccount name: …\nAccount number: …\n'
                      'Branch code: …\nReference: invoice number',
                  hintStyle: const TextStyle(
                      fontSize: 12, color: ZohoPalette.textMuted),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: ZohoPalette.border),
                  ),
                ),
              ),
              if (_bankingDirty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: ZohoNewButton(
                      label: 'Save banking details',
                      icon: null,
                      onPressed: _saveBanking,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Ties Zoho invoice state back to the Job List: which job status means
/// cancelled, and how Zoho's statuses map onto your own invoice statuses.
class _SyncSettingsSection extends riverpod.ConsumerWidget {
  const _SyncSettingsSection();

  /// The Zoho statuses worth mapping. Draft is omitted — a draft invoice has
  /// not been issued, so it should not move the Job List column.
  static const _mappable = <ZohoInvoiceStatus>[
    ZohoInvoiceStatus.sent,
    ZohoInvoiceStatus.overdue,
    ZohoInvoiceStatus.partiallyPaid,
    ZohoInvoiceStatus.paid,
    ZohoInvoiceStatus.isVoid,
  ];

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final sync = ref.watch(zohoSyncSettingsRiverpod);
    final jobStatuses = ref.watch(jobListStatusRiverpod).statuses;
    final invoiceStatuses = ref.watch(invoiceStatusRiverpod).statuses;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Job & invoice sync',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: ZohoPalette.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Keeps the Job List and Zoho agreeing in both directions.',
          style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          initialValue: sync.cancelledJobStatusId.isEmpty
              ? null
              : sync.cancelledJobStatusId,
          isExpanded: true,
          decoration: _dropDecoration(
            'Job status that means cancelled',
            helper: 'Moving a job here offers to void its invoice. '
                'Deleting a job always asks.',
          ),
          style: const TextStyle(fontSize: 13, color: ZohoPalette.textPrimary),
          items: [
            const DropdownMenuItem<String>(value: '', child: Text('Not set')),
            ...jobStatuses.map((s) => DropdownMenuItem<String>(
                  value: s.id,
                  child: Text(s.label, overflow: TextOverflow.ellipsis),
                )),
          ],
          onChanged: (id) => sync.setCancelledJobStatusId(id ?? ''),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue:
              sync.noInvoiceStatusId.isEmpty ? null : sync.noInvoiceStatusId,
          isExpanded: true,
          decoration: _dropDecoration(
            'Status when no invoice exists',
            helper: 'Applied to a new or copied job saved with invoicing off '
                'and no number typed.',
          ),
          style: const TextStyle(fontSize: 13, color: ZohoPalette.textPrimary),
          items: [
            const DropdownMenuItem<String>(value: '', child: Text('Not set')),
            ...invoiceStatuses.map((s) => DropdownMenuItem<String>(
                  value: s.id,
                  child: Text(s.label, overflow: TextOverflow.ellipsis),
                )),
          ],
          onChanged: (id) => sync.setNoInvoiceStatusId(id ?? ''),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: sync.invoiceEnteredStatusId.isEmpty
              ? null
              : sync.invoiceEnteredStatusId,
          isExpanded: true,
          decoration: _dropDecoration(
            'Status when an invoice number is entered',
            helper: 'Applied the first time a number is typed by hand — '
                'billed but not yet paid.',
          ),
          style: const TextStyle(fontSize: 13, color: ZohoPalette.textPrimary),
          items: [
            const DropdownMenuItem<String>(value: '', child: Text('Not set')),
            ...invoiceStatuses.map((s) => DropdownMenuItem<String>(
                  value: s.id,
                  child: Text(s.label, overflow: TextOverflow.ellipsis),
                )),
          ],
          onChanged: (id) => sync.setInvoiceEnteredStatusId(id ?? ''),
        ),
        const SizedBox(height: 14),
        const Text(
          'When Zoho or Xero says…  set the job’s Invoice Status to',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: ZohoPalette.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'Applies to Xero too (Authorised → Sent, Voided → Void; overdue and '
          'part-paid are worked out from the invoice). Leave a row unset to '
          'have that status not touch the column. A job marked Paid by hand '
          'always keeps Paid.',
          style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
        ),
        const SizedBox(height: 8),
        for (final status in _mappable)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 130,
                  child: ZohoStatusChip(status: status, dense: true),
                ),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        sync.invoiceStatusMap[status.apiValue]?.isEmpty ?? true
                            ? null
                            : sync.invoiceStatusMap[status.apiValue],
                    isExpanded: true,
                    decoration: _dropDecoration(null),
                    style: const TextStyle(
                        fontSize: 13, color: ZohoPalette.textPrimary),
                    items: [
                      const DropdownMenuItem<String>(
                          value: '', child: Text('Do not change')),
                      ...invoiceStatuses.map((s) => DropdownMenuItem<String>(
                            value: s.id,
                            child:
                                Text(s.label, overflow: TextOverflow.ellipsis),
                          )),
                    ],
                    onChanged: (id) =>
                        sync.setInvoiceStatusMapping(status, id ?? ''),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static InputDecoration _dropDecoration(String? label, {String? helper}) {
    return InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 2,
      labelStyle: const TextStyle(fontSize: 12),
      helperStyle: const TextStyle(fontSize: 10, color: ZohoPalette.textMuted),
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: ZohoPalette.border),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final InvoiceMessageCategory category;

  const _CategoryChip({required this.category});

  Color get _color {
    switch (category) {
      case InvoiceMessageCategory.paid:
        return const Color(0xFF2E9E4F);
      case InvoiceMessageCategory.overdue:
        return const Color(0xFFE03E3E);
      case InvoiceMessageCategory.unpaid:
        return const Color(0xFFE8912D);
      case InvoiceMessageCategory.any:
        return ZohoPalette.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 74,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: _color.withValues(alpha: 0.35)),
      ),
      child: Text(
        category.label.toUpperCase(),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: _color,
        ),
      ),
    );
  }
}

/// Editor for a single template, with tappable chips that insert tokens at
/// the cursor.
class _TemplateEditorDialog extends riverpod.ConsumerStatefulWidget {
  final InvoiceMessageTemplate? existing;

  const _TemplateEditorDialog({this.existing});

  @override
  riverpod.ConsumerState<_TemplateEditorDialog> createState() =>
      _TemplateEditorDialogState();
}

class _TemplateEditorDialogState
    extends riverpod.ConsumerState<_TemplateEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _bodyController;
  final FocusNode _bodyFocus = FocusNode();
  late InvoiceMessageCategory _category;
  bool _isSaving = false;
  String? _error;

  /// Last caret position seen while the message field had focus.
  ///
  /// Tapping a chip blurs the field, which invalidates
  /// `controller.selection` — without remembering it, every insert would land
  /// at the end of the text instead of where the user was typing.
  TextSelection _lastBodySelection = const TextSelection.collapsed(offset: -1);

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _bodyController = TextEditingController(text: widget.existing?.body ?? '');
    _category = widget.existing?.category ?? InvoiceMessageCategory.any;

    _bodyController.addListener(() {
      final selection = _bodyController.selection;
      if (selection.isValid) _lastBodySelection = selection;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bodyController.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  /// Insert the tag at the caret, replacing any selected text, so tags can be
  /// placed mid-sentence and never have to be typed by hand.
  void _insertToken(InvoiceMessageToken token) {
    final text = _bodyController.text;

    // The live selection is gone once the chip takes focus, so fall back to
    // the last caret seen while the field was focused, then to the end.
    var selection = _bodyController.selection;
    if (!selection.isValid) selection = _lastBodySelection;

    final at =
        selection.isValid ? selection.start.clamp(0, text.length) : text.length;
    final end =
        selection.isValid ? selection.end.clamp(0, text.length) : text.length;

    final updated = text.replaceRange(at, end, token.placeholder);
    final caret = at + token.placeholder.length;

    _bodyController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: caret),
    );
    _lastBodySelection = TextSelection.collapsed(offset: caret);

    // Hand focus back so the caret is visible and typing continues where the
    // tag landed, instead of the field sitting blurred.
    _bodyFocus.requestFocus();
  }

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _error = 'Give the template a name.');
      return;
    }
    if (_bodyController.text.trim().isEmpty) {
      setState(() => _error = 'The message cannot be empty.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    final provider = ref.read(invoiceMessageTemplateRiverpod);
    final draft = InvoiceMessageTemplate(
      id: widget.existing?.id ?? '',
      name: _nameController.text.trim(),
      body: _bodyController.text.trim(),
      category: _category,
      order: widget.existing?.order ?? provider.templates.length,
    );

    try {
      if (widget.existing == null) {
        await provider.addTemplate(draft);
      } else {
        await provider.updateTemplate(draft);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: ZohoPalette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      title: Text(
        widget.existing == null ? 'New template' : 'Edit template',
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: ZohoPalette.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameController,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration:
                    _decoration('Template name', hint: 'e.g. Payment reminder'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<InvoiceMessageCategory>(
                initialValue: _category,
                decoration: _decoration('Use for'),
                style: const TextStyle(
                    fontSize: 13, color: ZohoPalette.textPrimary),
                items: InvoiceMessageCategory.values
                    .map((c) => DropdownMenuItem(
                          value: c,
                          child: Text(c.label),
                        ))
                    .toList(),
                onChanged: (c) =>
                    setState(() => _category = c ?? InvoiceMessageCategory.any),
              ),
              const SizedBox(height: 14),
              const Text(
                'Insert a tag',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: ZohoPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final token in InvoiceMessageToken.values)
                    ActionChip(
                      label: Text(token.label,
                          style: const TextStyle(fontSize: 11)),
                      onPressed: () => _insertToken(token),
                      visualDensity: VisualDensity.compact,
                      side: const BorderSide(color: ZohoPalette.border),
                      backgroundColor: ZohoPalette.pageBackground,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _bodyController,
                focusNode: _bodyFocus,
                maxLines: 8,
                style: const TextStyle(fontSize: 13),
                decoration: _decoration(
                  'Message',
                  hint: 'Hi {client_name},\n\nInvoice {invoice_number} for '
                      '{total} is due on {due_date}.\n\n{banking_details}',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ZohoNewButton(
          label: _isSaving ? 'Saving…' : 'Save',
          icon: null,
          onPressed: _isSaving ? null : _save,
        ),
      ],
    );
  }

  InputDecoration _decoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
      labelStyle: const TextStyle(fontSize: 13),
      isDense: true,
      alignLabelWithHint: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: ZohoPalette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: ZohoPalette.link),
      ),
    );
  }
}
