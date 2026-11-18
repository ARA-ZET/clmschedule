import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/distributor.dart';
import '../../models/payslip_account.dart';
import '../../providers/auth_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../services/payslip_access_service.dart';
import '../../utils/friendly_error.dart';
import '../app_toast.dart';

final payslipAccessServiceRiverpod =
    riverpod.Provider<PayslipAccessService>((ref) => PayslipAccessService());

/// Every payslip sign-up, live. Only admins can read it (firestore.rules),
/// and it is only watched from the admin-gated Payroll tab.
final payslipAccountsRiverpod =
    riverpod.StreamProvider<List<PayslipAccount>>((ref) {
  return ref.watch(payslipAccessServiceRiverpod).streamAccounts();
});

final _when = DateFormat('d MMM yyyy, HH:mm');

/// Payroll top-bar button: opens [PayslipAccessPage], with a badge counting
/// sign-ups waiting for approval.
class PayslipAccessButton extends riverpod.ConsumerWidget {
  final Color color;

  const PayslipAccessButton({super.key, this.color = Colors.white});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final pending = ref.watch(payslipAccountsRiverpod).valueOrNull?.where(
              (a) => a.status == PayslipAccountStatus.pending,
            ).length ??
        0;
    return IconButton(
      color: color,
      tooltip: pending > 0
          ? 'Payslip access: $pending waiting for approval'
          : 'Payslip access',
      icon: Badge(
        isLabelVisible: pending > 0,
        label: Text('$pending'),
        child: const Icon(Icons.phonelink_lock_outlined),
      ),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PayslipAccessPage()),
      ),
    );
  }
}

