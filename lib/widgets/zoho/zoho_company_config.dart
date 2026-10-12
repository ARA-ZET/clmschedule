import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../services/zoho_books_service.dart';
import '../../utils/zoho_org.dart';

/// Zoho settings for a company, edited inside the company management dialog.
///
/// One Zoho login holds several organisations (Junk & Stuff, Happy Sun), so the
/// only per-company setting is which organisation its books are in. The list is
/// read live from Zoho so nobody has to copy an id out of Zoho's settings.
///
/// Key written: `organizationId` ([ZohoOrg.configKey]). Left blank, the company
/// falls back to its well-known id in [ZohoOrg].
class ZohoCompanyConfig extends riverpod.ConsumerStatefulWidget {
  final String companyId;
  final Map<String, String> config;
  final ValueChanged<Map<String, String>> onChanged;

  const ZohoCompanyConfig({
    super.key,
    required this.companyId,
    required this.config,
    required this.onChanged,
  });

  @override
  riverpod.ConsumerState<ZohoCompanyConfig> createState() =>
      _ZohoCompanyConfigState();
}

class _ZohoCompanyConfigState
    extends riverpod.ConsumerState<ZohoCompanyConfig> {
  List<({String id, String name})> _orgs = const [];
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
    try {
      // Any org's client will do — listing organisations is not org-scoped.
      final orgs = await ref
          .read(zohoBooksServiceRiverpod(ZohoOrg.junkAndStuff))
          .listOrganizations();
      if (!mounted) return;
      setState(() => _orgs = orgs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String get _effectiveId {
    final configured = widget.config[ZohoOrg.configKey]?.trim() ?? '';
    return configured.isNotEmpty
        ? configured
        : ZohoOrg.forCompanyId(widget.companyId);
  }

  @override
  Widget build(BuildContext context) {
    final current = _effectiveId;

    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Row(children: [
          SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Loading Zoho organisations…', style: TextStyle(fontSize: 12)),
        ]),
      );
    }

    if (_error != null || _orgs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Zoho organisation: $current'
              '${_error == null ? '' : '\nCould not list organisations: $_error'}',
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final known = _orgs.any((o) => o.id == current);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DropdownButtonFormField<String>(
        initialValue: known ? current : null,
        decoration: InputDecoration(
          labelText: 'Zoho Books organisation',
          helperText: known
              ? 'Invoices and customers for this company live here'
              : 'Saved id $current is not one this Zoho login can reach',
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: _orgs
            .map((o) => DropdownMenuItem(
                  value: o.id,
                  child: Text('${o.name} (${o.id})'),
                ))
            .toList(),
        onChanged: (id) {
          if (id == null) return;
          widget.onChanged({...widget.config, ZohoOrg.configKey: id});
        },
      ),
    );
  }
}
