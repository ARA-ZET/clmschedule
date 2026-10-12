import 'package:flutter/material.dart';

import '../models/erf_area.dart';

/// One downloaded area in the sidebar or strip.
///
/// Carries its parcel count and stored size, so the cost of an area is
/// visible before it is opened rather than after.
class ErfAreaCard extends StatelessWidget {
  const ErfAreaCard({
    super.key,
    required this.area,
    required this.selected,
    required this.onOpen,
    required this.onDelete,
    this.enabled = true,
  });

  final ErfArea area;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? onOpen : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Row(
            children: [
              Icon(
                area.source == ErfAreaSource.boundingBox
                    ? Icons.crop_free_rounded
                    : Icons.location_city_rounded,
                size: 20,
                color: selected ? scheme.onPrimaryContainer : scheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      area.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: selected ? scheme.onPrimaryContainer : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        '${area.propertyCount} parcels',
                        if (area.sizeLabel.isNotEmpty) area.sizeLabel,
                        if (!area.isPacked) 'unpacked',
                      ].join(' · '),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: selected
                            ? scheme.onPrimaryContainer.withValues(alpha: 0.8)
                            : scheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: 'Remove ${area.name}',
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? onDelete : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