/// Approve, reject and remove distributors' access to their own payslips
/// on clmworking.web.app/payslips.html.
class PayslipAccessPage extends riverpod.ConsumerWidget {
  const PayslipAccessPage({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final accountsAsync = ref.watch(payslipAccountsRiverpod);
    final distributors = [...ref.watch(scheduleRiverpod).distributors]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Payslip access'),
      ),
      body: accountsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              friendlyFirebaseError(e, action: 'load the payslip sign-ups'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (accounts) {
          final pending = accounts
              .where((a) => a.status == PayslipAccountStatus.pending)
              .toList();
          final approved = accounts
              .where((a) => a.status == PayslipAccountStatus.approved)
              .toList()
            ..sort((a, b) => (a.distributorName ?? '')
                .toLowerCase()
                .compareTo((b.distributorName ?? '').toLowerCase()));
          final closed = accounts
              .where((a) =>
                  a.status == PayslipAccountStatus.rejected ||
                  a.status == PayslipAccountStatus.removed)
              .toList();

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const _HowItWorks(),
                  const SizedBox(height: 20),
                  _SectionTitle('Waiting for approval', pending.length),
                  if (pending.isEmpty)
                    const _Empty('Nobody is waiting.')
                  else
                    for (final a in pending)
                      _PendingCard(
                        key: ValueKey(a.id),
                        account: a,
                        distributors: distributors,
                        approved: approved,
                      ),
                  const SizedBox(height: 20),
                  _SectionTitle('Have access', approved.length),
                  if (approved.isEmpty)
                    const _Empty('No distributor has access yet.')
                  else
                    Card(
                      margin: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (final a in approved) ...[
                            _ApprovedRow(account: a),
                            if (a != approved.last) const Divider(height: 1),
                          ],
                        ],
                      ),
                    ),
                  if (closed.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Card(
                      margin: EdgeInsets.zero,
                      child: ExpansionTile(
                        title: Text('Rejected and removed (${closed.length})'),
                        children: [
                          for (final a in closed) _ClosedRow(account: a),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: const Text(
        'Distributors sign up at clmworking.web.app/payslips.html with their '
        'cellphone number. Before you approve someone, ask them for the '
        '4-digit code showing on their phone and check it matches. An '
        'approved distributor sees only the distributor you link them to, '
        'and only weeks marked Paid.\n\n'
        'Forgotten password: remove their access, ask them to sign up again '
        'with the same number, then approve the new request.',
        style: TextStyle(fontSize: 13, height: 1.4),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final int count;

  const _SectionTitle(this.title, this.count);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          '$title ($count)',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      );
}

class _Empty extends StatelessWidget {
  final String text;

  const _Empty(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: TextStyle(color: Colors.grey.shade600)),
      );
}

/// "Thabo · Thabo Mokoena": the schedule name and the legal name the
/// distributor picked on the sign-up page.
String _withLegalName(Distributor d) {
  final legal = (d.fullName ?? '').trim();
  return legal.isEmpty || legal.toLowerCase() == d.name.trim().toLowerCase()
      ? d.name
      : '${d.name} · $legal';
}

String _reviewer(riverpod.WidgetRef ref) {
  final email = ref.read(authRiverpod).userEmail;
  return email.isNotEmpty ? email : 'admin';
}

/// Shows a toast with an Undo that puts [before] back.
void _toastWithUndo(
  BuildContext context,
  riverpod.WidgetRef ref,
  String message,
  PayslipAccount before,
) {
  final messenger = ScaffoldMessenger.of(context);
  final service = ref.read(payslipAccessServiceRiverpod);
  final reviewer = _reviewer(ref);
  messenger.showToast(SnackBar(
    content: Text(message),
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () async {
        try {
          await service.restore(before, reviewer);
        } catch (e) {
          messenger.showToast(SnackBar(
            content: Text(friendlyFirebaseError(e, action: 'undo that')),
          ));
        }
      },
    ),
  ));
}

class _PendingCard extends riverpod.ConsumerStatefulWidget {
  final PayslipAccount account;
  final List<Distributor> distributors;
  final List<PayslipAccount> approved;

  const _PendingCard({
    super.key,
    required this.account,
    required this.distributors,
    required this.approved,
  });

  @override
  riverpod.ConsumerState<_PendingCard> createState() => _PendingCardState();
}

class _PendingCardState extends riverpod.ConsumerState<_PendingCard> {
  String? _distributorId;
  bool _busy = false;

  /// The distributor whose profile carries this sign-up's phone number.
  Distributor? get _phoneMatch {
    for (final d in widget.distributors) {
      if (normalizeSaPhone(d.phone1) == widget.account.phone ||
          normalizeSaPhone(d.phone2) == widget.account.phone) {
        return d;
      }
    }
    return null;
  }

  /// The distributor they picked from the list when signing up, if still
  /// on the books.
  Distributor? get _claimed {
    for (final d in widget.distributors) {
      if (d.id == widget.account.claimedDistributorId) return d;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    // Suggest, never decide: who they picked, then a phone match, then an
    // exact name match (sign-ups from before the name list).
    final byPhone = _phoneMatch;
    if (_claimed != null) {
      _distributorId = _claimed!.id;
    } else if (byPhone != null) {
      _distributorId = byPhone.id;
    } else {
      final typed = widget.account.name.toLowerCase().trim();
      for (final d in widget.distributors) {
        if (d.name.toLowerCase().trim() == typed ||
            (d.fullName ?? '').toLowerCase().trim() == typed) {
          _distributorId = d.id;
          break;
        }
      }
    }
  }

  Distributor? get _selected {
    for (final d in widget.distributors) {
      if (d.id == _distributorId) return d;
    }
    return null;
  }

  Future<void> _approve() async {
    final distributor = _selected;
    if (distributor == null) return;
    final a = widget.account;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Approve payslip access?'),
        content: Text(
          '${a.phoneDisplay} (${a.name}) will see ${distributor.name}\'s '
          'payslips for every week marked Paid.\n\n'
          'Only approve if they told you the code ${a.signupCode}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(payslipAccessServiceRiverpod)
          .approve(a.id, distributor, _reviewer(ref));
      messenger.showToast(SnackBar(
        content: Text('Approved. ${a.name} can now see ${distributor.name}\'s '
            'paid payslips.'),
      ));
    } catch (e) {
      messenger.showToast(SnackBar(
        content: Text(friendlyFirebaseError(e, action: 'approve it')),
      ));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    final a = widget.account;
    setState(() => _busy = true);
    try {
      await ref
          .read(payslipAccessServiceRiverpod)
          .reject(a.id, _reviewer(ref));
      if (mounted) {
        _toastWithUndo(context, ref, 'Rejected ${a.name}\'s request.', a);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(SnackBar(
          content: Text(friendlyFirebaseError(e, action: 'reject it')),
        ));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final selected = _selected;
    final phoneMatch = _phoneMatch;
    final claimed = _claimed;
    final alreadyHasAccess = selected == null
        ? const <PayslipAccount>[]
        : widget.approved
            .where((x) => x.distributorId == selected.id)
            .toList();

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.name,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(a.phoneDisplay),
                      if (a.createdAt != null)
                        Text('Signed up ${_when.format(a.createdAt!)}',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                Column(
                  children: [
                    Text('Code',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600)),
                    Text(
                      a.signupCode,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 3,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: selected?.id,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Which distributor is this?',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final d in widget.distributors)
                  DropdownMenuItem(
                    value: d.id,
                    child: Text(
                      [
                        _withLegalName(d),
                        if (d.status != DistributorStatus.active)
                          '(${d.status.displayName})',
                      ].join(' '),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged:
                  _busy ? null : (id) => setState(() => _distributorId = id),
            ),
            const SizedBox(height: 8),
            if (claimed != null && claimed.id != selected?.id)
              _Hint(Icons.warning_amber_rounded, Colors.orange.shade800,
                  'They picked ${_withLegalName(claimed)} when signing up, '
                  'not the '
                  'distributor selected here.'),
            if (phoneMatch != null && phoneMatch.id == selected?.id)
              _Hint(Icons.check_circle_outline, Colors.green.shade700,
                  'This number is on ${phoneMatch.name}\'s profile.')
            else if (phoneMatch != null)
              _Hint(Icons.warning_amber_rounded, Colors.orange.shade800,
                  'This number is on ${phoneMatch.name}\'s profile, not the '
                  'distributor you picked.')
            else
              _Hint(Icons.info_outline, Colors.grey.shade700,
                  'This number is not on any distributor\'s profile. Check '
                  'the code with them before approving.'),
            for (final other in alreadyHasAccess)
              _Hint(
                  Icons.warning_amber_rounded,
                  Colors.orange.shade800,
                  '${selected!.name} already has access from '
                  '${other.phoneDisplay}. Approving adds a second login.'),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : _reject,
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _busy || selected == null ? null : _approve,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Approve'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _Hint(this.icon, this.color, this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(text, style: TextStyle(fontSize: 12, color: color)),
            ),
          ],
        ),
      );
}

class _ApprovedRow extends riverpod.ConsumerWidget {
  final PayslipAccount account;

  const _ApprovedRow({required this.account});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final a = account;
    final details = [
      a.phoneDisplay,
      if (a.name.isNotEmpty && a.name != a.distributorName) 'signed up as ${a.name}',
      if (a.reviewedBy != null && a.reviewedAt != null)
        'approved by ${a.reviewedBy} ${_when.format(a.reviewedAt!)}',
      a.lastLoginAt != null
          ? 'last signed in ${_when.format(a.lastLoginAt!)}'
          : 'not signed in since approval',
    ].join(' · ');
    return ListTile(
      title: Text(a.distributorName ?? a.name),
      subtitle: Text(details, style: const TextStyle(fontSize: 12)),
      trailing: TextButton(
        style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
        onPressed: () async {
          try {
            await ref
                .read(payslipAccessServiceRiverpod)
                .remove(a.id, _reviewer(ref));
            if (context.mounted) {
              _toastWithUndo(context, ref,
                  'Removed ${a.distributorName ?? a.name}\'s payslip access.', a);
            }
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showToast(SnackBar(
                content:
                    Text(friendlyFirebaseError(e, action: 'remove access')),
              ));
            }
          }
        },
        child: const Text('Remove access'),
      ),
    );
  }
}

class _ClosedRow extends StatelessWidget {
  final PayslipAccount account;

  const _ClosedRow({required this.account});

  @override
  Widget build(BuildContext context) {
    final a = account;
    final what =
        a.status == PayslipAccountStatus.removed ? 'Access removed' : 'Rejected';
    final by = [
      if (a.reviewedBy != null) 'by ${a.reviewedBy}',
      if (a.reviewedAt != null) _when.format(a.reviewedAt!),
    ].join(' ');
    return ListTile(
      dense: true,
      title: Text(a.distributorName != null
          ? '${a.distributorName} (${a.name})'
          : a.name),
      subtitle: Text('${a.phoneDisplay} · $what${by.isEmpty ? '' : ' $by'}'),
    );
  }
}
