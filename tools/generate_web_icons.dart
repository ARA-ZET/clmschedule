#!/usr/bin/env dart

import 'dart:io';
import 'package:image/image.dart' as img;

/// Generates web icons and favicon from assets/logo.png
///
/// This script reads the logo.png file and creates:
/// - favicon.png (32x32) for the browser tab icon
/// - Icon-192.png (192x192) for PWA manifest
/// - Icon-512.png (512x512) for PWA manifest
/// - Icon-maskable-192.png (192x192) with padding for maskable icons
/// - Icon-maskable-512.png (512x512) with padding for maskable icons
///
/// Run this script with: dart run tools/generate_web_icons.dart

void main() async {
  print('🎨 CLM Schedule - Web Icon Generator');
  print('═' * 50);

  // Paths
  final sourceFile = File('assets/logo.png');
  final webDir = Directory('web');
  final iconsDir = Directory('web/icons');

  // Validate source file exists
  if (!sourceFile.existsSync()) {
    print('❌ Error: assets/logo.png not found!');
    print('   Please place your logo.png file in the assets/ directory.');
    exit(1);
  }

  // Ensure directories exist
  if (!webDir.existsSync()) {
    print('❌ Error: web/ directory not found!');
    exit(1);
  }

  if (!iconsDir.existsSync()) {
    print('📁 Creating web/icons/ directory...');
    iconsDir.createSync(recursive: true);
  }

  try {
    // Read the source logo
    print('📖 Reading logo from assets/logo.png...');
    final sourceBytes = sourceFile.readAsBytesSync();
    final sourceImage = img.decodeImage(sourceBytes);

    if (sourceImage == null) {
      print(
          '❌ Error: Could not decode logo.png. Make sure it\'s a valid PNG file.');
      exit(1);
    }

    print(
        '✅ Logo loaded successfully (${sourceImage.width}x${sourceImage.height})');
    print('');

    // Generate icons
    await _generateIcons(sourceImage);

    print('');
    print('═' * 50);
    print('✨ All icons generated successfully!');
    print('');
    print('📝 Next steps:');
    print('   1. Check web/favicon.png and web/icons/*.png');
    print('   2. Run: flutter build web');
    print('   3. Deploy your web app!');
  } catch (e, stackTrace) {
    print('❌ Error generating icons: $e');
    print(stackTrace);
    exit(1);
  }
}

Future<void> _generateIcons(img.Image sourceImage) async {
  // 1. Generate favicon (32x32)
  print('🖼️  Generating favicon.png (32x32)...');
  final favicon = img.copyResize(
    sourceImage,
    width: 32,
    height: 32,
    interpolation: img.Interpolation.linear,
  );
  File('web/favicon.png').writeAsBytesSync(img.encodePng(favicon));
  print('   ✅ web/favicon.png created');

  // 2. Generate Icon-192.png
  print('🖼️  Generating Icon-192.png (192x192)...');
  final icon192 = img.copyResize(
    sourceImage,
    width: 192,
    height: 192,
    interpolation: img.Interpolation.linear,
  );
  File('web/icons/Icon-192.png').writeAsBytesSync(img.encodePng(icon192));
  print('   ✅ web/icons/Icon-192.png created');

  // 3. Generate Icon-512.png
  print('🖼️  Generating Icon-512.png (512x512)...');
  final icon512 = img.copyResize(
    sourceImage,
    width: 512,
    height: 512,
    interpolation: img.Interpolation.linear,
  );
  File('web/icons/Icon-512.png').writeAsBytesSync(img.encodePng(icon512));
  print('   ✅ web/icons/Icon-512.png created');

  // 4. Generate maskable icons (with 20% padding for safe zone)
  print('🖼️  Generating Icon-maskable-192.png (192x192 with padding)...');
  final maskable192 = _createMaskableIcon(sourceImage, 192);
  File('web/icons/Icon-maskable-192.png')
      .writeAsBytesSync(img.encodePng(maskable192));
  print('   ✅ web/icons/Icon-maskable-192.png created');

  print('🖼️  Generating Icon-maskable-512.png (512x512 with padding)...');
  final maskable512 = _createMaskableIcon(sourceImage, 512);
  File('web/icons/Icon-maskable-512.png')
      .writeAsBytesSync(img.encodePng(maskable512));
  print('   ✅ web/icons/Icon-maskable-512.png created');
}

/// Creates a maskable icon with proper padding for safe zone
/// Maskable icons need 20% padding to ensure they work with different shapes
img.Image _createMaskableIcon(img.Image source, int size) {
  // Create background canvas
  final canvas = img.Image(width: size, height: size);

  // Fill with white background (you can change this to match your brand color)
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));

  // Calculate padded size (80% of canvas for the logo, 20% total padding)
  final paddedSize = (size * 0.8).round();
  final offset = ((size - paddedSize) / 2).round();

  // Resize and center the logo
  final resizedLogo = img.copyResize(
    source,
    width: paddedSize,
    height: paddedSize,
    interpolation: img.Interpolation.linear,
  );

  // Composite the logo onto the canvas
  img.compositeImage(canvas, resizedLogo, dstX: offset, dstY: offset);

  return canvas;
}
