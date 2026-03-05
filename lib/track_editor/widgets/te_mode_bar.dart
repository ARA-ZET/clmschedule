// track_editor/widgets/te_mode_bar.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/te_mode_provider.dart';

class TEModeBar extends StatelessWidget {
  const TEModeBar({super.key});

  static const _modes = [
    (mode: TEMode.import, label: 'Import', icon: Icons.upload_file),
    (
      mode: TEMode.processing,
      label: 'Processing',
      icon: Icons.settings_suggest
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final current = context.watch<TEModeProvider>().mode;
    final provider = context.read<TEModeProvider>();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: _modes.map((item) {
          final selected = current == item.mode;
          return GestureDetector(
            onTap: () => provider.setMode(item.mode),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? Colors.blueGrey : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Row(
                spacing: 6,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    item.icon,
                    size: 16,
                    color: selected ? Colors.white : Colors.blueGrey.shade700,
                  ),
                  Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : Colors.blueGrey.shade700,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
