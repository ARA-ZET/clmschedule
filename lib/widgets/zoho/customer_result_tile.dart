import 'package:flutter/material.dart';

import 'zoho_table.dart';

/// One customer in a search-results list.
///
/// Shared by the Zoho and Xero pickers so the two read alike — the same row
/// shape, the same detail, the same hit area. Picking a customer is the step
/// that decides who gets billed, and a cramped one-line row makes it easy to
/// take the wrong one of two similar names.
class CustomerResultTile extends StatelessWidget {
  final String name;

  /// Secondary identity — a company, or the person at the client.
  final String subtitle;

  final String email;
  final String phone;

  /// Right-hand note, e.g. an outstanding balance. Blank when unknown.
  final String trailingLabel;

  final VoidCallback onTap;

  const CustomerResultTile({
    super.key,
    required this.name,
    required this.onTap,
    this.subtitle = '',
    this.email = '',
    this.phone = '',
    this.trailingLabel = '',
  });

  /// First letter of the name, for the avatar. Falls back to a person icon so
  /// an unnamed contact does not render an empty circle.
  String get _initial {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '' : trimmed.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final details = [
      if (email.isNotEmpty) email,
      if (phone.isNotEmpty) phone,
    ].join('  ·  ');

    return InkWell(
      onTap: onTap,
      hoverColor: ZohoPalette.rowHover,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: ZohoPalette.link.withValues(alpha: 0.12),
              child: _initial.isEmpty
                  ? const Icon(Icons.person_outline,
                      size: 16, color: ZohoPalette.link)
                  : Text(
                      _initial,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: ZohoPalette.link,
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name.isEmpty ? '(no name)' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: ZohoPalette.textPrimary,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: ZohoPalette.textPrimary,
                      ),
                    ),
                  if (details.isNotEmpty)
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: ZohoPalette.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            if (trailingLabel.isNotEmpty) ...[
              const SizedBox(width: 10),
              Text(
                trailingLabel,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ZohoPalette.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
