import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:url_launcher/url_launcher.dart';

import '../../models/xero_org.dart';
import '../../services/xero_accounting_service.dart';

/// Xero settings for a company, edited inside the company management dialog.
///
/// Nothing here is hardcoded, deliberately. The revenue account code and the
/// VAT tax type are organisation-specific — Xero's South African vocabulary
/// differs from the demo company's, and the chart of accounts differs between
/// organisations — so both are read live from the connected tenant and chosen
/// once by an admin. They are stored in `Company.providerConfig`, the free-form
/// map that exists for exactly this.
///
/// Keys written: `salesAccountCode`, `salesTaxType`.
class XeroCompanyConfig extends riverpod.ConsumerStatefulWidget {
  final Map<String, String> config;
  final ValueChanged<Map<String, String>> onChanged;

  const XeroCompanyConfig({
    super.key,
    required this.config,
    required this.onChanged,
  });

  @override
  riverpod.ConsumerState<XeroCompanyConfig> createState() =>
      _XeroCompanyConfigState();
}

class _XeroCompanyConfigState
    extends riverpod.ConsumerState<XeroCompanyConfig> {
  XeroConnectionStatus? _status;
  XeroOrganisation? _organisation;
  List<XeroAccount> _accounts = const [];
  List<XeroTaxRate> _taxRates = const [];

  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final service = ref.read(xeroAccountingServiceRiverpod);
    try {
      final status = await service.connectionStatus();
      if (!status.connected) {
        if (!mounted) return;
        setState(() {
          _status = status;
          _isLoading = false;
        });
        return;
      }

      // Three reads against a 1,000/day budget, so this loads on demand when
      // the Xero section is opened — never on app start.
      final results = await Future.wait([
        service.getOrganisation(),
        service.listRevenueAccounts(),
        service.listTaxRates(),
      ]);

      if (!mounted) return;
      setState(() {
        _status = status;
        _organisation = results[0] as XeroOrganisation;
        _accounts = results[1] as List<XeroAccount>;
        _taxRates = results[2] as List<XeroTaxRate>;
        _isLoading = false;
      });
    } on XeroException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _isLoading = false;
      });
    }
  }

  void _set(String key, String? value) {
    final next = Map<String, String>.from(widget.config);
    if (value == null || value.isEmpty) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Text('Reading settings from Xero…', style: TextStyle(fontSize: 12)),
          ],
        ),
      );
    }

    if (_error != null) {
      return _Notice(
        icon: Icons.error_outline,
        color: Colors.red,
        title: 'Could not read from Xero',
        body: _error!,
        onRetry: _load,
      );
    }

    if (_status?.connected != true) {
      return _Notice(
        icon: Icons.link_off,
        color: Colors.orange,
        title: 'Xero is not connected',
        body: 'Run the one-off consent script (~/xero_connect.js) to authorise '
            'an organisation. Until then, jobs can be tagged as Xero but no '
            'invoice can be raised.',
        onRetry: _load,
      );
    }

    final org = _organisation;
    final selectedAccount = widget.config['salesAccountCode'] ?? '';
    final selectedTaxType = widget.config['salesTaxType'] ?? '';

    // Xero flags which rates may be used on a revenue account. Prefer those,
    // but never present an empty dropdown with nothing to explain it — some
    // organisations report the flag inconsistently.
    final revenueRates = _taxRates.where((t) => t.canApplyToRevenue).toList();
    final offeredRates = revenueRates.isEmpty ? _taxRates : revenueRates;
    final hasFifteen = offeredRates.any((t) => t.effectiveRate == 15);

    // A tax type saved earlier may not exist on the currently connected
    // organisation — switching from the demo company to the live books is
    // exactly that case. Dropping the value into a dropdown that has no
    // matching item throws, so fall back to null and flag it.
    final accountExists = _accounts.any((a) => a.code == selectedAccount);
    final taxTypeExists = offeredRates.any((t) => t.taxType == selectedTaxType);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(Icons.check_circle, size: 15, color: Color(0xFF2E9E4F)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Connected to ${org?.name ?? _status!.tenantName}'
                '${org != null ? ' · ${org.countryCode} · ${org.baseCurrency}' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 16),
              tooltip: 'Reload from Xero',
              onPressed: _load,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        if (org?.isDemoCompany == true)
          const Padding(
            padding: EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              'This is Xero\'s Demo Company — invoices raised here are not real, '
              'and its tax rates are not the live organisation\'s.',
              style: TextStyle(fontSize: 11, color: Colors.orange),
            ),
          ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          initialValue: accountExists ? selectedAccount : null,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Sales account',
            helperText: 'Revenue account invoice lines post to',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: _accounts
              .map((a) => DropdownMenuItem(
                    value: a.code,
                    child:
                        Text(a.displayLabel, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (v) => _set('salesAccountCode', v),
        ),
        if (selectedAccount.isNotEmpty && !accountExists)
          _staleValue('Saved account code "$selectedAccount" does not exist on '
              'this organisation. Pick one again.'),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          initialValue: taxTypeExists ? selectedTaxType : null,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'VAT rate',
            helperText:
                'Applied to invoice lines when the job type charges VAT',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: offeredRates
              .map((t) => DropdownMenuItem(
                    value: t.taxType,
                    child:
                        Text(t.displayLabel, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (v) => _set('salesTaxType', v),
        ),
        if (selectedTaxType.isNotEmpty && !taxTypeExists)
          _staleValue(
              'Saved tax type "$selectedTaxType" does not exist on this '
              'organisation. Pick one again.'),
        // The list is whatever the connected organisation has. Rates are
        // defined in Xero — the app must send a TaxType Xero already knows, so
        // a percentage typed here would simply be rejected.
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(hasFifteen ? Icons.info_outline : Icons.warning_amber,
                  size: 14,
                  color:
                      hasFifteen ? theme.colorScheme.outline : Colors.orange),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasFifteen
                      ? 'Rates come from Xero. To add or change one, edit it in '
                          'Xero and press reload above.'
                      : 'This organisation has no 15% rate. South African Xero '
                          'organisations include one — if you are still on the '
                          'Demo Company, that is why. Add or edit rates in Xero, '
                          'then press reload above.',
                  style: TextStyle(
                    fontSize: 11,
                    color: hasFifteen
                        ? theme.colorScheme.outline
                        : Colors.orange.shade800,
                  ),
                ),
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.open_in_new, size: 15),
            label: const Text('Manage tax rates in Xero',
                style: TextStyle(fontSize: 12)),
            onPressed: () => launchUrl(
              Uri.parse('https://go.xero.com/app/!-/accounting/tax-rates'),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ),
        if (revenueRates.isEmpty && _taxRates.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'None of this organisation\'s rates are flagged for use on '
              'revenue, so all active rates are listed. Pick a sales/output '
              'one — Xero rejects a purchases rate on a sales invoice.',
              style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
            ),
          ),
      ],
    );
  }

  Widget _staleValue(String message) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(message,
            style: const TextStyle(fontSize: 11, color: Colors.red)),
      );
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final VoidCallback onRetry;

  const _Notice({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color)),
                const SizedBox(height: 2),
                Text(body, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
