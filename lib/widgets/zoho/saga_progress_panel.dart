import 'package:flutter/material.dart';

import '../slow_action_hint.dart';
import 'invoice_save_saga.dart';
import 'zoho_table.dart';

/// Per-step result panel for [InvoiceSaveSaga], so the user can see exactly
/// what completed before the dialog closes.
class SagaProgressPanel extends StatelessWidget {
  final InvoiceSaveSaga saga;
  final VoidCallback? onRetry;

  const SagaProgressPanel({
    super.key,
    required this.saga,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final failed = saga.hasFailed;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZohoPalette.surface,
        border: Border.all(
          color: failed ? Colors.red.shade200 : ZohoPalette.border,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final step in saga.steps) _buildStep(step),
          SlowActionHint(
              busy: saga.isRunning,
              action: 'Working with ${saga.providerName}'),
          if (failed) ...[
            const Divider(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: Colors.orange.shade800),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    // The invoice existing changes the stakes entirely: the
                    // job is fine, but real accounting data is now unlinked.
                    // Named, not hardcoded: this panel serves both providers,
                    // and pointing someone at the wrong set of books while
                    // they are chasing an unlinked invoice is the worst
                    // possible moment to be vague.
                    saga.onlyAllocationFailed
                        ? 'The job is saved'
                            '${saga.invoiceExists ? ' and invoiced' : ''} but '
                            'is NOT on the Schedule. Retry to allocate it, or '
                            'add it on the Schedule by hand.'
                        : saga.invoiceExists
                            ? 'Invoice ${saga.invoice!.invoiceNumber} EXISTS in '
                                '${saga.providerName} but is not linked to the job. '
                                'Retry, or note the number and link it manually — '
                                'do not create another.'
                            // A lost reply can hide an invoice that was in
                            // fact raised; the retry sends the same request
                            // key, so it picks that invoice up instead of
                            // raising another.
                            : 'The invoice was not confirmed by '
                                '${saga.providerName}. Retry is safe — it will '
                                'not create a second invoice.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange.shade900,
                    ),
                  ),
                ),
              ],
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: saga.isRunning ? null : onRetry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(saga.onlyAllocationFailed
                      ? 'Retry allocation'
                      : 'Retry from failed step'),
                  style: FilledButton.styleFrom(
                    backgroundColor: ZohoPalette.link,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                    textStyle: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildStep(SagaStep step) {
    late final Widget icon;
    late final Color color;

    switch (step.state) {
      case SagaStepState.pending:
        icon = Icon(Icons.radio_button_unchecked,
            size: 16, color: Colors.grey.shade400);
        color = ZohoPalette.textMuted;
        break;
      case SagaStepState.running:
        icon = const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        color = ZohoPalette.textPrimary;
        break;
      case SagaStepState.done:
        icon =
            const Icon(Icons.check_circle, size: 16, color: Color(0xFF2E9E4F));
        color = ZohoPalette.textPrimary;
        break;
      case SagaStepState.skipped:
        icon = const Icon(Icons.remove_circle_outline,
            size: 16, color: ZohoPalette.textMuted);
        color = ZohoPalette.textMuted;
        break;
      case SagaStepState.failed:
        icon = const Icon(Icons.cancel, size: 16, color: Color(0xFFE03E3E));
        color = const Color(0xFFE03E3E);
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 20, child: Center(child: icon)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: step.state == SagaStepState.running
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: color,
                  ),
                ),
                if (step.detail != null && step.detail!.isNotEmpty)
                  Text(
                    step.detail!,
                    style: TextStyle(
                      fontSize: 11,
                      color: step.state == SagaStepState.failed
                          ? const Color(0xFFE03E3E)
                          : ZohoPalette.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
