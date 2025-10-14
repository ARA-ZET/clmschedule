import 'dart:math' as math;
import 'package:flutter/material.dart';

class ColorUtils {
  /// Determines whether to use light or dark text based on the background color's brightness
  /// Returns white for dark backgrounds and black for light backgrounds
  static Color getContrastingTextColor(Color backgroundColor) {
    // Calculate the luminance of the background color
    final luminance = backgroundColor.computeLuminance();

    // Use white text for dark backgrounds (luminance < 0.5)
    // Use black text for light backgrounds (luminance >= 0.5)
    return luminance < 0.5 ? Colors.white : Colors.black;
  }

  /// Alternative method using relative luminance calculation
  /// This provides more precise contrast calculation
  static Color getContrastingTextColorPrecise(Color backgroundColor) {
    // Get RGB values
    final red = backgroundColor.red / 255.0;
    final green = backgroundColor.green / 255.0;
    final blue = backgroundColor.blue / 255.0;

    // Apply gamma correction
    final double r = red <= 0.03928
        ? red / 12.92
        : math.pow((red + 0.055) / 1.055, 2.4).toDouble();
    final double g = green <= 0.03928
        ? green / 12.92
        : math.pow((green + 0.055) / 1.055, 2.4).toDouble();
    final double b = blue <= 0.03928
        ? blue / 12.92
        : math.pow((blue + 0.055) / 1.055, 2.4).toDouble();

    // Calculate relative luminance
    final luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;

    // Return white for dark backgrounds, black for light backgrounds
    return luminance > 0.179 ? Colors.black : Colors.white;
  }
}
