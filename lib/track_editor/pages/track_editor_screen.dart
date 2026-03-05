// track_editor/pages/track_editor_screen.dart
//
// Full-screen shell for the Track Editor. Owns the Scaffold so that the
// app bar can expose mode-switch actions (Import / Trim / Processing)
// without needing an extra bar inside the body.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/te_mode_provider.dart';
import 'track_editor_page.dart';

class TrackEditorScreen extends StatelessWidget {
  const TrackEditorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mode = context.watch<TEModeProvider>().mode;
    final modeProvider = context.read<TEModeProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 222, 222, 222),
      appBar: AppBar(
        backgroundColor: colorScheme.inversePrimary,
        title: const Text(
          'Track Editor',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          // ── Import ───────────────────────────────────────────────
          _ModeButton(
            icon: Icons.upload_file,
            label: 'Import',
            selected: mode == TEMode.import,
            onTap: () => modeProvider.setMode(TEMode.import),
          ),
          // ── Trim ─────────────────────────────────────────────────
          _ModeButton(
            icon: Icons.content_cut,
            label: 'Trim',
            selected: mode == TEMode.trim,
            onTap: () => modeProvider.setMode(TEMode.trim),
          ),
          // ── Processing ───────────────────────────────────────────
          _ModeButton(
            icon: Icons.settings_suggest,
            label: 'Processing',
            selected: mode == TEMode.processing,
            onTap: () => modeProvider.setMode(TEMode.processing),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: const TrackEditorPage(),
    );
  }
}

// ── A labelled toggle button used in the app bar ──────────────────────────────
class _ModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontSize: 13)),
        style: TextButton.styleFrom(
          foregroundColor: selected ? Colors.white : Colors.black54,
          backgroundColor: selected
              ? Colors.blueGrey.shade600
              : Colors.black.withValues(alpha: 0.05),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}
