import 'package:flutter/material.dart';

import '../../models/geocode_detail.dart';

/// Shared visual language for the geocoding + route planning tool.
///
/// The screens here are dense — a list, a live map, progress, stats and
/// exports all on one surface — so the small pieces are defined once and
/// reused, rather than each screen inventing its own chip and card.
class GeocodeColors {
  GeocodeColors._();

  static const brand = Color(0xFF1565C0);
  static const success = Color(0xFF2E7D32);
  static const warning = Color(0xFFEF6C00);
  static const danger = Color(0xFFC62828);
  static const neutral = Color(0xFF546E7A);
  static const depot = Color(0xFF6A1B9A);

  static Color forPrecision(GeocodePrecision precision) => switch (precision) {
        GeocodePrecision.manual => depot,
        GeocodePrecision.exact => success,
        GeocodePrecision.interpolated => brand,
        GeocodePrecision.approximate => warning,
        GeocodePrecision.low => danger,
        GeocodePrecision.unknown => neutral,
      };
}

/// A compact labelled figure, used across the stat strips.
class StatPill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool selected;

  const StatPill({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.icon,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: selected
            ? color.withValues(alpha: 0.16)
            : color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: selected ? 0.85 : 0.28),
          width: selected ? 1.6 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 7),
          ],
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: color,
              height: 1.1,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: color.withValues(alpha: 0.85),
              height: 1.1,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: content,
    );
  }
}

/// Colour-coded badge for how much a geocoded pin can be trusted.
class PrecisionChip extends StatelessWidget {
  final GeocodePrecision precision;
  final bool dense;

  const PrecisionChip({super.key, required this.precision, this.dense = true});

  @override
  Widget build(BuildContext context) {
    final color = GeocodeColors.forPrecision(precision);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 10,
        vertical: dense ? 2 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            switch (precision) {
              GeocodePrecision.manual => Icons.touch_app_rounded,
              GeocodePrecision.exact ||
              GeocodePrecision.interpolated =>
                Icons.gps_fixed_rounded,
              _ => Icons.help_outline,
            },
            size: dense ? 11 : 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            precision.label,
            style: TextStyle(
              fontSize: dense ? 10.5 : 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small numbered badge matching the map pins.
class SequenceBadge extends StatelessWidget {
  final String label;
  final Color color;
  final bool selected;
  final double size;

  const SequenceBadge({
    super.key,
    required this.label,
    required this.color,
    this.selected = false,
    this.size = 30,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: selected
            ? Border.all(color: Colors.white, width: 2.5)
            : null,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: selected ? 0.55 : 0.25),
            blurRadius: selected ? 10 : 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: label.length >= 3 ? size * 0.33 : size * 0.42,
        ),
      ),
    );
  }
}

/// Slim determinate/indeterminate bar with a status line, shown inline
/// instead of a modal dialog.
///
/// Long operations here used to sit behind a barrier dialog, which meant
/// any bug in dismissing it left the user stuck with a spinner and no way
/// out. Inline progress keeps the screen usable and cancellable.
class InlineProgressBar extends StatelessWidget {
  final String message;
  final double? fraction;
  final String? detail;
  final VoidCallback? onCancel;
  final Color color;

  const InlineProgressBar({
    super.key,
    required this.message,
    this.fraction,
    this.detail,
    this.onCancel,
    this.color = GeocodeColors.brand,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                value: fraction,
                color: color,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          message,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: color,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (fraction != null)
                        Text(
                          '${(fraction! * 100).round()}%',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: color,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: fraction,
                      minHeight: 5,
                      backgroundColor: color.withValues(alpha: 0.15),
                      color: color,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onCancel != null)
              TextButton(
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Centred illustration + message + optional call to action.
class GeocodeEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const GeocodeEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: GeocodeColors.brand.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 42, color: GeocodeColors.brand),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 22),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Rounded surface used for the floating panels over the map.
class GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double maxWidth;

  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.maxWidth = 420,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        color: theme.colorScheme.surface.withValues(alpha: 0.97),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Snack helper that keeps messaging consistent and never throws when the
/// screen has already gone.
void showGeocodeSnack(
  BuildContext context,
  String message, {
  bool isError = false,
  SnackBarAction? action,
}) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        width: 460,
        backgroundColor: isError ? GeocodeColors.danger : null,
        duration: Duration(seconds: isError ? 6 : 3),
        action: action,
      ),
    );
}
