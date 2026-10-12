import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/zoho_item.dart';
import '../../models/zoho_item_autofill.dart';
import '../../providers/zoho_item_autofill_provider.dart';
import '../../providers/zoho_items_provider.dart';
import 'zoho_table.dart';

/// Edit what each Zoho item autofills onto an invoice line.
///
/// Zoho's own item description is a catalogue entry — it describes the service
/// in general. An invoice line usually wants to describe *this* job, so each
/// item can carry a template whose tokens are filled from the job when the
/// line is created.
///
/// Leaving both fields blank stores nothing and falls back to the catalogue
/// text, so an item nobody has configured behaves exactly as before.
class ZohoItemAutofillDialog extends riverpod.ConsumerStatefulWidget {
  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  const ZohoItemAutofillDialog({super.key, required this.orgId});

  @override
  riverpod.ConsumerState<ZohoItemAutofillDialog> createState() =>
      _ZohoItemAutofillDialogState();
}

class _ZohoItemAutofillDialogState
    extends riverpod.ConsumerState<ZohoItemAutofillDialog> {
  /// Item currently expanded for editing.
  String? _editingId;

  late final TextEditingController _name;
  late final TextEditingController _description;

  /// Which field the token chips insert into.
  bool _tokenTargetIsDescription = true;

  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _description = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(zohoItemsRiverpod(widget.orgId)).ensureLoaded();
      ref.read(zohoItemAutofillRiverpod).ensureLoaded();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _startEdit(ZohoItem item) {
    final existing = ref.read(zohoItemAutofillRiverpod).forItem(item.itemId);
    setState(() {
      _editingId = item.itemId;
      _error = null;
      _name.text = existing?.nameTemplate ?? '';
      _description.text = existing?.descriptionTemplate ?? '';
      _tokenTargetIsDescription = true;
    });
  }

  Future<void> _save() async {
    final id = _editingId;
    if (id == null) return;

    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await ref.read(zohoItemAutofillRiverpod).save(ZohoItemAutofill(
            itemId: id,
            nameTemplate: _name.text.trim(),
            descriptionTemplate: _description.text.trim(),
          ));
      if (!mounted) return;
      setState(() {
        _editingId = null;
        _isSaving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _error = '$e';
      });
    }
  }

  void _insertToken(ItemAutofillToken token) {
    final controller = _tokenTargetIsDescription ? _description : _name;
    final selection = controller.selection;
    final text = controller.text;

    // Insert at the caret when there is one, otherwise append — a chip tapped
    // before the field has been focused should still do something.
    final at = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;

    controller.text = text.replaceRange(at, end, token.placeholder);
    controller.selection = TextSelection.collapsed(
      offset: at + token.placeholder.length,
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(zohoItemsRiverpod(widget.orgId));
    final autofills = ref.watch(zohoItemAutofillRiverpod);

    return AlertDialog(
      backgroundColor: ZohoPalette.surface,
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Invoice line autofill'),
          Text(
            'What each Zoho item puts on the line',
            style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: items.isLoading || autofills.isLoading
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : items.items.isEmpty
                ? Text(
                    items.error ??
                        'No items in Zoho Books yet. Add them under Items in '
                            'Zoho, then reopen this.',
                    style: const TextStyle(
                        fontSize: 13, color: ZohoPalette.textMuted),
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final item in items.items) _buildRow(item),
                        if (_error != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            _error!,
                            style: TextStyle(
                                fontSize: 12, color: Colors.red.shade800),
                          ),
                        ],
                      ],
                    ),
                  ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildRow(ZohoItem item) {
    final autofill = ref.read(zohoItemAutofillRiverpod).forItem(item.itemId);
    final isEditing = _editingId == item.itemId;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: isEditing ? ZohoPalette.link : ZohoPalette.border,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            title: Text(item.displayName,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            subtitle: Text(
              autofill == null || autofill.isEmpty
                  ? 'Uses Zoho’s own description'
                  : autofill.descriptionTemplate.isNotEmpty
                      ? autofill.descriptionTemplate
                      : autofill.nameTemplate,
              style: TextStyle(
                fontSize: 11,
                fontStyle: (autofill == null || autofill.isEmpty)
                    ? FontStyle.italic
                    : FontStyle.normal,
                color: ZohoPalette.textMuted,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: TextButton(
              onPressed: _isSaving
                  ? null
                  : () => isEditing
                      ? setState(() => _editingId = null)
                      : _startEdit(item),
              child: Text(isEditing ? 'Cancel' : 'Edit',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
          if (isEditing) _buildEditor(),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            enabled: !_isSaving,
            onTap: () => setState(() => _tokenTargetIsDescription = false),
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Item name',
              helperText: 'Blank keeps the name Zoho stores.',
              helperStyle: TextStyle(fontSize: 11),
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _description,
            enabled: !_isSaving,
            onTap: () => setState(() => _tokenTargetIsDescription = true),
            minLines: 2,
            maxLines: null,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Description',
              helperText: 'Blank keeps the description Zoho stores.',
              helperStyle: TextStyle(fontSize: 11),
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Insert into ${_tokenTargetIsDescription ? 'description' : 'item name'}:',
            style: const TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final token in ItemAutofillToken.values)
                ActionChip(
                  label:
                      Text(token.label, style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  onPressed: _isSaving ? null : () => _insertToken(token),
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'A token with no value on the job disappears, and the punctuation '
            'around it is tidied up.',
            style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: ZohoNewButton(
              label: _isSaving ? 'Saving…' : 'Save',
              icon: null,
              onPressed: _isSaving ? null : _save,
            ),
          ),
        ],
      ),
    );
  }
}
