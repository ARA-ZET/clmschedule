// widgets/save_check_dialog.dart
//
// "Check saving files": tests Chrome's Save dialog on this computer and
// explains the one fix that is usually needed.
//
// On some Windows PCs the Save dialog opens full screen (Windows remembers a
// maximised Save dialog per program). It then covers Chrome, Chrome treats
// the page as hidden and closes its own dialog at once — every invoice then
// falls back to Downloads. A web page cannot see the dialog's size, nor open
// it without a click, so the check runs from a button: Settings → Check
// saving files, or "How to fix" on the toast after it happens.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../utils/root_navigator.dart';
import '../utils/save_with_picker.dart';

/// Opens the guide from anywhere (toast buttons sit above the Navigator).
void openSaveCheckGuide() {
  final context = rootNavigatorKey.currentContext;
  if (context == null) return;
  showSaveCheckDialog(context, afterFailure: true);
}

/// [afterFailure]: opened because Chrome just closed the Save dialog.
Future<void> showSaveCheckDialog(
  BuildContext context, {
  bool afterFailure = false,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => SaveCheckDialog(afterFailure: afterFailure),
    );

class SaveCheckDialog extends StatefulWidget {
  final bool afterFailure;

  const SaveCheckDialog({super.key, this.afterFailure = false});

  @override
  State<SaveCheckDialog> createState() => _SaveCheckDialogState();
}

class _SaveCheckDialogState extends State<SaveCheckDialog> {
  bool _testing = false;
  SaveCheckResult? _result;

  bool get _windows => defaultTargetPlatform == TargetPlatform.windows;

  Future<void> _test() async {
    // Nothing may be awaited before this: Chrome only opens the Save dialog
    // straight after the click.
    final check = checkSaveDialog();
    setState(() {
      _testing = true;
      _result = null;
    });
    final result = await check;
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final passed = _result?.outcome == SaveCheckOutcome.works;
    // From the toast the problem is already known; from Settings, only once
    // the test shows it.
    final showSteps = _windows &&
        !passed &&
        (widget.afterFailure ||
            _result?.outcome == SaveCheckOutcome.coveredByDialog);
    return AlertDialog(
      title: Text(widget.afterFailure
          ? 'Fix the Save dialog on this computer'
          : 'Check saving files'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.afterFailure
                  ? 'Chrome closed the Save dialog by itself, so the file went '
                      'to your Downloads folder instead. On Windows this '
                      'nearly always means the Save dialog opens full screen: '
                      'it covers Chrome, and Chrome closes it straight away.'
                  : 'Invoice PDFs open a Save dialog so you can choose the '
                      'folder. On some Windows computers that dialog opens '
                      'full screen, and Chrome then closes it at once. Test '
                      'this computer — when the Save dialog appears, just '
                      'press Cancel.'),
              if (_result != null) ...[
                const SizedBox(height: 16),
                _ResultBanner(result: _result!, windows: _windows),
              ],
              if (showSteps) ...[
                const SizedBox(height: 16),
                Text('To fix it', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                const _Step(
                  n: 1,
                  text: 'In Chrome, open a new tab on any website (for '
                      'example google.com) and press Ctrl+S.',
                ),
                const _Step(
                  n: 2,
                  text: 'If the Save As dialog fills the whole screen, click '
                      'the middle button at its top right (Restore Down), '
                      'drag it smaller, then click Cancel. Windows remembers '
                      'that size.',
                ),
                const _Step(
                  n: 3,
                  text: 'Come back here and press "Test the Save dialog".',
                ),
                const SizedBox(height: 12),
                Text(
                  'Or, in Chrome, turn on "Ask where to save each file before '
                  'downloading" (Settings → Downloads). Files that fall back '
                  'to a download will then ask for a folder too.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(passed ? 'Done' : 'Close'),
        ),
        FilledButton.icon(
          onPressed: _testing ? null : _test,
          icon: _testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_alt),
          label: Text(_result == null
              ? 'Test the Save dialog'
              : 'Test again'),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final int n;
  final String text;

  const _Step({required this.n, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 22, child: Text('$n.')),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

class _ResultBanner extends StatelessWidget {
  final SaveCheckResult result;
  final bool windows;

  const _ResultBanner({required this.result, required this.windows});

  @override
  Widget build(BuildContext context) {
    final (ok, text) = switch (result.outcome) {
      SaveCheckOutcome.works => (
          true,
          'The Save dialog works on this computer.'
              '${result.detail == null ? '' : ' ${result.detail}'}',
        ),
      SaveCheckOutcome.coveredByDialog => (
          false,
          windows
              ? 'Chrome closed the Save dialog again — it is still opening '
                  'full screen. Follow the steps below, then test again.'
              : 'Chrome closed the Save dialog because this window was '
                  'covered or hidden. Keep this window in front and test '
                  'again.',
        ),
      SaveCheckOutcome.notShown => (
          false,
          "Chrome didn't show the Save dialog. Make the Chrome window "
              'bigger and test again. If it still fails, file dialogs may be '
              'switched off on this computer: open chrome://policy and look '
              'for "AllowFileSelectionDialogs".',
        ),
      SaveCheckOutcome.unavailable => (
          false,
          'This browser has no Save dialog'
              '${result.detail == null ? '' : ' (${result.detail})'}, so '
              'files always go to the Downloads folder. Use Chrome or Edge '
              'to choose a folder.',
        ),
      SaveCheckOutcome.failed => (
          false,
          "The Save dialog couldn't open: ${result.detail}.",
        ),
    };
    final color = ok ? Colors.green.shade700 : Colors.red.shade700;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(ok ? Icons.check_circle : Icons.error_outline,
                color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}
