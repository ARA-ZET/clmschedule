import 'package:flutter/material.dart';

/// Highest flyer-set count offered in the picker. A saved value above this
/// (or any other non-standard value) is still shown — see
/// [SetsOrCodeDropdown] — so nothing already recorded is silently lost.
const int kMaxSetsOption = 3;

/// Bounds for the open menu's width — it is sized to its longest
/// "code — description" label rather than the narrow grid cell, so
/// descriptions can be read in full.
const double _kMenuMinWidth = 200;
const double _kMenuMaxWidth = 520;

/// Normalises a typed/saved value to its canonical option — a code in its
/// configured casing (e.g. "dr" -> "DR"), otherwise the trimmed text.
String canonicalSetsOrCode(String raw, List<String> knownCodes) {
  final t = raw.trim();
  for (final c in knownCodes) {
    if (c.toLowerCase() == t.toLowerCase()) return c;
  }
  return t;
}

/// Picker for the "sets / code" cell, replacing free text so codes can't be
/// mistyped. Backed by a [TextEditingController] (empty = didn't work) so
/// the existing parse/save paths read it exactly as before.
class SetsOrCodeDropdown extends StatelessWidget {
  final TextEditingController controller;
  final List<String> codes;
  final Map<String, String> codeLabels;
  final bool enabled;
  final InputDecoration decoration;
  final TextStyle style;
  final FocusNode? focusNode;

  /// A value that was filled in automatically and isn't saved yet — shown
  /// italic and grey while the cell still holds it.
  final String? suggestedValue;

  /// Called after the admin picks a value (the controller is already set).
  final VoidCallback? onChanged;

  /// Whether "didn't work" is offered. Off for a day the distributor is
  /// allocated on the schedule — that's what decides whether they worked.
  final bool allowNotWorked;

  const SetsOrCodeDropdown({
    super.key,
    required this.controller,
    required this.codes,
    required this.codeLabels,
    required this.decoration,
    required this.style,
    this.enabled = true,
    this.focusNode,
    this.suggestedValue,
    this.onChanged,
    this.allowNotWorked = true,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, v, _) {
        final current = canonicalSetsOrCode(v.text, codes);
        final options = <String>[
          if (allowNotWorked || current.isEmpty) '',
          for (var i = 1; i <= kMaxSetsOption; i++) '$i',
          ...codes,
        ];
        // Keep an out-of-list saved value selectable rather than blanking it.
        if (!options.contains(current)) options.add(current);

        final isSuggested =
            suggestedValue != null && current == suggestedValue;
        final shownStyle = isSuggested
            ? style.copyWith(
                fontStyle: FontStyle.italic, color: Colors.grey.shade600)
            : style;

        String menuLabel(String o) {
          if (o.isEmpty) return '— (didn\'t work)';
          final label = codeLabels[o];
          return label == null || label.isEmpty ? o : '$o — $label';
        }

        final textScaler = MediaQuery.textScalerOf(context);
        var widest = 0.0;
        for (final o in options) {
          final painter = TextPainter(
            text: TextSpan(text: menuLabel(o), style: style),
            textDirection: TextDirection.ltr,
            textScaler: textScaler,
            maxLines: 1,
          )..layout();
          if (painter.width > widest) widest = painter.width;
          painter.dispose();
        }
        // + item padding either side and room for the scrollbar.
        final menuWidth =
            (widest + 48).clamp(_kMenuMinWidth, _kMenuMaxWidth).toDouble();

        return InputDecorator(
          decoration: decoration.copyWith(enabled: enabled),
          isEmpty: false,
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: current,
              focusNode: focusNode,
              isDense: true,
              isExpanded: true,
              style: shownStyle,
              iconSize: 16,
              menuWidth: menuWidth,
              items: [
                for (final o in options)
                  DropdownMenuItem(
                    value: o,
                    // Wraps rather than truncating if a description is
                    // longer than even the widest menu allowed.
                    child: Text(menuLabel(o), maxLines: 2, softWrap: true),
                  ),
              ],
              selectedItemBuilder: (_) => [
                for (final o in options)
                  Text(o.isEmpty ? '—' : o,
                      style: shownStyle, overflow: TextOverflow.ellipsis),
              ],
              onChanged: enabled
                  ? (o) {
                      if (o == null) return;
                      controller.text = o;
                      onChanged?.call();
                    }
                  : null,
            ),
          ),
        );
      },
    );
  }
}
