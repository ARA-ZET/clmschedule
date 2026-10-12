import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:url_launcher/url_launcher.dart';

import '../models/distribution_report.dart';
import '../models/distribution_report_template.dart';
import '../models/job_list_item.dart';
import '../providers/distribution_report_template_provider.dart';
import '../providers/job_list_provider.dart';
import '../services/distribution_report_service.dart';
import '../utils/gmail_compose.dart';

/// Compile and send the client-facing distribution report for [item].
///
/// Opens straight into a loading state and compiles on the way — the data
/// comes from three round-trips and there is nothing useful to show first.
Future<void> showDistributionReportDialog(
  BuildContext context,
  JobListItem item,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _DistributionReportDialog(item: item),
  );
}

class _DistributionReportDialog extends riverpod.ConsumerStatefulWidget {
  final JobListItem item;

  const _DistributionReportDialog({required this.item});

  @override
  riverpod.ConsumerState<_DistributionReportDialog> createState() =>
      _DistributionReportDialogState();
}

class _DistributionReportDialogState
    extends riverpod.ConsumerState<_DistributionReportDialog> {
  final _greeting = TextEditingController();
  final _subject = TextEditingController();

  DistributionReport? _report;
  String? _compileError;
  bool _loading = true;

  /// Selected template's **id**, not the object — the provider replaces its
  /// whole list on reload and the template has no value equality, which would
  /// leave the dropdown with a value matching none of its items.
  String? _templateId;

  final Set<String> _selectedFolders = {};

  /// Null until the user overrides the invoice-derived default.
  bool? _includeInvoiceLine;

  bool _writeBackQuantity = false;

  @override
  void initState() {
    super.initState();
    _compile();
  }

  @override
  void dispose() {
    _greeting.dispose();
    _subject.dispose();
    super.dispose();
  }

  Future<void> _compile() async {
    try {
      final report = await DistributionReportService().compile(widget.item);
      if (!mounted) return;
      setState(() {
        _report = report;
        _selectedFolders
          ..clear()
          ..addAll(report.readableFolders.map((f) => f.path));
        // Only offer the write-back when the row has no figure of its own.
        // Silently replacing a manually entered number would be worse than
        // making the user tick a box.
        _writeBackQuantity = report.recordedQuantityDistributed == 0;
        _subject.text = _defaultSubject(report);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _compileError = '$e';
        _loading = false;
      });
    }
  }

  String _defaultSubject(DistributionReport report) {
    final totals = report.totalsFor(_selectedFolders);
    final date = totals.startDate;
    final when =
        date == null ? '' : ' — ${DistributionReportFormat.date.format(date)}';
    return 'Distribution Report — ${report.client}$when';
  }

  // ---------------------------------------------------------------------------
  // Derived values
  // ---------------------------------------------------------------------------

  bool get _invoiceLineDefault {
    final report = _report;
    if (report == null) return false;
    return report.hasInvoice && !report.invoiceIsPaid;
  }

  bool get _includeInvoice => _includeInvoiceLine ?? _invoiceLineDefault;

  /// The template in force.
  ///
  /// A single template is unambiguous, so it is treated as chosen without the
  /// user picking it. With a choice, nothing is chosen until they say so — the
  /// wrong wording sent to a client cannot be taken back.
  ///
  /// Derived rather than assigned, so nothing writes state during `build`.
  DistributionReportTemplate? _resolveTemplate(
    List<DistributionReportTemplate> available,
  ) {
    if (available.isEmpty) return null;
    final id = _templateId ?? (available.length == 1 ? available.first.id : null);
    if (id == null) return null;
    for (final t in available) {
      if (t.id == id) return t;
    }
    // Deleted or re-ordered while the dialog was open.
    return null;
  }

  String _renderBody(DistributionReportTemplate template) {
    final report = _report!;
    final totals = report.totalsFor(_selectedFolders);
    return template.render(DistributionReportValues(
      greetingName: _greeting.text.trim(),
      startDate: totals.startDate == null
          ? ''
          : DistributionReportFormat.date.format(totals.startDate!),
      quantityDistributed:
          DistributionReportFormat.quantity.format(totals.quantityDistributed),
      distributionAreas: DistributionReportFormat.areaList(report.areas),
      mapLink: report.mapLink,
      client: report.client,
      includeInvoiceLine: _includeInvoice,
    ));
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _maybeWriteBackQuantity() async {
    final report = _report;
    if (report == null || !_writeBackQuantity) return;

    final totals = report.totalsFor(_selectedFolders);
    if (totals.quantityDistributed == widget.item.quantityDistributed) return;

    try {
      await ref.read(jobListRiverpod).updateJobListItemWithTracking(
            widget.item,
            widget.item
                .copyWith(quantityDistributed: totals.quantityDistributed),
          );
    } catch (e) {
      debugPrint('[DistributionReport] quantity write-back failed: $e');
    }
  }

  Future<void> _copy(String body) async {
    await Clipboard.setData(ClipboardData(text: body));
    await _maybeWriteBackQuantity();
    if (!mounted) return;
    _close('Report copied to clipboard.');
  }

  Future<void> _openGmail(String body) async {
    final report = _report!;
    final url = buildGmailComposeUrl(
      to: report.recipients,
      subject: _subject.text.trim(),
      body: body,
    );

    // Captured before the first await: this dialog closes partway through, so
    // its context is gone by the time the result needs reporting.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // Always on the clipboard, whether or not it fitted in the URL — the user
    // still has to attach the invoice by hand, and may want to paste rather
    // than retype if anything goes wrong with the draft.
    await Clipboard.setData(ClipboardData(text: body));
    await _maybeWriteBackQuantity();

    navigator.pop();

    try {
      final ok = await launchUrl(url.uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Could not open Gmail. The report is on your '
              'clipboard.'),
          backgroundColor: Colors.red,
        ));
        return;
      }
      messenger.showSnackBar(SnackBar(
        content: Text(url.bodyIncluded
            ? 'Gmail draft opened. Report also copied to your clipboard.'
            : 'Report too long for the draft URL — paste it into the '
                'draft (it is on your clipboard).'),
        backgroundColor: url.bodyIncluded ? null : Colors.orange.shade800,
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Could not open Gmail: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  void _close(String message) {
    // Messenger resolved before the pop: afterwards this dialog's context is
    // defunct and the snackbar would have nowhere to land.
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Distribution Report'),
      content: SizedBox(
        width: 620,
        child: _buildContent(),
      ),
      actions: _buildActions(),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_compileError != null) {
      return _message(
        Icons.error_outline,
        Colors.red,
        'Could not compile the report:\n$_compileError',
      );
    }

    final report = _report!;
    if (!report.hasMap) {
      return _message(
        Icons.map_outlined,
        Colors.orange.shade800,
        report.mapError ?? 'No map is linked to this job.',
      );
    }

    final available = ref.watch(distributionReportTemplateRiverpod).available;
    final template = _resolveTemplate(available);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _summary(report),
          const SizedBox(height: 12),
          TextField(
            controller: _greeting,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Greeting name *',
              hintText: 'Who to address, e.g. Nicola',
              helperText: 'The name after "Hi" — not the account name.',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _subject,
            decoration: const InputDecoration(
              labelText: 'Subject',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          if (available.length > 1) ...[
            DropdownButtonFormField<String>(
              initialValue: template?.id,
              isExpanded: true,
              hint: const Text('Choose a report…'),
              decoration: const InputDecoration(
                labelText: 'Template *',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: available
                  .map((t) => DropdownMenuItem(
                        value: t.id,
                        child: Text(t.name, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (id) => setState(() => _templateId = id),
            ),
            const SizedBox(height: 12),
          ],
          if (report.folders.length > 1) _folderPicker(report),
          _invoiceControls(report),
          _quantityWriteBack(report),
          const SizedBox(height: 12),
          const Text('Preview',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 220),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                template == null
                    ? 'Choose a template to see the report.'
                    : _renderBody(template),
                style: const TextStyle(fontSize: 12, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _message(IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  /// The compiled facts, stated plainly so a wrong one is obvious before it
  /// reaches a client.
  Widget _summary(DistributionReport report) {
    final totals = report.totalsFor(_selectedFolders);
    final date = totals.startDate;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Client', report.client),
          _row(
            'Start date',
            date == null
                ? 'Unknown'
                : DistributionReportFormat.date.format(date),
            // A date taken off the GPS needs no explanation; an inferred one
            // does, because it is the number most likely to be wrong.
            note: totals.dateSource.isMeasured
                ? null
                : totals.dateSource.label,
          ),
          _row(
            'Quantity distributed',
            DistributionReportFormat.quantity
                .format(totals.quantityDistributed),
            note: report.quantityOrdered > 0
                ? '${DistributionReportFormat.quantity.format(report.quantityOrdered)} ordered'
                : null,
          ),
          _row(
            'Areas',
            report.areas.isEmpty
                ? 'None found on the map'
                : DistributionReportFormat.areaList(report.areas),
          ),
          _row(
            'To',
            report.recipients.isEmpty
                ? 'No Report Addresses on this job'
                : report.recipients.join(', '),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {String? note}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(
                text: value,
                style: const TextStyle(fontSize: 12),
              ),
              if (note != null)
                TextSpan(
                  text: '  ($note)',
                  style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                ),
            ])),
          ),
        ],
      ),
    );
  }

  /// Shown only when a map carries more than one cloud folder.
  ///
  /// Maps accumulate folders across months, so a map reused for a repeat job
  /// can carry an earlier job's round. Summing those silently would overstate
  /// the figure on a client's report.
  Widget _folderPicker(DistributionReport report) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Cloud folders',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        const Text(
          'This map has more than one folder. Untick any that belong to a '
          'different job.',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
        for (final folder in report.folders)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _selectedFolders.contains(folder.path),
            onChanged: folder.error != null
                ? null
                : (on) => setState(() {
                      if (on ?? false) {
                        _selectedFolders.add(folder.path);
                      } else {
                        _selectedFolders.remove(folder.path);
                      }
                    }),
            title: Text(folder.label, style: const TextStyle(fontSize: 12)),
            subtitle: Text(
              folder.error ??
                  '${DistributionReportFormat.quantity.format(folder.waypointCount)} letterboxes'
                      '${folder.date == null ? '' : ' · ${DistributionReportFormat.date.format(folder.date!)}'}',
              style: TextStyle(
                fontSize: 11,
                color: folder.error != null ? Colors.red : Colors.grey,
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _invoiceControls(DistributionReport report) {
    if (!report.hasInvoice) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _includeInvoice,
          onChanged: (on) => setState(() => _includeInvoiceLine = on ?? false),
          title: const Text('Include "$kInvoiceAttachedLine"',
              style: TextStyle(fontSize: 12)),
          subtitle: Text(
            report.invoiceIsPaid
                ? '${report.invoiceNumber} is paid, so the line is off by default.'
                : '${report.invoiceNumber} is unpaid.',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
        if (_includeInvoice)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.attach_file,
                    size: 14, color: Colors.orange.shade800),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Attach the invoice PDF to the draft yourself — Gmail '
                    'cannot be given a file from here. The invoice icon in '
                    'the Actions column downloads it.',
                    style: TextStyle(
                        fontSize: 11, color: Colors.orange.shade900),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _quantityWriteBack(DistributionReport report) {
    final totals = report.totalsFor(_selectedFolders);
    if (totals.quantityDistributed == report.recordedQuantityDistributed) {
      return const SizedBox.shrink();
    }

    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: _writeBackQuantity,
      onChanged: (on) => setState(() => _writeBackQuantity = on ?? false),
      title: const Text('Update Qty Distributed on this job',
          style: TextStyle(fontSize: 12)),
      subtitle: Text(
        '${DistributionReportFormat.quantity.format(report.recordedQuantityDistributed)}'
        ' → ${DistributionReportFormat.quantity.format(totals.quantityDistributed)}',
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
    );
  }

  List<Widget> _buildActions() {
    final report = _report;
    final ready = !_loading && _compileError == null && report != null &&
        report.hasMap;

    if (!ready) {
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ];
    }

    final available = ref.read(distributionReportTemplateRiverpod).available;
    final template = _resolveTemplate(available);
    // Both guards matter: an email opening "Hi ," and a report sent from the
    // wrong template are each worse than a moment's friction.
    final canSend = template != null && _greeting.text.trim().isNotEmpty;
    final body = template == null ? '' : _renderBody(template);

    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton.icon(
        onPressed: canSend ? () => _copy(body) : null,
        icon: const Icon(Icons.copy, size: 16),
        label: const Text('Copy report'),
      ),
      FilledButton.icon(
        onPressed: canSend ? () => _openGmail(body) : null,
        icon: const Icon(Icons.mail_outline, size: 16),
        label: const Text('Open Gmail'),
      ),
    ];
  }
}
