import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/distributor.dart';
import '../../models/distributor_payroll_profile.dart';
import '../../models/payment_account.dart';
import '../../providers/payroll_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../utils/digit_grouping.dart';
import '../../utils/south_african_banks.dart';

const List<String> _kPaymentMethods = ['eWallet', 'Bank account'];

/// Opens the payment-accounts manager for one distributor — add, edit,
/// delete, and pick a default among their saved eWallet numbers / bank
/// accounts. They can have several and alternate between them without
/// losing any: each payroll week just records which one it used.
Future<void> showManagePaymentAccountsDialog(
  BuildContext context, {
  required String distributorId,
}) {
  return showDialog(
    context: context,
    builder: (_) =>
        ManagePaymentAccountsDialog(distributorId: distributorId),
  );
}

class ManagePaymentAccountsDialog extends riverpod.ConsumerWidget {
  final String distributorId;

  const ManagePaymentAccountsDialog({super.key, required this.distributorId});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final schedule = ref.watch(scheduleRiverpod);
    Distributor? distributor;
    for (final d in schedule.distributors) {
      if (d.id == distributorId) {
        distributor = d;
        break;
      }
    }
    final profile = distributor?.payroll ?? const DistributorPayrollProfile();
    final accounts = profile.paymentAccounts;

    return AlertDialog(
      title: Text('${distributor?.name ?? 'Distributor'} — payment accounts'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (accounts.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'No payment accounts saved yet.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final a in accounts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(a.method == 'eWallet'
                      ? Icons.phone_android
                      : Icons.account_balance),
                  title: Text(a.label.isNotEmpty ? a.label : a.method),
                  subtitle: Text(a.summary),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          a.id == profile.defaultPaymentAccountId
                              ? Icons.star
                              : Icons.star_border,
                          color: a.id == profile.defaultPaymentAccountId
                              ? Colors.amber.shade700
                              : null,
                        ),
                        tooltip: 'Set as default for new weeks',
                        onPressed: () => ref
                            .read(payrollRiverpod)
                            .setDefaultPaymentAccount(distributorId, a.id),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        tooltip: 'Edit',
                        onPressed: () async {
                          final updated = await showDialog<PaymentAccount>(
                            context: context,
                            builder: (_) => _AccountFormDialog(initial: a),
                          );
                          if (updated != null) {
                            await ref
                                .read(payrollRiverpod)
                                .updatePaymentAccount(distributorId, updated);
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: 'Remove',
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Remove account?'),
                              content: Text(
                                  'Remove "${a.summary}"? This can\'t be undone.'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  child: const Text('Remove'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await ref
                                .read(payrollRiverpod)
                                .deletePaymentAccount(distributorId, a.id);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add account'),
                  onPressed: () async {
                    final created = await showDialog<PaymentAccount>(
                      context: context,
                      builder: (_) => const _AccountFormDialog(),
                    );
                    if (created != null) {
                      await ref
                          .read(payrollRiverpod)
                          .addPaymentAccount(distributorId, created);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _AccountFormDialog extends StatefulWidget {
  final PaymentAccount? initial;

  const _AccountFormDialog({this.initial});

  @override
  State<_AccountFormDialog> createState() => _AccountFormDialogState();
}

class _AccountFormDialogState extends State<_AccountFormDialog> {
  late String _method;
  late TextEditingController _label;
  String? _bankName;
  late TextEditingController _accountHolder;
  late TextEditingController _accountOrPhone;
  late TextEditingController _branchCode;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _method = i?.method ?? 'eWallet';
    _label = TextEditingController(text: i?.label ?? '');
    _bankName = i?.bankName;
    _accountHolder = TextEditingController(text: i?.accountHolder ?? '');
    _accountOrPhone = TextEditingController(
      text: groupDigits(
          _method == 'eWallet' ? (i?.ewalletNumber ?? '') : (i?.accountNumber ?? '')),
    );
    _branchCode = TextEditingController(text: i?.branchCode ?? '');
  }

  @override
  void dispose() {
    _label.dispose();
    _accountHolder.dispose();
    _accountOrPhone.dispose();
    _branchCode.dispose();
    super.dispose();
  }

  void _switchMethod(String newMethod) {
    // Clear the account/phone field when switching type — a bank account
    // number and an eWallet phone number are different values, and keeping
    // one visible under the other's label would be misleading.
    setState(() {
      _method = newMethod;
      _accountOrPhone.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isBank = _method == 'Bank account';
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add account' : 'Edit account'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _method,
                decoration: const InputDecoration(labelText: 'Payment method'),
                items: _kPaymentMethods
                    .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) _switchMethod(v);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _label,
                decoration: const InputDecoration(
                  labelText: 'Label (optional)',
                  hintText: 'e.g. "Main", "Mom\'s number"',
                ),
              ),
              const SizedBox(height: 12),
              if (isBank) ...[
                DropdownButtonFormField<String>(
                  initialValue:
                      southAfricanBanks.contains(_bankName) ? _bankName : null,
                  decoration: const InputDecoration(labelText: 'Bank'),
                  items: southAfricanBanks
                      .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                      .toList(),
                  onChanged: (v) => setState(() => _bankName = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _accountHolder,
                  decoration: const InputDecoration(
                      labelText: 'Account holder (optional)'),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _accountOrPhone,
                inputFormatters: [GroupedDigitsFormatter()],
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: isBank ? 'Account number' : 'Phone number',
                ),
              ),
              if (isBank) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _branchCode,
                  decoration:
                      const InputDecoration(labelText: 'Branch code (optional)'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final raw = stripDigitGrouping(_accountOrPhone.text);
            final account = PaymentAccount(
              id: widget.initial?.id ??
                  DateTime.now().microsecondsSinceEpoch.toString(),
              method: _method,
              label: _label.text.trim(),
              bankName: isBank ? _bankName : null,
              accountHolder: isBank && _accountHolder.text.trim().isNotEmpty
                  ? _accountHolder.text.trim()
                  : null,
              accountNumber: isBank ? raw : null,
              branchCode: isBank && _branchCode.text.trim().isNotEmpty
                  ? _branchCode.text.trim()
                  : null,
              ewalletNumber: !isBank ? raw : null,
            );
            Navigator.of(context).pop(account);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
