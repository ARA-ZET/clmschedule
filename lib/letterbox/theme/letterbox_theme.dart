import 'package:flutter/material.dart';

/// Visual language for the letterbox tool.
///
/// This is an operations tool that gets stared at for hours while curating 613
/// suburbs, so the choices lean quiet: one accent colour, generous spacing, and
/// almost no borders — depth comes from surface tint rather than lines. The
/// only thing allowed to shout is a count, because counts are what the tool is
/// for.
class LetterboxTheme {
  const LetterboxTheme._();

  /// Corner radius used everywhere. One value, so nothing looks accidental.
  static const double radius = 14;
  static const double radiusSmall = 10;

  /// 8pt spacing scale.
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;

  static const Color _seed = Color(0xFF3B5BDB);

  /// Status colours, shared by the map overlay, the legend and the list so a
  /// suburb reads the same everywhere.
  static const Color unseeded = Color(0xFF94A3B8);
  static const Color seeded = Color(0xFFF59E0B);
  static const Color inProgress = Color(0xFFF97316);
  static const Color verified = Color(0xFF16A34A);

  /// Apartment-block pins. Distinct from every status colour so a block never
  /// reads as a curation state.
  static const Color apartment = Color(0xFF7C3AED);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.light,
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surfaceContainerLowest,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        side: BorderSide.none,
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        padding: const EdgeInsets.symmetric(horizontal: s2, vertical: s1),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: s3, vertical: s3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSmall),
            ),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
          padding: const EdgeInsets.symmetric(horizontal: s4, vertical: s3),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
          side: BorderSide(color: scheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: s4, vertical: s3),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.5),
        contentPadding: const EdgeInsets.symmetric(horizontal: s3),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius + 4),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
        space: 1,
        thickness: 1,
      ),
    );
  }

  /// Soft shadow for panels floating over the map, where surface tint alone
  /// cannot separate them from satellite or terrain imagery.
  static List<BoxShadow> get floatingShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.10),
          blurRadius: 18,
          offset: const Offset(0, 4),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ];
}
