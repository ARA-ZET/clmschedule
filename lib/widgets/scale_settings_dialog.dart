import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/scale_provider.dart';

class ScaleSettingsDialog extends StatelessWidget {
  const ScaleSettingsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ScaleProvider>(
      builder: (context, scaleProvider, child) {
        return AlertDialog(
          title: const Text('Interface Scale Settings'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Adjust the size of text and icons throughout the application:',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 20),

                // Current scale display
                Text(
                  'Current Scale: ${(scaleProvider.scale * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),

                // Scale slider
                Slider(
                  value: scaleProvider.scale,
                  min: ScaleProvider.minScale,
                  max: ScaleProvider.maxScale,
                  divisions: 15, // 0.1 increments from 0.5 to 2.0
                  label: '${(scaleProvider.scale * 100).round()}%',
                  onChanged: (value) {
                    scaleProvider.setScale(value);
                  },
                ),

                // Scale indicators
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${(ScaleProvider.minScale * 100).round()}%',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const Text(
                      '100%',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    Text(
                      '${(ScaleProvider.maxScale * 100).round()}%',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Quick preset buttons
                const Text(
                  'Quick Presets:',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildPresetButton(context, scaleProvider, 'Small', 0.75),
                    _buildPresetButton(context, scaleProvider, 'Normal', 1.0),
                    _buildPresetButton(context, scaleProvider, 'Large', 1.25),
                    _buildPresetButton(context, scaleProvider, 'X-Large', 1.5),
                  ],
                ),
                const SizedBox(height: 20),

                // Live preview
                const Text(
                  'Preview:',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.schedule,
                            size: scaleProvider.mediumIconSize,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Sample Job Card',
                            style: TextStyle(
                              fontSize: scaleProvider.baseFontSize,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Client: John Doe',
                        style: TextStyle(fontSize: scaleProvider.smallFontSize),
                      ),
                      Text(
                        'Area: Downtown',
                        style: TextStyle(fontSize: scaleProvider.smallFontSize),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                scaleProvider.resetScale();
              },
              child: const Text('Reset to Default'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPresetButton(
    BuildContext context,
    ScaleProvider scaleProvider,
    String label,
    double scale,
  ) {
    final isSelected = (scaleProvider.scale - scale).abs() < 0.01;

    return ElevatedButton(
      onPressed: () {
        scaleProvider.setScale(scale);
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: isSelected ? Theme.of(context).primaryColor : null,
        foregroundColor: isSelected ? Colors.white : null,
      ),
      child: Text(label),
    );
  }
}
