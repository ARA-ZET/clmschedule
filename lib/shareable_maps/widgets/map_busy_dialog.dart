import 'package:flutter/material.dart';

/// Runs [task] behind a modal, undismissable progress dialog and returns its
/// result. [task] gets a `step` callback to update the line shown under the
/// spinner, so the user sees what is happening instead of a frozen screen.
///
/// Use it for work that swaps the open map out from under the user (duplicate,
/// open copy): until it finishes, the map on screen is the *old* one, and any
/// edit made in that gap lands on the wrong map. The dialog is a PopupRoute, so
/// [MapModalGestureObserver] also holds the Google Map for as long as it is up,
/// and it owns keyboard focus, so editor shortcuts can't fire underneath.
///
/// The dialog closes when [task] completes or throws; errors are rethrown for
/// the caller to report.
Future<T> runWithMapBusyDialog<T>(
  BuildContext context, {
  required String title,
  required String initialStep,
  required Future<T> Function(void Function(String step) step) task,
}) async {
  final stepText = ValueNotifier<String>(initialStep);
  // Pushed on the root navigator like showDialog, and closed through the route
  // itself — never the caller's context, which may resolve to the nested
  // body navigator and pop the page instead.
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 360),
          child: Row(
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: stepText,
                  builder: (_, text, __) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(text),
                      const SizedBox(height: 6),
                      Text(
                        'Please wait — don\'t edit the map until this closes.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  navigator.push(route);
  try {
    return await task((s) => stepText.value = s);
  } finally {
    if (route.isActive) {
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    }
  }
}
