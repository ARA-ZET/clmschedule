import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/scale_provider.dart';

/// A test widget to demonstrate the global scaling functionality
class ScaleTestWidget extends StatelessWidget {
  const ScaleTestWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ScaleProvider>(
      builder: (context, scaleProvider, child) {
        return Card(
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Dynamic Scaling Demo',
                  style: TextStyle(
                    fontSize: scaleProvider.xlargeFontSize,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Current Scale: ${(scaleProvider.scale * 100).round()}%',
                  style: TextStyle(fontSize: scaleProvider.baseFontSize),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: scaleProvider.canDecrease
                          ? scaleProvider.decreaseScale
                          : null,
                      icon: Icon(Icons.remove,
                          size: scaleProvider.mediumIconSize),
                      label: Text(
                        'Smaller',
                        style:
                            TextStyle(fontSize: scaleProvider.mediumFontSize),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: scaleProvider.resetScale,
                      child: Text(
                        'Reset',
                        style:
                            TextStyle(fontSize: scaleProvider.mediumFontSize),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: scaleProvider.canIncrease
                          ? scaleProvider.increaseScale
                          : null,
                      icon: Icon(Icons.add, size: scaleProvider.mediumIconSize),
                      label: Text(
                        'Larger',
                        style:
                            TextStyle(fontSize: scaleProvider.mediumFontSize),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Font Size Examples:',
                  style: TextStyle(
                    fontSize: scaleProvider.baseFontSize,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Small Text',
                  style: TextStyle(fontSize: scaleProvider.smallFontSize),
                ),
                Text(
                  'Medium Text',
                  style: TextStyle(fontSize: scaleProvider.mediumFontSize),
                ),
                Text(
                  'Base Text',
                  style: TextStyle(fontSize: scaleProvider.baseFontSize),
                ),
                Text(
                  'Large Text',
                  style: TextStyle(fontSize: scaleProvider.largeFontSize),
                ),
                Text(
                  'Extra Large Text',
                  style: TextStyle(fontSize: scaleProvider.xlargeFontSize),
                ),
                const SizedBox(height: 16),
                Text(
                  'Icon Size Examples:',
                  style: TextStyle(
                    fontSize: scaleProvider.baseFontSize,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Column(
                      children: [
                        Icon(Icons.star, size: scaleProvider.smallIconSize),
                        Text(
                          'Small',
                          style:
                              TextStyle(fontSize: scaleProvider.smallFontSize),
                        ),
                      ],
                    ),
                    Column(
                      children: [
                        Icon(Icons.star, size: scaleProvider.mediumIconSize),
                        Text(
                          'Medium',
                          style:
                              TextStyle(fontSize: scaleProvider.smallFontSize),
                        ),
                      ],
                    ),
                    Column(
                      children: [
                        Icon(Icons.star, size: scaleProvider.largeIconSize),
                        Text(
                          'Large',
                          style:
                              TextStyle(fontSize: scaleProvider.smallFontSize),
                        ),
                      ],
                    ),
                    Column(
                      children: [
                        Icon(Icons.star, size: scaleProvider.xlargeIconSize),
                        Text(
                          'X-Large',
                          style:
                              TextStyle(fontSize: scaleProvider.smallFontSize),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
